import XCTest
@testable import Epos

/// Local Ollama polish bakeoff for small models. The first target is
/// `qwen3:1.7b`: low memory footprint, local-only, and unloaded after each real
/// polish call via `keep_alive: 0`.
///
/// Skipped unless explicitly enabled and the model is already installed:
///
///   ollama pull qwen3:1.7b
///   EPOS_RUN_OLLAMA_POLISH_EVAL=1 swift test --filter OllamaPolishEvalTests
///
/// Optional knobs:
/// - `EPOS_OLLAMA_MODEL`: defaults to `qwen3:1.7b`
/// - `EPOS_EVAL_LIMIT`: number of transcripts to replay
/// - `EPOS_EVAL_OUTPUT`: defaults to `.build/evals/ollama-polish-eval.jsonl`
///   for `EPOS_RUN_OLLAMA_POLISH_EVAL`, or `.build/evals/ollama-raw-candidate-eval.jsonl`
///   for `EPOS_RUN_OLLAMA_RAW_CANDIDATE_EVAL`
/// - `EPOS_POLISH_EVAL_PREWARM_MS`: defaults to 1500, use 0 for cold-start stress
/// - Prompt styles are compared by default: conservative is the production
///   prompt, strict is the original FoundationModels-compatible prompt, and
///   relaxed is eval-only shadow mode for measuring broader model capability.
/// - `EPOS_OLLAMA_EVAL_PROMPT_STYLES`: optional comma-separated prompt styles.
/// - `EPOS_RUN_OLLAMA_RAW_CANDIDATE_EVAL=1`: bypasses `TranscriptPolisher` and
///   logs raw relaxed candidates plus the strict guard decision as diagnostics.
/// - `EPOS_RUN_OLLAMA_RESIDUAL_BAKEOFF=1`: runs selected residual dogfood rows
///   through prompt/model variants and scores candidate plus strict-gate output
///   against human ground truth.
final class OllamaPolishEvalTests: XCTestCase {
    private static let transcripts = [
        "It seems like you're saying that the polish is not working.",
        "Can we take a look at the details of this and break it down some more?",
        "What should we test 1st to ensure that it's still working properly?",
        "Also, I noticed that the text is no longer streaming in like it used to be.",
        "um so like we should uh ship it you know",
        "so I was thinking like we could just um refactor the parser",
        "send the report to dana comma then ping the team",
        "kill the process and then nuke the build directory",
        "Tuesday no wait Wednesday works better for the demo",
        "the damn thing crashed again so basically we lost the data",
    ]

    func testQwenPolishOverCorpus() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard SavedRecordingEvalSupport.isTruthy(environment["EPOS_RUN_OLLAMA_POLISH_EVAL"]) else {
            throw XCTSkip("Set EPOS_RUN_OLLAMA_POLISH_EVAL=1 to run the Ollama polish eval")
        }

        let model = environment["EPOS_OLLAMA_MODEL"] ?? OllamaPolishEngine.defaultModel
        let availabilityEngine = OllamaPolishEngine(model: model, prewarmEnabled: false)
        guard await availabilityEngine.isModelInstalled() else {
            throw XCTSkip("Ollama model \(model) unavailable; run `ollama pull \(model)`")
        }

        let outputURL = SavedRecordingEvalSupport.outputURL(
            environment: environment,
            defaultPath: ".build/evals/ollama-polish-eval.jsonl"
        )
        try SavedRecordingEvalSupport.prepareOutput(outputURL)

        let canonicalizer = TranscriptCanonicalizer.load()
        let knownTerms = ["Epos"] + canonicalizer.canonicalVocabularyStrings
        let limit = environment["EPOS_EVAL_LIMIT"].flatMap(Int.init)
        let transcripts = Array(Self.transcripts.prefix(limit ?? Self.transcripts.count))
        let prewarmDelay = SavedRecordingEvalSupport.polishPrewarmSettleNanoseconds(environment: environment)

        let variants = Self.variants(
            model: model,
            styles: Self.configuredPromptStyles(environment: environment),
            prewarmDelay: prewarmDelay
        )

        var rows: [OllamaPolishEvalRow] = []
        for variant in variants {
            for raw in transcripts {
                let engine = OllamaPolishEngine(
                    model: model,
                    promptStyle: variant.promptStyle,
                    prewarmEnabled: variant.prewarmEnabled
                )
                let canonicalizedRaw = canonicalizer.canonicalize(raw)
                let deterministicOutput = TranscriptDeterministicCleaner.clean(canonicalizedRaw)
                let polisher = TranscriptPolisher(
                    enabled: true,
                    engine: engine,
                    knownTerms: knownTerms,
                    canonicalize: { canonicalizer.canonicalize($0) }
                )
                polisher.prewarm()
                let prewarmWaitSeconds = await SavedRecordingEvalSupport.waitForPolishPrewarmSettle(
                    delayNanoseconds: variant.prewarmWait
                )

                let started = Date()
                let result = await polisher.polish(raw)
                let elapsedSeconds = Date().timeIntervalSince(started)
                let row = OllamaPolishEvalRow(
                    variant: variant.name,
                    model: model,
                    promptStyle: variant.promptStyle.rawValue,
                    prewarmEnabled: variant.prewarmEnabled,
                    raw: raw,
                    canonicalizedRaw: canonicalizedRaw,
                    deterministicOutput: deterministicOutput,
                    output: result.text,
                    outcome: String(describing: result.outcome),
                    engineOutcome: result.engineOutcome?.rawValue,
                    prewarmWaitSeconds: prewarmWaitSeconds,
                    elapsedSeconds: elapsedSeconds,
                    rawCharacterCount: result.rawCharacterCount,
                    outputCharacterCount: result.text.count,
                    outputChangedFromCanonicalizedRaw: result.text != canonicalizedRaw,
                    outputChangedFromDeterministic: result.text != deterministicOutput,
                    retainedFillerInRaw: PolishEvalScoring.retainsFiller(raw),
                    retainedFillerInOutput: PolishEvalScoring.retainsFiller(result.text),
                    guardRejectionReason: result.guardRejection?.reason.rawValue,
                    guardRejectionCandidate: result.guardRejection?.candidateText,
                    guardRejectionDiff: result.guardRejection?.diff
                )
                rows.append(row)
                try SavedRecordingEvalSupport.appendJSONL(row, to: outputURL)
            }
        }

        print(Self.report(rows: rows, outputURL: outputURL))
    }

    func testRelaxedRawCandidatesBypassPolisherOverCorpus() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard SavedRecordingEvalSupport.isTruthy(environment["EPOS_RUN_OLLAMA_RAW_CANDIDATE_EVAL"]) else {
            throw XCTSkip("Set EPOS_RUN_OLLAMA_RAW_CANDIDATE_EVAL=1 to run the raw candidate eval")
        }

        let model = environment["EPOS_OLLAMA_MODEL"] ?? OllamaPolishEngine.defaultModel
        let availabilityEngine = OllamaPolishEngine(model: model, prewarmEnabled: false)
        guard await availabilityEngine.isModelInstalled() else {
            throw XCTSkip("Ollama model \(model) unavailable; run `ollama pull \(model)`")
        }

        let outputURL = SavedRecordingEvalSupport.outputURL(
            environment: environment,
            defaultPath: ".build/evals/ollama-raw-candidate-eval.jsonl"
        )
        try SavedRecordingEvalSupport.prepareOutput(outputURL)

        let canonicalizer = TranscriptCanonicalizer.load()
        let knownTerms = ["Epos"] + canonicalizer.canonicalVocabularyStrings
        let limit = environment["EPOS_EVAL_LIMIT"].flatMap(Int.init)
        let transcripts = Array(Self.transcripts.prefix(limit ?? Self.transcripts.count))
        let prewarmDelay = SavedRecordingEvalSupport.polishPrewarmSettleNanoseconds(environment: environment)

        let variants = [
            OllamaPolishEvalVariant(
                name: "\(model)-relaxed-raw-cold",
                promptStyle: .relaxed,
                prewarmEnabled: false,
                prewarmWait: 0
            ),
            OllamaPolishEvalVariant(
                name: "\(model)-relaxed-raw-prewarm",
                promptStyle: .relaxed,
                prewarmEnabled: true,
                prewarmWait: prewarmDelay
            ),
        ]

        var rows: [OllamaRawCandidateEvalRow] = []
        for variant in variants {
            for raw in transcripts {
                let engine = OllamaPolishEngine(
                    model: model,
                    promptStyle: variant.promptStyle,
                    prewarmEnabled: variant.prewarmEnabled
                )
                let session = engine.makeSession(knownTerms: knownTerms)
                let prewarmWaitSeconds = await SavedRecordingEvalSupport.waitForPolishPrewarmSettle(
                    delayNanoseconds: variant.prewarmWait
                )
                let canonicalizedRaw = canonicalizer.canonicalize(raw)
                let deterministicOutput = TranscriptDeterministicCleaner.clean(canonicalizedRaw)
                let candidate = await OllamaRawCandidateEvalSupport.evaluate(
                    raw: raw,
                    canonicalizedRaw: canonicalizedRaw,
                    deterministicOutput: deterministicOutput,
                    session: session,
                    canonicalize: { canonicalizer.canonicalize($0) }
                )
                let row = OllamaRawCandidateEvalRow(
                    variant: variant.name,
                    model: model,
                    promptStyle: variant.promptStyle.rawValue,
                    prewarmEnabled: variant.prewarmEnabled,
                    prewarmWaitSeconds: prewarmWaitSeconds,
                    raw: raw,
                    canonicalizedRaw: canonicalizedRaw,
                    deterministicOutput: deterministicOutput,
                    retainedFillerInRaw: PolishEvalScoring.retainsFiller(raw),
                    candidate: candidate
                )
                rows.append(row)
                try SavedRecordingEvalSupport.appendJSONL(row, to: outputURL)
            }
        }

        print(Self.rawCandidateReport(rows: rows, outputURL: outputURL))
    }

    func testResidualRowsPromptModelBakeoff() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard SavedRecordingEvalSupport.isTruthy(environment["EPOS_RUN_OLLAMA_RESIDUAL_BAKEOFF"]) else {
            throw XCTSkip("Set EPOS_RUN_OLLAMA_RESIDUAL_BAKEOFF=1 to run the residual Ollama bakeoff")
        }

        var installedModels: [String] = []
        for model in Self.configuredModels(environment: environment) {
            let availabilityEngine = OllamaPolishEngine(model: model, prewarmEnabled: false)
            if await availabilityEngine.isModelInstalled() {
                installedModels.append(model)
            } else {
                print("Skipping unavailable Ollama model: \(model)")
            }
        }
        try XCTSkipIf(installedModels.isEmpty, "No configured Ollama models are installed")

        let outputURL = SavedRecordingEvalSupport.outputURL(
            environment: environment,
            defaultPath: ".build/evals/ollama-residual-bakeoff.jsonl"
        )
        try SavedRecordingEvalSupport.prepareOutput(outputURL)

        let sourceURL = Self.residualSourceURL(environment: environment)
        let residualRows = try Self.loadResidualSourceRows(
            from: sourceURL,
            minOutputWER: Self.residualMinimumOutputWER(environment: environment),
            limit: environment["EPOS_EVAL_LIMIT"].flatMap(Int.init)
        )
        try XCTSkipIf(residualRows.isEmpty, "No residual rows found in \(sourceURL.path)")

        let canonicalizer = TranscriptCanonicalizer.load()
        let knownTerms = ["Epos"] + canonicalizer.canonicalVocabularyStrings
        let prewarmDelay = SavedRecordingEvalSupport.polishPrewarmSettleNanoseconds(environment: environment)
        let promptStyles = Self.configuredPromptStyles(environment: environment)

        var rows: [OllamaResidualBakeoffRow] = []
        for model in installedModels {
            let variants = Self.variants(model: model, styles: promptStyles, prewarmDelay: prewarmDelay)
            for variant in variants {
                for sourceRow in residualRows {
                    guard let humanIntendedTranscript = sourceRow.humanIntendedTranscript,
                          let sourceOutputScore = sourceRow.outputTranscriptScore else {
                        continue
                    }

                    let engine = OllamaPolishEngine(
                        model: model,
                        promptStyle: variant.promptStyle,
                        prewarmEnabled: variant.prewarmEnabled
                    )
                    let session = engine.makeSession(knownTerms: knownTerms)
                    let prewarmWaitSeconds = await SavedRecordingEvalSupport.waitForPolishPrewarmSettle(
                        delayNanoseconds: variant.prewarmWait
                    )
                    let canonicalizedRaw = canonicalizer.canonicalize(sourceRow.rawTranscript)
                    let deterministicOutput = TranscriptDeterministicCleaner.clean(canonicalizedRaw)
                    let candidate = await OllamaRawCandidateEvalSupport.evaluate(
                        raw: sourceRow.rawTranscript,
                        canonicalizedRaw: canonicalizedRaw,
                        deterministicOutput: deterministicOutput,
                        session: session,
                        canonicalize: { canonicalizer.canonicalize($0) }
                    )
                    let strictGateOutput = candidate.strictGateOutput ?? canonicalizedRaw
                    let row = OllamaResidualBakeoffRow(
                        variant: variant.name,
                        model: model,
                        promptStyle: variant.promptStyle.rawValue,
                        prewarmEnabled: variant.prewarmEnabled,
                        prewarmWaitSeconds: prewarmWaitSeconds,
                        sourceFile: sourceRow.file,
                        humanIntendedTranscript: humanIntendedTranscript,
                        raw: sourceRow.rawTranscript,
                        canonicalizedRaw: canonicalizedRaw,
                        sourceOutput: sourceRow.output,
                        sourceOutcome: sourceRow.outcome,
                        sourceOutputTranscriptScore: sourceOutputScore,
                        rawTranscriptScore: PolishEvalScoring.wordErrorScore(
                            reference: humanIntendedTranscript,
                            hypothesis: sourceRow.rawTranscript
                        ),
                        canonicalizedRawTranscriptScore: PolishEvalScoring.wordErrorScore(
                            reference: humanIntendedTranscript,
                            hypothesis: canonicalizedRaw
                        ),
                        candidateTranscriptScore: candidate.candidate.map {
                            PolishEvalScoring.wordErrorScore(reference: humanIntendedTranscript, hypothesis: $0)
                        },
                        canonicalizedCandidateTranscriptScore: candidate.canonicalizedCandidate.map {
                            PolishEvalScoring.wordErrorScore(reference: humanIntendedTranscript, hypothesis: $0)
                        },
                        strictGateOutput: strictGateOutput,
                        strictGateOutputTranscriptScore: PolishEvalScoring.wordErrorScore(
                            reference: humanIntendedTranscript,
                            hypothesis: strictGateOutput
                        ),
                        strictGateOutputChangedFromCanonicalizedRaw: strictGateOutput != canonicalizedRaw,
                        strictGateOutputChangedFromSourceOutput: strictGateOutput != sourceRow.output,
                        retainedFillerInRaw: PolishEvalScoring.retainsFiller(sourceRow.rawTranscript),
                        retainedFillerInStrictGateOutput: PolishEvalScoring.retainsFiller(strictGateOutput),
                        candidate: candidate
                    )
                    rows.append(row)
                    try SavedRecordingEvalSupport.appendJSONL(row, to: outputURL)
                }
            }
        }

        print(Self.residualBakeoffReport(rows: rows, sourceURL: sourceURL, outputURL: outputURL))
    }

    private static func report(rows: [OllamaPolishEvalRow], outputURL: URL) -> String {
        var lines = ["", "Ollama polish eval"]
        for variant in stableUnique(rows.map(\.variant)) {
            let variantRows = rows.filter { $0.variant == variant }
            lines.append("")
            lines.append("[\(variant)] rows=\(variantRows.count)")
            lines.append("  outcomes: \(Self.countSummary(variantRows.map(\.outcome)))")
            lines.append("  engine outcomes: \(Self.countSummary(variantRows.map { $0.engineOutcome ?? "not-attempted" }))")
            lines.append("  guard rejections: \(Self.countSummary(variantRows.compactMap(\.guardRejectionReason)))")
            lines.append("  retained filler raw/output: \(variantRows.filter(\.retainedFillerInRaw).count)/\(variantRows.filter(\.retainedFillerInOutput).count)")
            lines.append("  changed from deterministic: \(variantRows.filter(\.outputChangedFromDeterministic).count)")
            lines.append("  mean elapsed: \(Self.formatSeconds(Self.meanElapsed(variantRows)))s")
            for row in variantRows {
                let engineOutcome = row.engineOutcome ?? "not-attempted"
                lines.append("  - <\(row.outcome)> engine=<\(engineOutcome)> elapsed=\(Self.formatSeconds(row.elapsedSeconds))s raw: \(row.raw)")
                lines.append("    out: \(row.output)")
                if let candidate = row.guardRejectionCandidate {
                    lines.append("    candidate: \(candidate)")
                }
            }
        }
        lines.append("")
        lines.append("output: \(outputURL.path)")
        return lines.joined(separator: "\n")
    }

    private static func residualBakeoffReport(
        rows: [OllamaResidualBakeoffRow],
        sourceURL: URL,
        outputURL: URL
    ) -> String {
        var lines = ["", "Ollama residual bakeoff"]
        lines.append("source: \(sourceURL.path)")
        for variant in stableUnique(rows.map(\.variant)) {
            let variantRows = rows.filter { $0.variant == variant }
            lines.append("")
            lines.append("[\(variant)] rows=\(variantRows.count)")
            lines.append("  candidate outcomes: \(Self.countSummary(variantRows.map(\.candidate.candidateOutcome)))")
            lines.append("  strict gate outcomes: \(Self.countSummary(variantRows.compactMap(\.candidate.strictGateOutcome)))")
            lines.append("  strict guard rejections: \(Self.countSummary(variantRows.compactMap(\.candidate.strictGuardRejectionReason)))")
            lines.append(
                "  mean WER raw/can/source/candidate/gate: " +
                    "\(Self.meanWER(variantRows) { $0.rawTranscriptScore })/" +
                    "\(Self.meanWER(variantRows) { $0.canonicalizedRawTranscriptScore })/" +
                    "\(Self.meanWER(variantRows) { $0.sourceOutputTranscriptScore })/" +
                    "\(Self.meanWER(variantRows) { $0.canonicalizedCandidateTranscriptScore })/" +
                    "\(Self.meanWER(variantRows) { $0.strictGateOutputTranscriptScore })"
            )
            lines.append(
                "  candidate vs canonicalized raw: " +
                    "\(Self.werDeltaSummary(variantRows) { $0.canonicalizedCandidateTranscriptScore })"
            )
            lines.append(
                "  strict gate vs canonicalized raw: " +
                    "\(Self.werDeltaSummary(variantRows) { $0.strictGateOutputTranscriptScore })"
            )
            lines.append("  strict gate changed source output: \(variantRows.filter(\.strictGateOutputChangedFromSourceOutput).count)")
            lines.append("  retained filler raw/gate: \(variantRows.filter(\.retainedFillerInRaw).count)/\(variantRows.filter(\.retainedFillerInStrictGateOutput).count)")
            lines.append("  mean elapsed: \(Self.formatSeconds(Self.meanResidualCandidateElapsed(variantRows)))s")
            for row in variantRows {
                lines.append(
                    "  - file=\(row.sourceFile) candidate=<\(row.candidate.candidateOutcome)> " +
                        "strict-gate=<\(row.candidate.strictGateOutcome ?? "not-evaluated")> " +
                        "WER can/candidate/gate=" +
                        "\(Self.formatScore(row.canonicalizedRawTranscriptScore.wordErrorRate))/" +
                        "\(Self.formatOptionalScore(row.canonicalizedCandidateTranscriptScore?.wordErrorRate))/" +
                        "\(Self.formatScore(row.strictGateOutputTranscriptScore.wordErrorRate))"
                )
                if let candidate = row.candidate.candidate {
                    lines.append("    candidate: \(candidate)")
                }
                lines.append("    gate output: \(row.strictGateOutput)")
                if let reason = row.candidate.strictGuardRejectionReason,
                   let diff = row.candidate.strictGuardRejectionDiff {
                    lines.append("    strict rejection: \(reason) \(diff)")
                }
            }
        }
        lines.append("")
        lines.append("output: \(outputURL.path)")
        return lines.joined(separator: "\n")
    }

    private static func configuredPromptStyles(environment: [String: String]) -> [OllamaPolishPromptStyle] {
        let rawStyles = environment["EPOS_OLLAMA_EVAL_PROMPT_STYLES"]?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        let styles = rawStyles?.compactMap(OllamaPolishPromptStyle.init(rawValue:))
        if let styles, !styles.isEmpty {
            return styles
        }
        return [.strict, .conservative, .relaxed]
    }

    private static func configuredModels(environment: [String: String]) -> [String] {
        if let configuredModels = environment["EPOS_OLLAMA_EVAL_MODELS"] {
            let models = configuredModels
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !models.isEmpty {
                return models
            }
        }
        let configuredModel = environment["EPOS_OLLAMA_MODEL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return [configuredModel].compactMap { model in
            guard let model, !model.isEmpty else { return OllamaPolishEngine.defaultModel }
            return model
        }
    }

    private static func residualSourceURL(environment: [String: String]) -> URL {
        fileURL(path: environment["EPOS_OLLAMA_RESIDUAL_SOURCE"] ?? ".build/evals/dogfood-pipeline-eval.jsonl")
    }

    private static func residualMinimumOutputWER(environment: [String: String]) -> Double {
        environment["EPOS_OLLAMA_RESIDUAL_MIN_OUTPUT_WER"].flatMap(Double.init) ?? 0
    }

    private static func loadResidualSourceRows(
        from sourceURL: URL,
        minOutputWER: Double,
        limit: Int?
    ) throws -> [DogfoodPipelineEvalRow] {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw XCTSkip("Residual source JSONL not found: \(sourceURL.path)")
        }

        let decoder = JSONDecoder()
        let contents = try String(contentsOf: sourceURL, encoding: .utf8)
        var residualRows: [DogfoodPipelineEvalRow] = []
        for (index, line) in contents.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            do {
                let row = try decoder.decode(DogfoodPipelineEvalRow.self, from: Data(line.utf8))
                guard row.humanIntendedTranscript != nil,
                      let outputScore = row.outputTranscriptScore,
                      outputScore.wordErrorRate > minOutputWER else {
                    continue
                }
                residualRows.append(row)
            } catch {
                throw OllamaResidualBakeoffError(
                    description: "\(sourceURL.path):\(index + 1): dogfood row decode failed: \(error)"
                )
            }
        }

        let selectedCount = limit.map { max(0, $0) } ?? residualRows.count
        return Array(residualRows.prefix(selectedCount))
    }

    private static func variants(
        model: String,
        styles: [OllamaPolishPromptStyle],
        prewarmDelay: UInt64
    ) -> [OllamaPolishEvalVariant] {
        styles.flatMap { style in
            [
                OllamaPolishEvalVariant(
                    name: "\(model)-\(style.rawValue)-cold",
                    promptStyle: style,
                    prewarmEnabled: false,
                    prewarmWait: 0
                ),
                OllamaPolishEvalVariant(
                    name: "\(model)-\(style.rawValue)-prewarm",
                    promptStyle: style,
                    prewarmEnabled: true,
                    prewarmWait: prewarmDelay
                ),
            ]
        }
    }

    private static func rawCandidateReport(rows: [OllamaRawCandidateEvalRow], outputURL: URL) -> String {
        var lines = ["", "Ollama raw relaxed candidate eval"]
        for variant in stableUnique(rows.map(\.variant)) {
            let variantRows = rows.filter { $0.variant == variant }
            lines.append("")
            lines.append("[\(variant)] rows=\(variantRows.count)")
            lines.append("  candidate outcomes: \(Self.countSummary(variantRows.map(\.candidate.candidateOutcome)))")
            lines.append("  strict gate outcomes: \(Self.countSummary(variantRows.compactMap(\.candidate.strictGateOutcome)))")
            lines.append("  strict guard rejections: \(Self.countSummary(variantRows.compactMap(\.candidate.strictGuardRejectionReason)))")
            lines.append("  raw candidate changed canonicalized raw: \(variantRows.filter { $0.candidate.candidateChangedFromCanonicalizedRaw == true }.count)")
            lines.append("  strict gate output changed canonicalized raw: \(variantRows.filter { $0.candidate.strictGateOutputChangedFromCanonicalizedRaw == true }.count)")
            lines.append("  retained filler raw/candidate: \(variantRows.filter(\.retainedFillerInRaw).count)/\(variantRows.filter { $0.candidate.retainedFillerInCandidate == true }.count)")
            lines.append("  mean elapsed: \(Self.formatSeconds(Self.meanCandidateElapsed(variantRows)))s")
            for row in variantRows {
                lines.append("  - candidate=<\(row.candidate.candidateOutcome)> strict-gate=<\(row.candidate.strictGateOutcome ?? "not-evaluated")> elapsed=\(Self.formatSeconds(row.candidate.elapsedSeconds))s raw: \(row.raw)")
                if let candidate = row.candidate.candidate {
                    lines.append("    candidate: \(candidate)")
                }
                if let canonicalizedCandidate = row.candidate.canonicalizedCandidate,
                   canonicalizedCandidate != row.candidate.candidate {
                    lines.append("    canonicalized candidate: \(canonicalizedCandidate)")
                }
                if let output = row.candidate.strictGateOutput {
                    lines.append("    strict gate output: \(output)")
                }
                if let reason = row.candidate.strictGuardRejectionReason,
                   let diff = row.candidate.strictGuardRejectionDiff {
                    lines.append("    strict rejection: \(reason) \(diff)")
                }
                if let error = row.candidate.errorDescription {
                    lines.append("    error: \(error)")
                }
            }
        }
        lines.append("")
        lines.append("output: \(outputURL.path)")
        return lines.joined(separator: "\n")
    }

    private static func countSummary(_ values: [String]) -> String {
        guard !values.isEmpty else { return "none" }
        return values
            .reduce(into: [String: Int]()) { counts, value in counts[value, default: 0] += 1 }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ", ")
    }

    private static func stableUnique<T: Hashable>(_ values: [T]) -> [T] {
        var seen: Set<T> = []
        return values.filter { seen.insert($0).inserted }
    }

    private static func meanElapsed(_ rows: [OllamaPolishEvalRow]) -> Double {
        guard !rows.isEmpty else { return 0 }
        return rows.reduce(0) { $0 + $1.elapsedSeconds } / Double(rows.count)
    }

    private static func meanCandidateElapsed(_ rows: [OllamaRawCandidateEvalRow]) -> Double {
        guard !rows.isEmpty else { return 0 }
        return rows.reduce(0) { $0 + $1.candidate.elapsedSeconds } / Double(rows.count)
    }

    private static func meanResidualCandidateElapsed(_ rows: [OllamaResidualBakeoffRow]) -> Double {
        guard !rows.isEmpty else { return 0 }
        return rows.reduce(0) { $0 + $1.candidate.elapsedSeconds } / Double(rows.count)
    }

    private static func meanWER(
        _ rows: [OllamaResidualBakeoffRow],
        _ score: (OllamaResidualBakeoffRow) -> TranscriptWordErrorScore?
    ) -> String {
        let scores = rows.compactMap { score($0)?.wordErrorRate }
        guard !scores.isEmpty else { return "n/a" }
        return formatScore(scores.reduce(0, +) / Double(scores.count))
    }

    private static func werDeltaSummary(
        _ rows: [OllamaResidualBakeoffRow],
        _ score: (OllamaResidualBakeoffRow) -> TranscriptWordErrorScore?
    ) -> String {
        var counts: [String: Int] = [:]
        for row in rows {
            guard let score = score(row) else {
                counts["unavailable", default: 0] += 1
                continue
            }
            let baseline = row.canonicalizedRawTranscriptScore.wordErrorRate
            if score.wordErrorRate < baseline {
                counts["better", default: 0] += 1
            } else if score.wordErrorRate > baseline {
                counts["worse", default: 0] += 1
            } else {
                counts["same", default: 0] += 1
            }
        }
        return Self.countSummary(
            counts.flatMap { key, count in Array(repeating: key, count: count) }
        )
    }

    private static func formatSeconds(_ seconds: Double) -> String {
        String(format: "%.3f", seconds)
    }

    private static func formatScore(_ score: Double) -> String {
        String(format: "%.3f", score)
    }

    private static func formatOptionalScore(_ score: Double?) -> String {
        score.map(formatScore) ?? "n/a"
    }

    private static func fileURL(path: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded)
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(expanded)
    }
}

private struct OllamaPolishEvalVariant {
    let name: String
    let promptStyle: OllamaPolishPromptStyle
    let prewarmEnabled: Bool
    let prewarmWait: UInt64
}

private struct OllamaPolishEvalRow: Codable {
    let variant: String
    let model: String
    let promptStyle: String
    let prewarmEnabled: Bool
    let raw: String
    let canonicalizedRaw: String
    let deterministicOutput: String
    let output: String
    let outcome: String
    let engineOutcome: String?
    let prewarmWaitSeconds: Double
    let elapsedSeconds: Double
    let rawCharacterCount: Int
    let outputCharacterCount: Int
    let outputChangedFromCanonicalizedRaw: Bool
    let outputChangedFromDeterministic: Bool
    let retainedFillerInRaw: Bool
    let retainedFillerInOutput: Bool
    let guardRejectionReason: String?
    let guardRejectionCandidate: String?
    let guardRejectionDiff: String?
}

private struct OllamaRawCandidateEvalRow: Codable {
    let variant: String
    let model: String
    let promptStyle: String
    let prewarmEnabled: Bool
    let prewarmWaitSeconds: Double
    let raw: String
    let canonicalizedRaw: String
    let deterministicOutput: String
    let retainedFillerInRaw: Bool
    let candidate: OllamaRawCandidateEvalResult
}

private struct OllamaResidualBakeoffRow: Codable {
    let variant: String
    let model: String
    let promptStyle: String
    let prewarmEnabled: Bool
    let prewarmWaitSeconds: Double
    let sourceFile: String
    let humanIntendedTranscript: String
    let raw: String
    let canonicalizedRaw: String
    let sourceOutput: String
    let sourceOutcome: String
    let sourceOutputTranscriptScore: TranscriptWordErrorScore
    let rawTranscriptScore: TranscriptWordErrorScore
    let canonicalizedRawTranscriptScore: TranscriptWordErrorScore
    let candidateTranscriptScore: TranscriptWordErrorScore?
    let canonicalizedCandidateTranscriptScore: TranscriptWordErrorScore?
    let strictGateOutput: String
    let strictGateOutputTranscriptScore: TranscriptWordErrorScore
    let strictGateOutputChangedFromCanonicalizedRaw: Bool
    let strictGateOutputChangedFromSourceOutput: Bool
    let retainedFillerInRaw: Bool
    let retainedFillerInStrictGateOutput: Bool
    let candidate: OllamaRawCandidateEvalResult
}

private struct OllamaResidualBakeoffError: Error, CustomStringConvertible {
    let description: String
}
