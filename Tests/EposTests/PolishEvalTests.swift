import XCTest
@testable import Epos

/// Offline quality eval for the LLM polish stage. Runs the REAL production path
/// (`FoundationModelsPolishEngine` + `TranscriptPolisher` guard + the
/// canonicalizer, both sides) over a text corpus — the recognizer's wav→text step
/// is covered separately by `SpeechContextEvalTests`, so this evals the polish
/// layer directly. The corpus is the transcripts of the saved real clips plus a
/// stress set that actually exercises polish (fillers, contraction, spoken
/// punctuation, guardrail bait, self-correction).
///
/// Skipped unless `EPOS_RUN_POLISH_EVAL=1`, since it runs the on-device model:
///
///   EPOS_RUN_POLISH_EVAL=1 swift test --filter PolishEvalTests
///
/// Prints a per-row raw→outcome→output table plus a summary, and writes
/// `.build/evals/polish-eval.jsonl`. Tune against two numbers: `retainedFiller`
/// should trend to 0 (polish is doing its job) and there must be ZERO meaning
/// changes on inspection (the safety bar). Refreshing the real-clip transcripts
/// after recording new audio uses the `LLMPolishProbe` harness — a local-only,
/// gitignored probe project NOT present in a fresh checkout: where it exists, run
/// `swift run LLMPolishProbe --transcribe-only` and paste the raw lines into
/// `realClipTranscripts`.
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
        guard ProcessInfo.processInfo.environment["EPOS_RUN_POLISH_EVAL"] == "1" else {
            throw XCTSkip("Set EPOS_RUN_POLISH_EVAL=1 to run the on-device polish eval")
        }
        let engine = FoundationModelsPolishEngine()
        try XCTSkipUnless(engine.isAvailable, "FoundationModels model unavailable in this context")

        let canonicalizer = TranscriptCanonicalizer.load()
        let knownTerms = ["Epos"] + canonicalizer.speechContextualStrings
        let polisher = TranscriptPolisher(
            enabled: true,
            engine: engine,
            knownTerms: knownTerms,
            canonicalize: { canonicalizer.canonicalize($0) }
        )

        var rows: [PolishEvalRow] = []
        for (label, corpus) in [("real", Self.realClipTranscripts), ("stress", Self.stressTranscripts)] {
            for raw in corpus {
                let result = await polisher.polish(raw)
                rows.append(PolishEvalRow(
                    set: label,
                    raw: raw,
                    output: result.text,
                    outcome: String(describing: result.outcome),
                    changed: result.text != raw,
                    retainedFiller: Self.retainsFiller(result.text)
                ))
            }
        }

        print(Self.report(rows))
        try Self.writeJSONL(rows)
    }

    /// A whole-word filler still present in the OUTPUT — the polish-quality miss
    /// signal. Whole-word so "uh" doesn't match inside "though".
    private static func retainsFiller(_ text: String) -> Bool {
        let words = text.lowercased().split { !$0.isLetter }.map(String.init)
        let wordSet = Set(words)
        if !PolishVocabulary.singleFillers.isDisjoint(with: wordSet) { return true }
        return PolishVocabulary.fillerPhrases.contains { phrase in
            guard let first = phrase.first, let start = words.firstIndex(of: first) else { return false }
            return start + phrase.count <= words.count
                && Array(words[start..<(start + phrase.count)]) == phrase
        }
    }

    private static func report(_ rows: [PolishEvalRow]) -> String {
        var lines = ["", "════════ Polish eval ════════"]
        for row in rows {
            lines.append("[\(row.set)] <\(row.outcome)>\(row.changed ? " CHANGED" : "")\(row.retainedFiller ? " FILLER-LEFT" : "")")
            lines.append("  raw: \(row.raw)")
            lines.append("  out: \(row.output)")
        }
        let applied = rows.filter { $0.outcome == "applied" }.count
        let fillerLeft = rows.filter { $0.retainedFiller }.count
        lines.append("")
        lines.append("rows: \(rows.count)  applied: \(applied)  retainedFiller: \(fillerLeft)")
        lines.append("(inspect every row for meaning changes — that is the safety bar; retainedFiller is the quality miss count)")
        return lines.joined(separator: "\n")
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
    let output: String
    let outcome: String
    let changed: Bool
    let retainedFiller: Bool
}
