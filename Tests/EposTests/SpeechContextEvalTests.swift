import XCTest
@testable import Epos

/// Offline validation for recognition bias via `AnalysisContext.contextualStrings`.
/// Replays saved `.wav` captures through the transcriber twice - once unbiased,
/// once with the production contextual strings - and reports how often context
/// changed the raw transcript, the canonicalized transcript, and vocabulary hits.
///
/// Skipped unless `EPOS_RUN_CONTEXT_EVAL=1`, since it needs the locale asset and
/// saved recordings:
///
///   EPOS_RUN_CONTEXT_EVAL=1 EPOS_EVAL_LATEST=1 EPOS_EVAL_LIMIT=10 swift test --filter SpeechContextEvalTests
///
/// Useful knobs:
/// - `EPOS_EVAL_RECORDINGS_DIR`: defaults to `~/Library/Caches/Epos/recordings`
/// - `EPOS_EVAL_LIMIT`: number of recordings to replay
/// - `EPOS_EVAL_LATEST=1`: newest-first selection instead of oldest-first
/// - `EPOS_EVAL_OUTPUT`: defaults to `.build/evals/speech-context-eval.jsonl`
final class SpeechContextEvalTests: XCTestCase {
    func testSavedRecordingsWithAndWithoutSpeechContext() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["EPOS_RUN_CONTEXT_EVAL"] == "1" else {
            throw XCTSkip("Set EPOS_RUN_CONTEXT_EVAL=1 to replay saved recordings")
        }

        let settings = Settings.load()
        let locale = settings.locale
        let recordingsDirectory = SavedRecordingEvalSupport.recordingsDirectory(environment: environment)
        let outputURL = SavedRecordingEvalSupport.outputURL(
            environment: environment,
            defaultPath: ".build/evals/speech-context-eval.jsonl"
        )
        let selectedRecordings = try SavedRecordingEvalSupport.selectedRecordings(
            in: recordingsDirectory,
            limit: environment["EPOS_EVAL_LIMIT"].flatMap(Int.init),
            latest: SavedRecordingEvalSupport.isTruthy(environment["EPOS_EVAL_LATEST"])
        )
        try XCTSkipIf(selectedRecordings.isEmpty, "No .wav recordings found at \(recordingsDirectory.path)")

        let canonicalizer = TranscriptCanonicalizer.load()
        let contextualStrings = ["Epos"] + canonicalizer.speechContextualStrings
        try SavedRecordingEvalSupport.prepareOutput(outputURL)

        var summary = SpeechContextEvalSummary()
        var rows: [SpeechContextEvalRow] = []
        for recording in selectedRecordings {
            let noContext = try await SavedRecordingEvalSupport.transcribe(
                recording: recording,
                locale: locale
            )
            let withContext = try await SavedRecordingEvalSupport.transcribe(
                recording: recording,
                locale: locale,
                contextualStrings: contextualStrings
            )
            let row = SpeechContextEvalRow(
                file: recording.lastPathComponent,
                localeIdentifier: locale.identifier,
                audioDurationSeconds: try SavedRecordingEvalSupport.durationSeconds(recording: recording),
                noContext: noContext.text,
                withContext: withContext.text,
                noContextCanonicalized: canonicalizer.canonicalize(noContext.text),
                withContextCanonicalized: canonicalizer.canonicalize(withContext.text),
                noContextVocabularyHits: Self.vocabularyHits(in: noContext.text, terms: contextualStrings),
                withContextVocabularyHits: Self.vocabularyHits(in: withContext.text, terms: contextualStrings)
            )
            rows.append(row)
            summary.add(row)
            try SavedRecordingEvalSupport.appendJSONL(row, to: outputURL)
        }

        print(summary.report(
            recordingCount: selectedRecordings.count,
            contextTermCount: contextualStrings.count,
            outputURL: outputURL,
            rows: rows
        ))
    }

    private static func vocabularyHits(in text: String, terms: [String]) -> [String] {
        let lowercasedText = text.lowercased()
        return terms.filter { lowercasedText.contains($0.lowercased()) }
    }
}

private struct SpeechContextEvalRow: Codable {
    let file: String
    let localeIdentifier: String
    let audioDurationSeconds: Double
    let noContext: String
    let withContext: String
    let noContextCanonicalized: String
    let withContextCanonicalized: String
    let noContextVocabularyHits: [String]
    let withContextVocabularyHits: [String]

    var rawChanged: Bool { noContext != withContext }
    var canonicalizedChanged: Bool { noContextCanonicalized != withContextCanonicalized }
    var vocabularyHitDelta: Int { withContextVocabularyHits.count - noContextVocabularyHits.count }
}

private struct SpeechContextEvalSummary {
    private var rawChanged = 0
    private var canonicalizedChanged = 0
    private var vocabularyHitGains = 0
    private var vocabularyHitLosses = 0

    mutating func add(_ row: SpeechContextEvalRow) {
        if row.rawChanged {
            rawChanged += 1
        }
        if row.canonicalizedChanged {
            canonicalizedChanged += 1
        }
        if row.vocabularyHitDelta > 0 {
            vocabularyHitGains += 1
        }
        if row.vocabularyHitDelta < 0 {
            vocabularyHitLosses += 1
        }
    }

    func report(
        recordingCount: Int,
        contextTermCount: Int,
        outputURL: URL,
        rows: [SpeechContextEvalRow]
    ) -> String {
        var lines = ["", "Speech context eval"]
        for row in rows {
            var tags: [String] = []
            if row.rawChanged { tags.append("RAW-CHANGED") }
            if row.canonicalizedChanged { tags.append("CANON-CHANGED") }
            if row.vocabularyHitDelta > 0 { tags.append("VOCAB-GAIN") }
            if row.vocabularyHitDelta < 0 { tags.append("VOCAB-LOSS") }
            let tagText = tags.isEmpty ? "same" : tags.joined(separator: " ")
            lines.append("[\(row.file)] <\(tagText)> audio=\(Self.formatSeconds(row.audioDurationSeconds))s")
            lines.append("  no:  \(row.noContext)")
            lines.append("  ctx: \(row.withContext)")
            if row.canonicalizedChanged {
                lines.append("  no can:  \(row.noContextCanonicalized)")
                lines.append("  ctx can: \(row.withContextCanonicalized)")
            }
            if row.vocabularyHitDelta != 0 {
                lines.append("  no hits:  \(row.noContextVocabularyHits.joined(separator: ", "))")
                lines.append("  ctx hits: \(row.withContextVocabularyHits.joined(separator: ", "))")
            }
        }
        lines.append("")
        lines.append("recordings: \(recordingCount)")
        lines.append("context terms: \(contextTermCount)")
        lines.append("raw changed: \(rawChanged)")
        lines.append("canonicalized changed: \(canonicalizedChanged)")
        lines.append("vocabulary hit gains: \(vocabularyHitGains)")
        lines.append("vocabulary hit losses: \(vocabularyHitLosses)")
        lines.append("output: \(outputURL.path)")
        return lines.joined(separator: "\n")
    }

    private static func formatSeconds(_ seconds: Double) -> String {
        String(format: "%.3f", seconds)
    }
}
