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
        guard ProcessInfo.processInfo.environment["EPOS_RUN_POLISH_EVAL"] == "1" else {
            throw XCTSkip("Set EPOS_RUN_POLISH_EVAL=1 to run the on-device polish eval")
        }
        let engine = FoundationModelsPolishEngine()
        try XCTSkipUnless(engine.isAvailable, "FoundationModels model unavailable in this context")

        let canonicalizer = TranscriptCanonicalizer.load()
        let knownTerms = ["Epos"] + canonicalizer.canonicalVocabularyStrings
        let polisher = TranscriptPolisher(
            enabled: true,
            engine: engine,
            knownTerms: knownTerms,
            canonicalize: { canonicalizer.canonicalize($0) }
        )

        var rows: [PolishEvalRow] = []
        for (label, corpus) in [("real", Self.realClipTranscripts), ("stress", Self.stressTranscripts)] {
            for raw in corpus {
                let canonicalizedRaw = canonicalizer.canonicalize(raw)
                let result = await polisher.polish(raw)
                rows.append(PolishEvalRow(
                    set: label,
                    raw: raw,
                    canonicalizedRaw: canonicalizedRaw,
                    output: result.text,
                    outcome: String(describing: result.outcome),
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

    private static func report(_ rows: [PolishEvalRow]) -> String {
        var lines = ["", "════════ Polish eval ════════"]
        for row in rows {
            var tags = ["<\(row.outcome)>"]
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
        lines.append("")
        lines.append("rows: \(rows.count)  applied: \(applied)")
        lines.append("canonicalizer changed raw: \(canonicalizerChanged)")
        lines.append("polish changed canonicalized raw: \(polishChanged)")
        lines.append("retained filler raw/output: \(retainedFillerRaw)/\(retainedFillerOutput)")
        lines.append("outcomes: \(outcomeSummary(rows))")
        lines.append("guard rejections: \(guardRejectionSummary(rows))")
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
