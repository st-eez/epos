import Foundation
import XCTest
@testable import Epos

/// End-to-end local dogfood eval over saved `.wav` captures. Unlike
/// `SpeechContextEvalTests` (recognizer/context only) and `PolishEvalTests`
/// (text-to-polish only), this runs the production finalization stack for each
/// recording:
///
///   wav -> SpeechTranscriber -> TranscriptCanonicalizer -> TranscriptPolisher -> guard outcome
///
/// Skipped unless `EPOS_RUN_DOGFOOD_EVAL=1`, since it needs real saved audio and
/// the on-device FoundationModels polish model:
///
///   EPOS_RUN_DOGFOOD_EVAL=1 EPOS_EVAL_LATEST=1 EPOS_EVAL_LIMIT=10 swift test --filter DogfoodPipelineEvalTests
///
/// Useful knobs:
/// - `EPOS_EVAL_RECORDINGS_DIR`: defaults to `~/Library/Caches/Epos/recordings`
/// - `EPOS_EVAL_LIMIT`: number of recordings to replay
/// - `EPOS_EVAL_LATEST=1`: newest-first selection instead of oldest-first
/// - `EPOS_EVAL_OUTPUT`: defaults to `.build/evals/dogfood-pipeline-eval.jsonl`
final class DogfoodPipelineEvalTests: XCTestCase {
    func testSavedRecordingsThroughProductionPolishPipeline() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard SavedRecordingEvalSupport.isTruthy(environment["EPOS_RUN_DOGFOOD_EVAL"]) else {
            throw XCTSkip("Set EPOS_RUN_DOGFOOD_EVAL=1 to run the saved-recording dogfood pipeline eval")
        }

        let engine = FoundationModelsPolishEngine()
        try XCTSkipUnless(engine.isAvailable, "FoundationModels model unavailable in this context")

        let settings = Settings.load()
        let locale = settings.locale
        let recordingsDirectory = SavedRecordingEvalSupport.recordingsDirectory(environment: environment)
        let outputURL = SavedRecordingEvalSupport.outputURL(
            environment: environment,
            defaultPath: ".build/evals/dogfood-pipeline-eval.jsonl"
        )
        let selectedRecordings = try SavedRecordingEvalSupport.selectedRecordings(
            in: recordingsDirectory,
            limit: environment["EPOS_EVAL_LIMIT"].flatMap(Int.init),
            latest: SavedRecordingEvalSupport.isTruthy(environment["EPOS_EVAL_LATEST"])
        )
        try XCTSkipIf(selectedRecordings.isEmpty, "No .wav recordings found at \(recordingsDirectory.path)")

        let canonicalizer = TranscriptCanonicalizer.load()
        let knownTerms = ["Epos"] + canonicalizer.speechContextualStrings
        try SavedRecordingEvalSupport.prepareOutput(outputURL)

        var summary = DogfoodPipelineEvalSummary()
        var rows: [DogfoodPipelineEvalRow] = []
        for recording in selectedRecordings {
            let polisher = TranscriptPolisher(
                enabled: true,
                engine: engine,
                knownTerms: knownTerms,
                canonicalize: { canonicalizer.canonicalize($0) }
            )
            polisher.prewarm()

            let transcribeStarted = Date()
            let transcription = try await SavedRecordingEvalSupport.transcribe(recording: recording, locale: locale)
            let transcribeSeconds = Date().timeIntervalSince(transcribeStarted)

            let canonicalizedRaw = canonicalizer.canonicalize(transcription.text)
            let polishStarted = Date()
            let result = await polisher.polish(transcription.text)
            let polishSeconds = Date().timeIntervalSince(polishStarted)

            let row = DogfoodPipelineEvalRow(
                file: recording.lastPathComponent,
                localeIdentifier: locale.identifier,
                audioDurationSeconds: try SavedRecordingEvalSupport.durationSeconds(recording: recording),
                transcribeSeconds: transcribeSeconds,
                polishSeconds: polishSeconds,
                rawTranscript: transcription.text,
                canonicalizedRaw: canonicalizedRaw,
                output: result.text,
                outcome: String(describing: result.outcome),
                rawChangedByCanonicalizer: canonicalizedRaw != transcription.text,
                outputChangedFromRaw: result.text != transcription.text,
                outputChangedFromCanonicalizedRaw: result.text != canonicalizedRaw,
                retainedFillerInRaw: PolishEvalScoring.retainsFiller(transcription.text),
                retainedFillerInOutput: PolishEvalScoring.retainsFiller(result.text),
                rawCharacterCount: result.rawCharacterCount,
                outputCharacterCount: result.text.count,
                guardRejectionReason: result.guardRejection?.reason.rawValue,
                guardRejectionCandidate: result.guardRejection?.candidateText,
                guardRejectionCandidateCharacterCount: result.guardRejection?.candidateCharacterCount,
                guardRejectionDiff: result.guardRejection?.diff
            )
            rows.append(row)
            summary.add(row)
            try SavedRecordingEvalSupport.appendJSONL(row, to: outputURL)
        }

        print(summary.report(
            recordingCount: selectedRecordings.count,
            knownTermCount: knownTerms.count,
            outputURL: outputURL,
            rows: rows
        ))
    }
}

private struct DogfoodPipelineEvalRow: Codable {
    let file: String
    let localeIdentifier: String
    let audioDurationSeconds: Double
    let transcribeSeconds: Double
    let polishSeconds: Double
    let rawTranscript: String
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

private struct DogfoodPipelineEvalSummary {
    private var canonicalizerChanged = 0
    private var changedFromCanonicalizedRaw = 0
    private var retainedFillerRaw = 0
    private var retainedFillerOutput = 0
    private var outcomes: [String: Int] = [:]

    mutating func add(_ row: DogfoodPipelineEvalRow) {
        if row.rawChangedByCanonicalizer {
            canonicalizerChanged += 1
        }
        if row.outputChangedFromCanonicalizedRaw {
            changedFromCanonicalizedRaw += 1
        }
        if row.retainedFillerInRaw {
            retainedFillerRaw += 1
        }
        if row.retainedFillerInOutput {
            retainedFillerOutput += 1
        }
        outcomes[row.outcome, default: 0] += 1
    }

    func report(
        recordingCount: Int,
        knownTermCount: Int,
        outputURL: URL,
        rows: [DogfoodPipelineEvalRow]
    ) -> String {
        var lines = ["", "Dogfood pipeline eval"]
        for row in rows {
            lines.append(Self.rowHeader(row))
            lines.append("  raw: \(row.rawTranscript)")
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
        lines.append("")
        lines.append("recordings: \(recordingCount)")
        lines.append("known terms: \(knownTermCount)")
        lines.append("canonicalizer changed raw: \(canonicalizerChanged)")
        lines.append("polish changed canonicalized raw: \(changedFromCanonicalizedRaw)")
        lines.append("retained filler raw/output: \(retainedFillerRaw)/\(retainedFillerOutput)")
        lines.append("outcomes: \(Self.outcomeSummary(outcomes))")
        lines.append("output: \(outputURL.path)")
        return lines.joined(separator: "\n")
    }

    private static func rowHeader(_ row: DogfoodPipelineEvalRow) -> String {
        var tags = ["<\(row.outcome)>"]
        if row.rawChangedByCanonicalizer { tags.append("CANON") }
        if row.outputChangedFromCanonicalizedRaw { tags.append("POLISHED") }
        if row.retainedFillerInOutput { tags.append("FILLER-LEFT") }
        let audio = Self.formatSeconds(row.audioDurationSeconds)
        let transcribe = Self.formatSeconds(row.transcribeSeconds)
        let polish = Self.formatSeconds(row.polishSeconds)
        return "[\(row.file)] \(tags.joined(separator: " ")) audio=\(audio)s transcribe=\(transcribe)s polish=\(polish)s"
    }

    private static func outcomeSummary(_ outcomes: [String: Int]) -> String {
        outcomes
            .keys
            .sorted()
            .map { "\($0)=\(outcomes[$0, default: 0])" }
            .joined(separator: ", ")
    }

    private static func formatSeconds(_ seconds: Double) -> String {
        String(format: "%.3f", seconds)
    }
}
