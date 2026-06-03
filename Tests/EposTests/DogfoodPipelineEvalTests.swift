import Foundation
import XCTest
@testable import Epos

/// End-to-end local dogfood eval over saved `.wav` captures. Unlike
/// `SpeechContextEvalTests` (recognizer/context only) and `PolishEvalTests`
/// (text-to-polish only), this runs the production finalization stack for each
/// recording:
///
///   wav -> SpeechTranscriber + production speech context
///       -> TranscriptCanonicalizer -> TranscriptPolisher -> guard outcome
///
/// Skipped unless `EPOS_RUN_DOGFOOD_EVAL=1`, since it needs real saved audio and
/// the configured local polish model:
///
///   EPOS_RUN_DOGFOOD_EVAL=1 EPOS_EVAL_LATEST=1 EPOS_EVAL_LIMIT=10 swift test --filter DogfoodPipelineEvalTests
///   EPOS_POLISH_ENGINE=ollama EPOS_RUN_DOGFOOD_EVAL=1 EPOS_EVAL_LATEST=1 EPOS_EVAL_LIMIT=10 swift test --filter DogfoodPipelineEvalTests
///
/// Useful knobs:
/// - `EPOS_EVAL_RECORDINGS_DIR`: defaults to `~/Library/Caches/Epos/recordings`
/// - `EPOS_EVAL_LIMIT`: number of recordings to replay
/// - `EPOS_EVAL_LATEST=1`: newest-first selection instead of oldest-first
/// - `EPOS_EVAL_OUTPUT`: defaults to `.build/evals/dogfood-pipeline-eval.jsonl`
/// - `EPOS_EVAL_SHADOW_RELAXED_OLLAMA=1`: also log an eval-only relaxed Qwen
///   candidate without changing the production strict output fields.
final class DogfoodPipelineEvalTests: XCTestCase {
    func testSavedRecordingsThroughProductionPolishPipeline() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard SavedRecordingEvalSupport.isTruthy(environment["EPOS_RUN_DOGFOOD_EVAL"]) else {
            throw XCTSkip("Set EPOS_RUN_DOGFOOD_EVAL=1 to run the saved-recording dogfood pipeline eval")
        }

        let engine = try await Self.makeConfiguredPolishEngine(environment: environment)
        let shadowRelaxedEngine = try await Self.makeRelaxedOllamaShadowEngine(environment: environment)

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
        let speechContextualStrings = ["Epos"] + canonicalizer.speechContextualStrings
        let knownTerms = ["Epos"] + canonicalizer.canonicalVocabularyStrings
        let prewarmDelay = SavedRecordingEvalSupport.polishPrewarmSettleNanoseconds(environment: environment)
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
            let shadowRelaxedPolisher = shadowRelaxedEngine.map { engine in
                TranscriptPolisher(
                    enabled: true,
                    engine: engine,
                    knownTerms: knownTerms,
                    canonicalize: { canonicalizer.canonicalize($0) }
                )
            }
            polisher.prewarm()
            shadowRelaxedPolisher?.prewarm()

            let transcribeStarted = Date()
            let transcription = try await SavedRecordingEvalSupport.transcribe(
                recording: recording,
                locale: locale,
                contextualStrings: speechContextualStrings
            )
            let transcribeSeconds = Date().timeIntervalSince(transcribeStarted)
            let prewarmWaitSeconds = await SavedRecordingEvalSupport.waitForPolishPrewarmSettle(
                delayNanoseconds: prewarmDelay,
                alreadyElapsedSeconds: transcribeSeconds
            )

            let canonicalizedRaw = canonicalizer.canonicalize(transcription.text)
            let polishStarted = Date()
            let result = await polisher.polish(transcription.text)
            let polishSeconds = Date().timeIntervalSince(polishStarted)
            let shadowRelaxedStarted = Date()
            let shadowRelaxedResult = await shadowRelaxedPolisher?.polish(transcription.text)
            let shadowRelaxedPolishSeconds = shadowRelaxedResult.map { _ in
                Date().timeIntervalSince(shadowRelaxedStarted)
            }
            let shadowRelaxedCandidateOrOutput = shadowRelaxedResult?.guardRejection?.candidateText
                ?? shadowRelaxedResult?.text

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
                engineOutcome: result.engineOutcome?.rawValue,
                prewarmWaitSeconds: prewarmWaitSeconds,
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
                guardRejectionDiff: result.guardRejection?.diff,
                shadowRelaxedOutput: shadowRelaxedResult?.text,
                shadowRelaxedOutcome: shadowRelaxedResult.map { String(describing: $0.outcome) },
                shadowRelaxedEngineOutcome: shadowRelaxedResult?.engineOutcome?.rawValue,
                shadowRelaxedPolishSeconds: shadowRelaxedPolishSeconds,
                shadowRelaxedOutputChangedFromProduction: shadowRelaxedResult.map { $0.text != result.text },
                shadowRelaxedOutputChangedFromCanonicalizedRaw: shadowRelaxedResult.map {
                    $0.text != canonicalizedRaw
                },
                shadowRelaxedCandidateOrOutputChangedFromProduction: shadowRelaxedCandidateOrOutput.map {
                    $0 != result.text
                },
                shadowRelaxedGuardRejectionReason: shadowRelaxedResult?.guardRejection?.reason.rawValue,
                shadowRelaxedGuardRejectionCandidate: shadowRelaxedResult?.guardRejection?.candidateText,
                shadowRelaxedGuardRejectionCandidateCharacterCount: shadowRelaxedResult?
                    .guardRejection?
                    .candidateCharacterCount,
                shadowRelaxedGuardRejectionDiff: shadowRelaxedResult?.guardRejection?.diff
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

extension DogfoodPipelineEvalTests {
    private static let shadowRelaxedEnvironmentKey = "EPOS_EVAL_SHADOW_RELAXED_OLLAMA"

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

    private static func makeRelaxedOllamaShadowEngine(environment: [String: String]) async throws -> (any PolishEngine)? {
        guard SavedRecordingEvalSupport.isTruthy(environment[shadowRelaxedEnvironmentKey]) else { return nil }
        let model = configuredShadowOllamaModel(environment: environment)
        let engine = OllamaPolishEngine(model: model, promptStyle: .relaxed)
        guard await engine.isModelInstalled() else {
            throw XCTSkip("Ollama shadow model \(model) unavailable; run `ollama pull \(model)`")
        }
        return engine
    }

    private static func configuredShadowOllamaModel(environment: [String: String]) -> String {
        guard let configured = environment[PolishEngineFactory.ollamaModelEnvironmentKey] else {
            return OllamaPolishEngine.defaultModel
        }
        let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? OllamaPolishEngine.defaultModel : trimmed
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
    let shadowRelaxedOutput: String?
    let shadowRelaxedOutcome: String?
    let shadowRelaxedEngineOutcome: String?
    let shadowRelaxedPolishSeconds: Double?
    let shadowRelaxedOutputChangedFromProduction: Bool?
    let shadowRelaxedOutputChangedFromCanonicalizedRaw: Bool?
    let shadowRelaxedCandidateOrOutputChangedFromProduction: Bool?
    let shadowRelaxedGuardRejectionReason: String?
    let shadowRelaxedGuardRejectionCandidate: String?
    let shadowRelaxedGuardRejectionCandidateCharacterCount: Int?
    let shadowRelaxedGuardRejectionDiff: String?
}

private struct DogfoodPipelineEvalSummary {
    private var canonicalizerChanged = 0
    private var changedFromCanonicalizedRaw = 0
    private var retainedFillerRaw = 0
    private var retainedFillerOutput = 0
    private var outcomes: [String: Int] = [:]
    private var engineOutcomes: [String: Int] = [:]
    private var totalPrewarmWaitSeconds = 0.0
    private var shadowRelaxedRows = 0
    private var shadowRelaxedOutputChangedFromProduction = 0
    private var shadowRelaxedCandidateOrOutputChangedFromProduction = 0
    private var shadowRelaxedOutputChangedFromCanonicalizedRaw = 0
    private var shadowRelaxedOutcomes: [String: Int] = [:]
    private var shadowRelaxedEngineOutcomes: [String: Int] = [:]
    private var shadowRelaxedGuardRejections: [String: Int] = [:]

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
        engineOutcomes[row.engineOutcome ?? "not-attempted", default: 0] += 1
        totalPrewarmWaitSeconds += row.prewarmWaitSeconds
        if let shadowOutcome = row.shadowRelaxedOutcome {
            shadowRelaxedRows += 1
            shadowRelaxedOutcomes[shadowOutcome, default: 0] += 1
            shadowRelaxedEngineOutcomes[row.shadowRelaxedEngineOutcome ?? "not-attempted", default: 0] += 1
        }
        if row.shadowRelaxedOutputChangedFromProduction == true {
            shadowRelaxedOutputChangedFromProduction += 1
        }
        if row.shadowRelaxedCandidateOrOutputChangedFromProduction == true {
            shadowRelaxedCandidateOrOutputChangedFromProduction += 1
        }
        if row.shadowRelaxedOutputChangedFromCanonicalizedRaw == true {
            shadowRelaxedOutputChangedFromCanonicalizedRaw += 1
        }
        if let reason = row.shadowRelaxedGuardRejectionReason {
            shadowRelaxedGuardRejections[reason, default: 0] += 1
        }
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
            if let shadowOutput = row.shadowRelaxedOutput {
                lines.append("  relaxed out: \(shadowOutput)")
            }
            if let shadowCandidate = row.shadowRelaxedGuardRejectionCandidate {
                lines.append("  relaxed candidate: \(shadowCandidate)")
            }
            if let reason = row.shadowRelaxedGuardRejectionReason,
               let diff = row.shadowRelaxedGuardRejectionDiff {
                lines.append("  relaxed rejection: \(reason) \(diff)")
            }
        }
        lines.append("")
        lines.append("recordings: \(recordingCount)")
        lines.append("known terms: \(knownTermCount)")
        lines.append("canonicalizer changed raw: \(canonicalizerChanged)")
        lines.append("polish changed canonicalized raw: \(changedFromCanonicalizedRaw)")
        lines.append("retained filler raw/output: \(retainedFillerRaw)/\(retainedFillerOutput)")
        lines.append("outcomes: \(Self.outcomeSummary(outcomes))")
        lines.append("engine outcomes: \(Self.outcomeSummary(engineOutcomes))")
        lines.append("prewarm wait total: \(Self.formatSeconds(totalPrewarmWaitSeconds))s")
        if shadowRelaxedRows > 0 {
            lines.append("shadow relaxed rows: \(shadowRelaxedRows)")
            lines.append("shadow relaxed output changed production: \(shadowRelaxedOutputChangedFromProduction)")
            lines.append("shadow relaxed candidate/output changed production: \(shadowRelaxedCandidateOrOutputChangedFromProduction)")
            lines.append("shadow relaxed output changed canonicalized raw: \(shadowRelaxedOutputChangedFromCanonicalizedRaw)")
            lines.append("shadow relaxed outcomes: \(Self.outcomeSummary(shadowRelaxedOutcomes))")
            lines.append("shadow relaxed engine outcomes: \(Self.outcomeSummary(shadowRelaxedEngineOutcomes))")
            lines.append("shadow relaxed guard rejections: \(Self.outcomeSummary(shadowRelaxedGuardRejections))")
        }
        lines.append("output: \(outputURL.path)")
        return lines.joined(separator: "\n")
    }

    private static func rowHeader(_ row: DogfoodPipelineEvalRow) -> String {
        var tags = ["<\(row.outcome)>", "engine=<\(row.engineOutcome ?? "not-attempted")>"]
        if row.rawChangedByCanonicalizer { tags.append("CANON") }
        if row.outputChangedFromCanonicalizedRaw { tags.append("POLISHED") }
        if row.retainedFillerInOutput { tags.append("FILLER-LEFT") }
        if row.shadowRelaxedCandidateOrOutputChangedFromProduction == true { tags.append("RELAXED-DIFF") }
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
