import XCTest
@testable import Epos

/// Offline quality eval for the LLM polish stage. Runs the configured production
/// polish engine (`PolishEngineFactory` + `TranscriptPolisher` guard + the
/// canonicalizer, both sides) over a text corpus — the recognizer's wav→text step
/// is covered separately by `SpeechContextEvalTests`, so this evals the polish
/// layer directly. The corpus is the transcripts of the saved real clips plus a
/// stress set that actually exercises polish (fillers, contraction, spoken
/// punctuation, guardrail bait, self-correction).
///
/// Skipped unless `EPOS_RUN_POLISH_EVAL=1`, since it runs the on-device model:
///
///   EPOS_RUN_POLISH_EVAL=1 swift test --filter PolishEvalTests
///   EPOS_POLISH_ENGINE=ollama EPOS_RUN_POLISH_EVAL=1 swift test --filter PolishEvalTests
///
/// Prints a per-row raw→outcome→output table plus a summary, and writes
/// `.build/evals/polish-eval.jsonl` with guard rejection candidate text and diffs.
/// Tune against two numbers: retained filler in the output should trend to 0
/// (polish is doing its job) and there must be ZERO meaning changes on inspection
/// (the safety bar). Refreshing the real-clip transcripts after recording new audio
/// uses the `LLMPolishProbe` harness — a local-only, gitignored probe project NOT
/// present in a fresh checkout: where it exists, run `swift run LLMPolishProbe
/// --transcribe-only` and paste the raw lines into `realClipTranscripts`.
final class PolishEvalTests: XCTestCase {
    /// Transcripts of the saved clips in ~/Library/Caches/Epos/recordings, as
    /// re-transcribed by the production preset (see the probe). Clean, filler-free
    /// sentences — they test that polish does not CORRUPT clean input.
    private static let realClipTranscripts = [
        "Ask Stas to review the CMOX changes.",
        "Stath pushed the fix to Siemux last night.",
        "Open cloud.md and update the project.yamo.",
        "Let's check the read me and the agent's file.",
        "Semux keeps crashing when stuff runs it.",
        "Edit cloud.md, then ping stuff.",
    ]

    /// Hand-authored cases that exercise the polish behavior the real clips don't:
    /// fillers (must be removed), spoken punctuation (must stay a word, the
    /// canonicalizer owns conversion), contraction (must not collapse), guardrail
    /// bait (no refusal), command-as-data and self-correction (kept verbatim).
    private static let stressTranscripts = [
        "um so like we should uh ship it you know",
        "so I was thinking like we could just um refactor the parser",
        "the build is uh totally broken and we need to like fix it right now",
        "i think we should uh just ship the feature you know",
        "send the report to dana comma then ping the team",
        "it's broken so just fix it",
        "kill the process and then nuke the build directory",
        "remind me to call the dentist tomorrow",
        "Tuesday no wait Wednesday works better for the demo",
        "the damn thing crashed again so basically we lost the data",
    ]

    func testProductionPolishOverCorpus() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["EPOS_RUN_POLISH_EVAL"] == "1" else {
            throw XCTSkip("Set EPOS_RUN_POLISH_EVAL=1 to run the on-device polish eval")
        }
        let engine = try await Self.makeConfiguredPolishEngine(environment: environment)

        let canonicalizer = TranscriptCanonicalizer.load()
        let knownTerms = ["Epos"] + canonicalizer.canonicalVocabularyStrings
        let prewarmDelay = SavedRecordingEvalSupport.polishPrewarmSettleNanoseconds(environment: environment)

        var rows: [PolishEvalRow] = []
        for (label, corpus) in [("real", Self.realClipTranscripts), ("stress", Self.stressTranscripts)] {
            for raw in corpus {
                let canonicalizedRaw = canonicalizer.canonicalize(raw)
                let polisher = TranscriptPolisher(
                    enabled: true,
                    engine: engine,
                    knownTerms: knownTerms,
                    canonicalize: { canonicalizer.canonicalize($0) }
                )
                polisher.prewarm()
                let prewarmWaitSeconds = await SavedRecordingEvalSupport.waitForPolishPrewarmSettle(
                    delayNanoseconds: prewarmDelay
                )
                let result = await polisher.polish(raw)
                rows.append(PolishEvalRow(
                    set: label,
                    raw: raw,
                    canonicalizedRaw: canonicalizedRaw,
                    output: result.text,
                    outcome: String(describing: result.outcome),
                    engineOutcome: result.engineOutcome?.rawValue,
                    prewarmWaitSeconds: prewarmWaitSeconds,
                    rawChangedByCanonicalizer: canonicalizedRaw != raw,
                    outputChangedFromRaw: result.text != raw,
                    outputChangedFromCanonicalizedRaw: result.text != canonicalizedRaw,
                    retainedFillerInRaw: PolishEvalScoring.retainsFiller(raw),
                    retainedFillerInOutput: PolishEvalScoring.retainsFiller(result.text),
                    rawCharacterCount: result.rawCharacterCount,
                    outputCharacterCount: result.text.count,
                    guardRejectionReason: result.guardRejection?.reason.rawValue,
                    guardRejectionCandidate: result.guardRejection?.candidateText,
                    guardRejectionCandidateCharacterCount: result.guardRejection?.candidateCharacterCount,
                    guardRejectionDiff: result.guardRejection?.diff
                ))
            }
        }

        print(Self.report(rows))
        try Self.writeJSONL(rows)
    }

    /// Disfluent dictation that an LLM is actually FOR (fillers, self-corrections,
    /// stutters, spoken punctuation, rambling) interleaved with already-clean
    /// "hallucination bait" — clean/command/symbol sentences the model must leave
    /// EXACTLY alone. Used to judge a model's RAW (unguarded) output: can it clean
    /// the mess without changing meaning or inventing text? That is the only thing
    /// that decides whether a better model could let us drop the guard.
    private static let rawBenchCorpus = [
        // --- should clean, meaning preserved ---
        "um so like we should uh ship it you know",
        "can you uh take a look at the um details and break it down",
        "send it on Tuesday no wait Wednesday",
        "the the build is is broken",
        "we need to like fix it right now basically",
        "send the report to dana comma then ping the team",
        "Tuesday no wait Wednesday works better for the demo",
        // --- hallucination bait: already clean, must stay byte-identical ---
        "What should we test first to ensure it's still working properly?",
        "Also, I noticed that the text is no longer streaming in.",
        "kill the process and then nuke the build directory",
        "Edit CLAUDE.md, then ping the team.",
        "run the script with --verbose and point it at $HOME/bin",
        "remind me to call the dentist tomorrow",
        "it's broken so just fix it",
    ]

    /// Runs the configured engine DIRECTLY — no `TranscriptPolisher`, no guard, no
    /// canonicalize-comparison — and dumps raw input→output so the model's true
    /// behavior can be judged. Run once per model and diff the files:
    ///
    ///   EPOS_RUN_POLISH_EVAL=1 swift test --filter PolishEvalTests/testRawEngineModelBench
    ///   EPOS_POLISH_ENGINE=ollama EPOS_OLLAMA_MODEL=qwen3:4b EPOS_RUN_POLISH_EVAL=1 \
    ///     swift test --filter PolishEvalTests/testRawEngineModelBench
    func testRawEngineModelBench() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["EPOS_RUN_POLISH_EVAL"] == "1" else {
            throw XCTSkip("Set EPOS_RUN_POLISH_EVAL=1 to run the on-device polish eval")
        }
        let engine = try await Self.makeConfiguredPolishEngine(environment: environment)
        let canonicalizer = TranscriptCanonicalizer.load()
        let knownTerms = ["Epos"] + canonicalizer.canonicalVocabularyStrings
        // Derive the label from the ACTUALLY-configured engine, never from a raw env
        // read — a leaked EPOS_OLLAMA_MODEL in the shell profile otherwise mislabels a
        // FoundationModels run as ollama.
        let modelLabel: String
        switch PolishEngineFactory.configuredEngine(environment: environment) {
        case .foundationModels: modelLabel = "foundationmodels"
        case .ollama(let model): modelLabel = "ollama-\(model)"
        }
        let safeLabel = modelLabel.replacingOccurrences(of: ":", with: "-")

        var lines = ["", "════════ RAW engine (NO GUARD): \(modelLabel) ════════"]
        var jsonl: [String] = []
        for raw in Self.rawBenchCorpus {
            let input = canonicalizer.canonicalize(raw)
            let session = engine.makeSession(knownTerms: knownTerms)
            let output = await Self.rawPolishWithTimeout(session: session, input: input)
            let changed = output != input && !output.hasPrefix("‹")
            lines.append("\(changed ? "CHANGED" : "same   ")  in:  \(input)")
            lines.append("          out: \(output)")
            jsonl.append(#"{"model":"\#(modelLabel)","in":\#(Self.json(input)),"out":\#(Self.json(output))}"#)
        }
        print(lines.joined(separator: "\n"))
        let outURL = URL(fileURLWithPath: ".build/evals/raw-engine-\(safeLabel).jsonl")
        try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (jsonl.joined(separator: "\n") + "\n").write(to: outURL, atomically: true, encoding: .utf8)
        print("wrote \(outURL.path)")
    }

    /// Hypothesis test: the FoundationModels "I think we should ship it tomorrow"
    /// hallucination on clean input is the production prompt's inline examples
    /// ("…ship it", "…dentist tomorrow", "I think"/"we should") bleeding verbatim on
    /// the greedy decoder — NOT the model being incapable. Runs the SAME corpus
    /// through the production prompt and the example-free prompt, raw (no guard), so
    /// the two outputs sit side by side. If the example-free prompt stops inventing
    /// text, the cause is the prompt, not the model.
    ///
    ///   EPOS_RUN_POLISH_EVAL=1 swift test --filter PolishEvalTests/testFoundationModelsPromptBleedAB
    func testFoundationModelsPromptBleedAB() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["EPOS_RUN_POLISH_EVAL"] == "1" else {
            throw XCTSkip("Set EPOS_RUN_POLISH_EVAL=1 to run the on-device polish eval")
        }
        let production = FoundationModelsPolishEngine(promptStyle: .production)
        try XCTSkipUnless(production.isAvailable, "FoundationModels model unavailable in this context")
        let exampleFree = FoundationModelsPolishEngine(promptStyle: .exampleFreeStrict)
        let canonicalizer = TranscriptCanonicalizer.load()
        let knownTerms = ["Epos"] + canonicalizer.canonicalVocabularyStrings

        var lines = ["", "════ FoundationModels: production vs example-free prompt (raw, NO guard) ════"]
        for raw in Self.rawBenchCorpus {
            let input = canonicalizer.canonicalize(raw)
            let prodOut = await Self.rawPolishWithTimeout(
                session: production.makeSession(knownTerms: knownTerms), input: input
            )
            let freeOut = await Self.rawPolishWithTimeout(
                session: exampleFree.makeSession(knownTerms: knownTerms), input: input
            )
            let prodInvented = prodOut != input && !prodOut.hasPrefix("‹")
            lines.append("in:   \(input)")
            lines.append("  prod\(prodInvented ? "*" : " "): \(prodOut)")
            lines.append("  free : \(freeOut)")
        }
        print(lines.joined(separator: "\n"))
    }

    /// Tagged corpus for the model sweep. `disfluent` rows carry residual the
    /// deterministic floor (`clean()`) can't do (stutters, self-corrections, phrase
    /// fillers) — the engine must improve on `det` here. `bait-*` rows must stay
    /// byte-identical; `bait-jargon` rows additionally trap "helpful" jargon correction
    /// (Siemux→Linux), the disqualifier the old corpus couldn't catch.
    private static let sweepCorpus: [(set: String, raw: String)] = [
        // disfluent — residual past the deterministic floor
        ("disfluent", "um so like we should uh ship it you know"),
        ("disfluent", "the the build is is broken"),
        ("disfluent", "send it on Tuesday no wait Wednesday"),
        ("disfluent", "Tuesday no wait Wednesday works better for the demo"),
        ("disfluent", "we need to like fix it right now basically"),
        ("disfluent", "so I was thinking like we could just um refactor the parser"),
        ("disfluent", "i think we should uh just ship the feature you know"),
        ("disfluent", "can you uh take a look at the um details and break it down"),
        // bait-clean — already clean / command / code / path / spoken-punctuation
        ("bait-clean", "What should we test first to ensure it's still working properly?"),
        ("bait-clean", "Also, I noticed that the text is no longer streaming in."),
        ("bait-clean", "kill the process and then nuke the build directory"),
        ("bait-clean", "Edit CLAUDE.md, then ping the team."),
        ("bait-clean", "run the script with --verbose and point it at $HOME/bin"),
        ("bait-clean", "remind me to call the dentist tomorrow"),
        ("bait-clean", "it's broken so just fix it"),
        ("bait-clean", "send the report to dana comma then ping the team"),
        // bait-jargon — real-clip rows; jargon/names must survive verbatim
        ("bait-jargon", "Ask Stas to review the CMOX changes."),
        ("bait-jargon", "Stath pushed the fix to Siemux last night."),
        ("bait-jargon", "Open cloud.md and update the project.yamo."),
        ("bait-jargon", "Semux keeps crashing when stuff runs it."),
        ("bait-jargon", "Edit cloud.md, then ping stuff."),
    ]

    /// The long-running, unattended sweep. For every installed candidate model, every
    /// prompt style, and both known-terms conditions (polluted prod list vs none),
    /// runs the RAW engine over `sweepCorpus`, scoring each cell against the
    /// deterministic floor `det = clean(canon)` — never against `raw`, so `um/uh`
    /// removal is correctly zero-credit. Captures latency and system-prompt length
    /// (the num_ctx=2048 truncation confound). Writes one JSONL row per cell to
    /// `.build/evals/sweep.jsonl` for the skeptical Claude judge pass.
    ///
    ///   EPOS_RUN_POLISH_EVAL=1 swift test --filter PolishEvalTests/testLocalModelSweep
    ///   EPOS_SWEEP_MODELS=gemma4:e2b,qwen3:4b EPOS_RUN_POLISH_EVAL=1 swift test --filter PolishEvalTests/testLocalModelSweep
    func testLocalModelSweep() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["EPOS_RUN_POLISH_EVAL"] == "1" else {
            throw XCTSkip("Set EPOS_RUN_POLISH_EVAL=1 to run the on-device polish sweep")
        }
        let candidates = (environment["EPOS_SWEEP_MODELS"].map {
            $0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        }) ?? ["qwen3:1.7b", "qwen3:4b", "gemma4:e2b", "gemma4:e4b"]

        let canonicalizer = TranscriptCanonicalizer.load()
        let pollutedKnownTerms = ["Epos"] + canonicalizer.canonicalVocabularyStrings
        let ktVariants: [(label: String, terms: [String])] = [
            ("polluted", pollutedKnownTerms),
            ("none", []),
        ]
        let styles = OllamaPolishPromptStyle.allCases

        struct Prepared { let set: String; let raw: String; let canon: String; let det: String }
        let prepared = Self.sweepCorpus.map { row -> Prepared in
            let canon = canonicalizer.canonicalize(row.raw)
            return Prepared(set: row.set, raw: row.raw, canon: canon, det: TranscriptDeterministicCleaner.clean(canon))
        }

        var jsonl: [String] = []
        var summary: [String] = ["", "════════ Local model sweep ════════"]
        for model in candidates {
            guard await OllamaPolishEngine(model: model).isModelInstalled() else {
                summary.append("· \(model): NOT INSTALLED — skipped")
                continue
            }
            for style in styles {
                for kt in ktVariants {
                    let engine = OllamaPolishEngine(
                        model: model,
                        promptStyle: style,
                        prewarmEnabled: false,
                        polishKeepAlive: "5m"
                    )
                    let session = engine.makeSession(knownTerms: kt.terms)
                    let promptChars = OllamaPolishPrompt.makeInstructions(knownTerms: kt.terms, promptStyle: style).count
                    var disfluentImproved = 0, baitDefects = 0, errors = 0
                    var totalLatencyMs = 0.0
                    for prep in prepared {
                        let start = DispatchTime.now()
                        let out = await Self.rawPolishWithTimeout(session: session, input: prep.canon)
                        let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
                        totalLatencyMs += ms
                        let isError = out.hasPrefix("‹")
                        let changedFromCanon = out != prep.canon
                        let changedFromDet = out != prep.det
                        if isError { errors += 1 }
                        else if prep.set == "disfluent", changedFromDet { disfluentImproved += 1 }
                        else if prep.set.hasPrefix("bait"), changedFromCanon { baitDefects += 1 }
                        jsonl.append(#"{"model":\#(Self.json(model)),"prompt":\#(Self.json(style.rawValue)),"kt":\#(Self.json(kt.label)),"set":\#(Self.json(prep.set)),"raw":\#(Self.json(prep.raw)),"canon":\#(Self.json(prep.canon)),"det":\#(Self.json(prep.det)),"out":\#(Self.json(out)),"changedFromCanon":\#(changedFromCanon),"changedFromDet":\#(changedFromDet),"error":\#(isError),"latencyMs":\#(Int(ms)),"promptChars":\#(promptChars)}"#)
                    }
                    let avg = totalLatencyMs / Double(prepared.count)
                    summary.append(
                        "· \(model) [\(style.rawValue)/\(kt.label)] residual+:\(disfluentImproved)/8 baitDefects:\(baitDefects)/13 err:\(errors) avg:\(Int(avg))ms prompt:\(promptChars)c"
                    )
                }
            }
        }

        print(summary.joined(separator: "\n"))
        let outURL = URL(fileURLWithPath: ".build/evals/sweep.jsonl")
        try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (jsonl.joined(separator: "\n") + "\n").write(to: outURL, atomically: true, encoding: .utf8)
        print("wrote \(outURL.path) (\(jsonl.count) cells)")
    }

    /// Round-2 adversarial corpus: disfluency wrapped around a TRAP that must survive
    /// cleaning. Targets the failure modes round 1 surfaced — proper-noun/jargon
    /// corruption (e4b "fixed" Stath→Stan), dropped command verbs (qwen dropped Edit), and
    /// the deadliest silent error of all: a dropped negation that inverts meaning. Each row
    /// names the tokens whose loss/alteration is a hard fail, so the judge can check precisely.
    private static let adversarialCorpus: [(set: String, raw: String, mustPreserve: [String])] = [
        // jargon / proper-noun survival while cleaning
        ("disfluent", "so um the the cmux backend uh keeps you know crashing", ["cmux", "crashing"]),
        ("disfluent", "uh Stas said the the SpeechAnalyzer um needs you know more memory", ["Stas", "SpeechAnalyzer", "memory"]),
        ("disfluent", "um the the xcodegen uh config in project dot yml you know needs updating", ["xcodegen", "project", "updating"]),
        ("disfluent", "the um AXInsertionTargetObserver uh isn't you know firing", ["AXInsertionTargetObserver", "firing"]),
        // command-verb survival
        ("disfluent", "um Edit the the Package dot swift and uh run swift build you know", ["Edit", "Package", "build"]),
        ("disfluent", "uh don't um delete the the entitlements file you know", ["don't", "delete", "entitlements"]),
        // NEGATION / meaning-flip — dropping the negation silently inverts meaning
        ("disfluent", "the um the test doesn't uh pass you know", ["doesn't", "pass"]),
        ("disfluent", "we should uh never like merge this you know", ["never", "merge"]),
        ("disfluent", "it's uh no longer um streaming you know", ["no longer", "streaming"]),
        // self-correction must resolve to / keep the FINAL value, not the abandoned one
        ("disfluent", "send it Monday no wait um Tuesday no actually Wednesday", ["Wednesday"]),
        ("disfluent", "we need uh like 3 no wait um 5 instances you know", ["5", "instances"]),
        // numbers / quantities must not drift
        ("disfluent", "the the timeout is uh 30 um seconds you know", ["30", "seconds"]),
        // blunt wording must be kept (no euphemizing)
        ("disfluent", "the damn um build is uh still you know broken", ["damn", "broken"]),
        // long realistic ramble
        ("disfluent", "so basically um I was thinking like we could uh maybe you know refactor the the transcriber to um use the the new API you know", ["refactor", "transcriber", "API"]),
        // already-clean technical bait — must stay byte-identical
        ("bait", "The SpeechTranscriber emits punctuation intrinsically.", ["SpeechTranscriber", "punctuation", "intrinsically"]),
        ("bait", "Run swift build with warnings as errors before committing.", ["swift", "build", "warnings", "committing"]),
    ]

    /// Runs the round-1 shortlist (the 0-HARMFUL configs) over the adversarial corpus,
    /// realistic kt=polluted. Writes `.build/evals/sweep-adversarial.jsonl` with the
    /// per-row `mustPreserve` list for a trap-aware judge.
    ///
    ///   EPOS_RUN_POLISH_EVAL=1 swift test --filter PolishEvalTests/testAdversarialChallenge
    func testAdversarialChallenge() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["EPOS_RUN_POLISH_EVAL"] == "1" else {
            throw XCTSkip("Set EPOS_RUN_POLISH_EVAL=1 to run the adversarial challenge")
        }
        let shortlist: [(model: String, style: OllamaPolishPromptStyle)] = [
            ("gemma4:e2b", .conservative),
            ("gemma4:e2b", .relaxed),
            ("gemma4:e4b", .conservative),
            ("qwen3:4b", .relaxed),
        ]
        let canonicalizer = TranscriptCanonicalizer.load()
        let knownTerms = ["Epos"] + canonicalizer.canonicalVocabularyStrings
        let prepared = Self.adversarialCorpus.map {
            (set: $0.set, raw: $0.raw, canon: canonicalizer.canonicalize($0.raw), mustPreserve: $0.mustPreserve)
        }

        var jsonl: [String] = []
        var summary = ["", "════════ Adversarial challenge ════════"]
        for config in shortlist {
            guard await OllamaPolishEngine(model: config.model).isModelInstalled() else {
                summary.append("· \(config.model): NOT INSTALLED — skipped"); continue
            }
            let engine = OllamaPolishEngine(model: config.model, promptStyle: config.style, prewarmEnabled: false, polishKeepAlive: "5m")
            let session = engine.makeSession(knownTerms: knownTerms)
            for prep in prepared {
                let start = DispatchTime.now()
                let out = await Self.rawPolishWithTimeout(session: session, input: prep.canon)
                let ms = Int(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
                let preserved = #"[\#(prep.mustPreserve.map { Self.json($0) }.joined(separator: ","))]"#
                jsonl.append(#"{"model":\#(Self.json(config.model)),"prompt":\#(Self.json(config.style.rawValue)),"set":\#(Self.json(prep.set)),"canon":\#(Self.json(prep.canon)),"out":\#(Self.json(out)),"mustPreserve":\#(preserved),"latencyMs":\#(ms)}"#)
            }
            summary.append("· \(config.model)/\(config.style.rawValue): done")
        }
        print(summary.joined(separator: "\n"))
        let outURL = URL(fileURLWithPath: ".build/evals/sweep-adversarial.jsonl")
        try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (jsonl.joined(separator: "\n") + "\n").write(to: outURL, atomically: true, encoding: .utf8)
        print("wrote \(outURL.path) (\(jsonl.count) cells)")
    }

    /// Round 3 — the STEELMAN for LLM polish. Messy dictation that a deterministic rule
    /// (filler removal + adjacent-dup dedup) provably CANNOT clean: abandoned false-starts,
    /// phrase-level repeats, meta-filler clauses, hedge pile-ups, filler-dense run-ons. If an
    /// LLM has any unique SAFE value, it shows here; if it still only no-ops (safe-useless) or
    /// damages content (unsafe), "not worth it" is confirmed on hard cases too. mustPreserve =
    /// the content whose loss is meaning damage; several rows are TRAPS where the tempting
    /// "clean" drops a hedge that carries degree ("kind of broken" != "broken") or an
    /// abandoned clause that was a real second intent.
    private static let hardCorpus: [(set: String, raw: String, mustPreserve: [String])] = [
        ("hard", "send it to uh send it to the whole team", ["send it to the whole team"]),                                  // phrase-level repeat (not single-word dedup)
        ("hard", "basically what i'm trying to say is we should just ship it", ["we should just ship it"]),                   // meta-filler clause
        ("hard", "so um yeah the the API like basically returns null when uh the cache is you know empty", ["API", "returns null", "cache", "empty"]), // filler-dense run-on
        ("hard", "we should merge no we should rebase first", ["rebase first"]),                                             // restart with correction (must resolve to rebase, not merge)
        ("hard", "the bug the one in the parser is fixed now", ["bug", "parser", "fixed"]),                                  // self-interrupting clarification
        ("hard", "the the thing the widget is broken", ["widget", "broken"]),                                               // abandoned noun-search
        ("hard", "can you uh i guess maybe look at the parser", ["look at the parser"]),                                     // politeness/hedge padding
        ("hard", "we need like five or six maybe let's say five instances", ["five instances"]),                            // number reasoning resolving to a value
        ("hard", "i mean it's kind of sort of broken", ["kind of", "broken"]),                                              // TRAP: hedges carry degree, dropping them changes meaning
        ("hard", "we need a cache uh actually let's refactor the parser first", ["refactor the parser first"]),             // TRAP: abandoned clause may be a real 2nd intent — keeping both is safe
        ("hard", "it works on my machine but um it doesn't work in CI you know", ["doesn't work in CI"]),                    // TRAP: contrast + negation must survive
        ("hard", "let's meet monday or uh actually tuesday works better", ["tuesday"]),                                      // self-correction of a day
        ("hard", "the the deadline is friday no wait it's thursday", ["thursday"]),                                          // correction resolving to thursday
        ("hard", "honestly at the end of the day we just need to fix the the flaky test", ["fix", "flaky test"]),            // discourse padding + dedup
    ]

    /// Runs the round-1 shortlist over `hardCorpus`. Writes `.build/evals/sweep-hard.jsonl`
    /// for the unbiased panel that asks: SAFE? and did-it-do-something-deterministic-can't?
    ///
    ///   EPOS_RUN_POLISH_EVAL=1 swift test --filter PolishEvalTests/testHardDictationChallenge
    func testHardDictationChallenge() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["EPOS_RUN_POLISH_EVAL"] == "1" else {
            throw XCTSkip("Set EPOS_RUN_POLISH_EVAL=1 to run the hard-dictation challenge")
        }
        let shortlist: [(model: String, style: OllamaPolishPromptStyle)] = [
            ("gemma4:e2b", .conservative),
            ("gemma4:e2b", .relaxed),
            ("gemma4:e4b", .conservative),
            ("qwen3:4b", .relaxed),
        ]
        let canonicalizer = TranscriptCanonicalizer.load()
        let knownTerms = ["Epos"] + canonicalizer.canonicalVocabularyStrings
        let det = { (s: String) in TranscriptDeterministicCleaner.clean(s) }
        let prepared = Self.hardCorpus.map {
            (set: $0.set, raw: $0.raw, canon: canonicalizer.canonicalize($0.raw), mustPreserve: $0.mustPreserve)
        }

        var jsonl: [String] = []
        var summary = ["", "════════ Hard dictation challenge ════════"]
        for config in shortlist {
            guard await OllamaPolishEngine(model: config.model).isModelInstalled() else {
                summary.append("· \(config.model): NOT INSTALLED — skipped"); continue
            }
            let engine = OllamaPolishEngine(model: config.model, promptStyle: config.style, prewarmEnabled: false, polishKeepAlive: "5m")
            let session = engine.makeSession(knownTerms: knownTerms)
            for prep in prepared {
                let out = await Self.rawPolishWithTimeout(session: session, input: prep.canon)
                let preserved = #"[\#(prep.mustPreserve.map { Self.json($0) }.joined(separator: ","))]"#
                jsonl.append(#"{"model":\#(Self.json(config.model)),"prompt":\#(Self.json(config.style.rawValue)),"set":\#(Self.json(prep.set)),"canon":\#(Self.json(prep.canon)),"det":\#(Self.json(det(prep.canon))),"out":\#(Self.json(out)),"mustPreserve":\#(preserved)}"#)
            }
            summary.append("· \(config.model)/\(config.style.rawValue): done")
        }
        print(summary.joined(separator: "\n"))
        let outURL = URL(fileURLWithPath: ".build/evals/sweep-hard.jsonl")
        try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (jsonl.joined(separator: "\n") + "\n").write(to: outURL, atomically: true, encoding: .utf8)
        print("wrote \(outURL.path) (\(jsonl.count) cells)")
    }

    private static func rawPolishWithTimeout(session: any PolishSession, input: String) async -> String {
        await withTaskGroup(of: String?.self) { group in
            group.addTask {
                do { return try await session.polish(input) }
                catch { return "‹ERROR: \(error)›" }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                return "‹TIMEOUT›"
            }
            let result = await group.next() ?? "‹nil›"
            group.cancelAll()
            return result ?? "‹nil›"
        }
    }

    private static func json(_ value: String) -> String {
        String(decoding: (try? JSONEncoder().encode(value)) ?? Data("\"\"".utf8), as: UTF8.self)
    }

    private static func makeConfiguredPolishEngine(environment: [String: String]) async throws -> any PolishEngine {
        switch PolishEngineFactory.configuredEngine(environment: environment) {
        case .foundationModels:
            let engine = FoundationModelsPolishEngine()
            try XCTSkipUnless(engine.isAvailable, "FoundationModels model unavailable in this context")
            return engine
        case .ollama(let model):
            let engine = OllamaPolishEngine(model: model)
            guard await engine.isModelInstalled() else {
                throw XCTSkip("Ollama model \(model) unavailable; run `ollama pull \(model)`")
            }
            return engine
        }
    }

    private static func report(_ rows: [PolishEvalRow]) -> String {
        var lines = ["", "════════ Polish eval ════════"]
        for row in rows {
            var tags = ["<\(row.outcome)>", "engine=<\(row.engineOutcome ?? "not-attempted")>"]
            if row.rawChangedByCanonicalizer { tags.append("CANON") }
            if row.outputChangedFromCanonicalizedRaw { tags.append("POLISHED") }
            if row.retainedFillerInOutput { tags.append("FILLER-LEFT") }
            lines.append("[\(row.set)] \(tags.joined(separator: " "))")
            lines.append("  raw: \(row.raw)")
            if row.rawChangedByCanonicalizer {
                lines.append("  can: \(row.canonicalizedRaw)")
            }
            lines.append("  out: \(row.output)")
            if let candidate = row.guardRejectionCandidate {
                lines.append("  candidate: \(candidate)")
            }
            if let reason = row.guardRejectionReason, let diff = row.guardRejectionDiff {
                lines.append("  rejection: \(reason) \(diff)")
            }
        }
        let applied = rows.filter { $0.outcome == "applied" }.count
        let canonicalizerChanged = rows.filter(\.rawChangedByCanonicalizer).count
        let polishChanged = rows.filter(\.outputChangedFromCanonicalizedRaw).count
        let retainedFillerRaw = rows.filter(\.retainedFillerInRaw).count
        let retainedFillerOutput = rows.filter(\.retainedFillerInOutput).count
        let totalPrewarmWait = rows.reduce(0) { $0 + $1.prewarmWaitSeconds }
        lines.append("")
        lines.append("rows: \(rows.count)  applied: \(applied)")
        lines.append("canonicalizer changed raw: \(canonicalizerChanged)")
        lines.append("polish changed canonicalized raw: \(polishChanged)")
        lines.append("retained filler raw/output: \(retainedFillerRaw)/\(retainedFillerOutput)")
        lines.append("outcomes: \(outcomeSummary(rows))")
        lines.append("engine outcomes: \(engineOutcomeSummary(rows))")
        lines.append("guard rejections: \(guardRejectionSummary(rows))")
        lines.append("prewarm wait total: \(String(format: "%.3f", totalPrewarmWait))s")
        lines.append("(inspect every row for meaning changes — that is the safety bar; retainedFiller is the quality miss count)")
        return lines.joined(separator: "\n")
    }

    private static func outcomeSummary(_ rows: [PolishEvalRow]) -> String {
        rows
            .reduce(into: [String: Int]()) { counts, row in counts[row.outcome, default: 0] += 1 }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ", ")
    }

    private static func engineOutcomeSummary(_ rows: [PolishEvalRow]) -> String {
        let counts = rows.reduce(into: [String: Int]()) { counts, row in
            counts[row.engineOutcome ?? "not-attempted", default: 0] += 1
        }
        return counts
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ", ")
    }

    private static func guardRejectionSummary(_ rows: [PolishEvalRow]) -> String {
        let counts = rows.reduce(into: [String: Int]()) { counts, row in
            guard let reason = row.guardRejectionReason else { return }
            counts[reason, default: 0] += 1
        }
        guard !counts.isEmpty else { return "none" }
        return counts
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ", ")
    }

    private static func writeJSONL(_ rows: [PolishEvalRow]) throws {
        let outputURL = URL(fileURLWithPath: ".build/evals/polish-eval.jsonl")
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let body = try rows.map { try String(decoding: JSONEncoder().encode($0), as: UTF8.self) }.joined(separator: "\n")
        try (body + "\n").write(to: outputURL, atomically: true, encoding: .utf8)
    }
}

private struct PolishEvalRow: Codable {
    let set: String
    let raw: String
    let canonicalizedRaw: String
    let output: String
    let outcome: String
    let engineOutcome: String?
    let prewarmWaitSeconds: Double
    let rawChangedByCanonicalizer: Bool
    let outputChangedFromRaw: Bool
    let outputChangedFromCanonicalizedRaw: Bool
    let retainedFillerInRaw: Bool
    let retainedFillerInOutput: Bool
    let rawCharacterCount: Int
    let outputCharacterCount: Int
    let guardRejectionReason: String?
    let guardRejectionCandidate: String?
    let guardRejectionCandidateCharacterCount: Int?
    let guardRejectionDiff: String?
}
