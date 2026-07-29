import Foundation
import XCTest
@testable import Epos

/// Raw Apple SpeechTranscriber eval over saved `.wav` captures.
///
/// This intentionally disables Epos correction context, canonicalization, and
/// deterministic cleanup. It measures only what Apple's recognizer returns for the audio.
///
///   EPOS_RUN_RAW_STT_APPLE_EVAL=1 EPOS_EVAL_GROUND_TRUTH_ONLY=1 swift test --filter RawSpeechTranscriberEvalTests
///
/// Useful knobs match the saved-recording eval helpers:
/// - `EPOS_EVAL_RECORDINGS_DIR`: defaults to `~/Library/Caches/Epos/recordings`
/// - `EPOS_EVAL_RECORDING_FILES`: comma- or newline-separated recording names
/// - `EPOS_EVAL_LIMIT`: number of recordings to replay
/// - `EPOS_EVAL_LATEST=1`: newest-first selection instead of manifest order
/// - `EPOS_EVAL_GROUND_TRUTH_ONLY=1`: limit to recordings with intended text
/// - `EPOS_EVAL_OUTPUT`: defaults to `.build/evals/raw-apple-speechtranscriber.jsonl`
final class RawSpeechTranscriberEvalTests: XCTestCase {
    func testRawAppleSpeechTranscriberOverSavedRecordings() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["EPOS_RUN_RAW_STT_APPLE_EVAL"] == "1" else {
            throw XCTSkip("Set EPOS_RUN_RAW_STT_APPLE_EVAL=1 to replay raw Apple SpeechTranscriber")
        }

        let settings = Settings.load()
        let recordingsDirectory = SavedRecordingEvalSupport.recordingsDirectory(environment: environment)
        let manifest = try SavedRecordingEvalSupport.groundTruthManifest(
            in: recordingsDirectory,
            environment: environment
        )
        let outputURL = SavedRecordingEvalSupport.outputURL(
            environment: environment,
            defaultPath: ".build/evals/raw-apple-speechtranscriber.jsonl"
        )
        let recordings = try Self.selectedRecordings(
            in: recordingsDirectory,
            manifest: manifest,
            environment: environment
        )
        try XCTSkipIf(recordings.isEmpty, "No .wav recordings found at \(recordingsDirectory.path)")
        try SavedRecordingEvalSupport.prepareOutput(outputURL)

        var rows: [RawSpeechTranscriberEvalRow] = []
        for recording in recordings {
            let duration = try SavedRecordingEvalSupport.durationSeconds(recording: recording)
            let started = Date()
            let transcription = try await SavedRecordingEvalSupport.transcribeForContextEval(
                recording: recording,
                locale: settings.locale,
                contextualStrings: [],
                applicationMode: .setContextBeforeStart,
                includeAlternatives: false
            )
            let elapsed = Date().timeIntervalSince(started)
            let intended = manifest.transcript(for: recording)
            let score = intended.map {
                TranscriptEvalScoring.wordErrorScore(reference: $0, hypothesis: transcription.text)
            }
            let row = RawSpeechTranscriberEvalRow(
                model: "apple-speechtranscriber",
                engine: "SpeechAnalyzer/SpeechTranscriber",
                modelRepo: nil,
                file: recording.lastPathComponent,
                audioDurationSeconds: duration,
                humanIntendedTranscript: intended,
                transcript: transcription.text,
                transcriptScore: score,
                elapsedSeconds: elapsed,
                rtf: elapsed > 0 ? duration / elapsed : nil,
                error: nil
            )
            rows.append(row)
            try SavedRecordingEvalSupport.appendJSONL(row, to: outputURL)
        }

        print(Self.summary(rows: rows, outputURL: outputURL))
    }

    private static func selectedRecordings(
        in recordingsDirectory: URL,
        manifest: HumanIntendedTranscriptManifest,
        environment: [String: String]
    ) throws -> [URL] {
        let selected = try SavedRecordingEvalSupport.selectedRecordings(
            in: recordingsDirectory,
            limit: environment["EPOS_EVAL_LIMIT"].flatMap(Int.init),
            latest: SavedRecordingEvalSupport.isTruthy(environment["EPOS_EVAL_LATEST"]),
            environment: environment
        )
        guard SavedRecordingEvalSupport.isTruthy(environment["EPOS_EVAL_GROUND_TRUTH_ONLY"]) else {
            return selected
        }
        return selected.filter { manifest.transcript(for: $0) != nil }
    }

    private static func summary(rows: [RawSpeechTranscriberEvalRow], outputURL: URL) -> String {
        let scored = rows.compactMap(\.transcriptScore)
        let meanWER = scored.isEmpty
            ? "n/a"
            : String(format: "%.6f", scored.map(\.wordErrorRate).reduce(0, +) / Double(scored.count))
        let totalErrors = scored.map(\.wordErrors).reduce(0, +)
        let totalReferenceWords = scored.map(\.referenceWordCount).reduce(0, +)
        let corpusWER = totalReferenceWords == 0
            ? "n/a"
            : String(format: "%.6f", Double(totalErrors) / Double(totalReferenceWords))
        let audioSeconds = rows.map(\.audioDurationSeconds).reduce(0, +)
        let elapsedSeconds = rows.map(\.elapsedSeconds).reduce(0, +)
        let rtf = elapsedSeconds > 0
            ? String(format: "%.2f", audioSeconds / elapsedSeconds)
            : "n/a"
        return """
        Raw Apple SpeechTranscriber eval:
          rows: \(rows.count)
          mean row WER: \(meanWER)
          corpus WER: \(corpusWER)
          total word errors: \(totalErrors)
          audio seconds: \(String(format: "%.3f", audioSeconds))
          elapsed seconds: \(String(format: "%.3f", elapsedSeconds))
          warm RTFx: \(rtf)
          output: \(outputURL.path)
        """
    }
}

private struct RawSpeechTranscriberEvalRow: Codable {
    let model: String
    let engine: String
    let modelRepo: String?
    let file: String
    let audioDurationSeconds: Double
    let humanIntendedTranscript: String?
    let transcript: String
    let transcriptScore: TranscriptWordErrorScore?
    let elapsedSeconds: Double
    let rtf: Double?
    let error: String?
}
