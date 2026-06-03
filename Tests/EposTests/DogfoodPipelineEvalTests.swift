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
/// - `EPOS_EVAL_RECORDING_FILES`: comma- or newline-separated recording filenames
///   or absolute paths for targeted eval slices. Overrides latest/limit ordering.
/// - `EPOS_EVAL_LIMIT`: number of recordings to replay
/// - `EPOS_EVAL_LATEST=1`: newest-first selection instead of oldest-first
/// - `EPOS_EVAL_OUTPUT`: defaults to `.build/evals/dogfood-pipeline-eval.jsonl`
/// - `EPOS_EVAL_GROUND_TRUTH`: JSONL manifest with `file` and
///   `humanIntendedTranscript`; defaults to `ground-truth.jsonl` in the
///   recordings directory when that file exists.
/// - `EPOS_EVAL_SHADOW_RELAXED_OLLAMA=1`: also log a direct, eval-only relaxed
///   Qwen candidate plus the strict guard decision, without changing production fields.
/// - `EPOS_OLLAMA_PROMPT_STYLE`: eval-only prompt style override for the
///   configured Ollama engine; defaults to the production prompt style.
final class DogfoodPipelineEvalTests: XCTestCase {
    func testSavedRecordingsThroughProductionPolishPipeline() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard SavedRecordingEvalSupport.isTruthy(environment["EPOS_RUN_DOGFOOD_EVAL"]) else {
            throw XCTSkip("Set EPOS_RUN_DOGFOOD_EVAL=1 to run the saved-recording dogfood pipeline eval")
        }

        let engine = try await Self.makeConfiguredPolishEngine(environment: environment)
        let shadowRelaxedEngine = try await Self.makeRelaxedOllamaRawCandidateEngine(environment: environment)
        let polishPromptStyle = Self.configuredPolishPromptStyleName(environment: environment)

        let settings = Settings.load()
        let locale = settings.locale
        let recordingsDirectory = SavedRecordingEvalSupport.recordingsDirectory(environment: environment)
        let groundTruthManifest = try SavedRecordingEvalSupport.groundTruthManifest(
            in: recordingsDirectory,
            environment: environment
        )
        let outputURL = SavedRecordingEvalSupport.outputURL(
            environment: environment,
            defaultPath: ".build/evals/dogfood-pipeline-eval.jsonl"
        )
        let selectedRecordings = try SavedRecordingEvalSupport.selectedRecordings(
            in: recordingsDirectory,
            limit: environment["EPOS_EVAL_LIMIT"].flatMap(Int.init),
            latest: SavedRecordingEvalSupport.isTruthy(environment["EPOS_EVAL_LATEST"]),
            environment: environment
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
            let shadowRelaxedSession = shadowRelaxedEngine?.makeSession(knownTerms: knownTerms)
            polisher.prewarm()

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
            let shadowRelaxedRawCandidate: OllamaRawCandidateEvalResult?
            if let shadowRelaxedSession {
                shadowRelaxedRawCandidate = await OllamaRawCandidateEvalSupport.evaluate(
                    raw: transcription.text,
                    canonicalizedRaw: canonicalizedRaw,
                    deterministicOutput: TranscriptDeterministicCleaner.clean(canonicalizedRaw),
                    session: shadowRelaxedSession,
                    canonicalize: { canonicalizer.canonicalize($0) }
                )
            } else {
                shadowRelaxedRawCandidate = nil
            }
            let shadowRelaxedCandidateOrOutput = shadowRelaxedRawCandidate?.candidate
                ?? shadowRelaxedRawCandidate?.strictGateOutput
            let shadowRelaxedRejectedCandidate = shadowRelaxedRawCandidate?.strictGuardRejectionReason == nil
                ? nil
                : shadowRelaxedRawCandidate?.candidate
            let shadowRelaxedRejectedCandidateCharacterCount =
                shadowRelaxedRawCandidate?.strictGuardRejectionReason == nil
                    ? nil
                    : shadowRelaxedRawCandidate?.candidateCharacterCount
            let humanIntendedTranscript = groundTruthManifest.transcript(for: recording)
            let rawTranscriptScore = humanIntendedTranscript.map {
                PolishEvalScoring.wordErrorScore(reference: $0, hypothesis: transcription.text)
            }
            let canonicalizedRawTranscriptScore = humanIntendedTranscript.map {
                PolishEvalScoring.wordErrorScore(reference: $0, hypothesis: canonicalizedRaw)
            }
            let outputTranscriptScore = humanIntendedTranscript.map {
                PolishEvalScoring.wordErrorScore(reference: $0, hypothesis: result.text)
            }
            let shadowRelaxedOutputTranscriptScore = humanIntendedTranscript.flatMap { reference in
                shadowRelaxedRawCandidate?.strictGateOutput.map {
                    PolishEvalScoring.wordErrorScore(reference: reference, hypothesis: $0)
                }
            }
            let shadowRelaxedCandidateTranscriptScore = humanIntendedTranscript.flatMap { reference in
                shadowRelaxedRawCandidate?.candidate.map {
                    PolishEvalScoring.wordErrorScore(reference: reference, hypothesis: $0)
                }
            }

            let row = DogfoodPipelineEvalRow(
                file: recording.lastPathComponent,
                localeIdentifier: locale.identifier,
                audioDurationSeconds: try SavedRecordingEvalSupport.durationSeconds(recording: recording),
                transcribeSeconds: transcribeSeconds,
                polishSeconds: polishSeconds,
                humanIntendedTranscript: humanIntendedTranscript,
                rawTranscript: transcription.text,
                rawTranscriptScore: rawTranscriptScore,
                canonicalizedRaw: canonicalizedRaw,
                canonicalizedRawTranscriptScore: canonicalizedRawTranscriptScore,
                output: result.text,
                outputTranscriptScore: outputTranscriptScore,
                outcome: String(describing: result.outcome),
                engineOutcome: result.engineOutcome?.rawValue,
                polishPromptStyle: polishPromptStyle,
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
                shadowRelaxedOutput: shadowRelaxedRawCandidate?.strictGateOutput,
                shadowRelaxedOutputTranscriptScore: shadowRelaxedOutputTranscriptScore,
                shadowRelaxedOutcome: shadowRelaxedRawCandidate?.strictGateOutcome,
                shadowRelaxedEngineOutcome: shadowRelaxedRawCandidate?.candidateOutcome,
                shadowRelaxedPolishSeconds: shadowRelaxedRawCandidate?.elapsedSeconds,
                shadowRelaxedOutputChangedFromProduction: shadowRelaxedRawCandidate?.strictGateOutput.map {
                    $0 != result.text
                },
                shadowRelaxedOutputChangedFromCanonicalizedRaw: shadowRelaxedRawCandidate?.strictGateOutput.map {
                    $0 != canonicalizedRaw
                },
                shadowRelaxedCandidateOrOutputChangedFromProduction: shadowRelaxedCandidateOrOutput.map {
                    $0 != result.text
                },
                shadowRelaxedGuardRejectionReason: shadowRelaxedRawCandidate?.strictGuardRejectionReason,
                shadowRelaxedGuardRejectionCandidate: shadowRelaxedRejectedCandidate,
                shadowRelaxedGuardRejectionCandidateCharacterCount: shadowRelaxedRejectedCandidateCharacterCount,
                shadowRelaxedGuardRejectionDiff: shadowRelaxedRawCandidate?.strictGuardRejectionDiff,
                shadowRelaxedCandidateTranscriptScore: shadowRelaxedCandidateTranscriptScore,
                shadowRelaxedRawCandidate: shadowRelaxedRawCandidate
            )
            rows.append(row)
            summary.add(row)
            try SavedRecordingEvalSupport.appendJSONL(row, to: outputURL)
        }

        print(summary.report(
            recordingCount: selectedRecordings.count,
            knownTermCount: knownTerms.count,
            polishPromptStyle: polishPromptStyle,
            groundTruthSourceURL: groundTruthManifest.sourceURL,
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
            let engine = OllamaPolishEngine(
                model: model,
                promptStyle: configuredOllamaPromptStyle(environment: environment)
            )
            guard await engine.isModelInstalled() else {
                throw XCTSkip("Ollama model \(model) unavailable; run `ollama pull \(model)`")
            }
            return engine
        }
    }

    private static func makeRelaxedOllamaRawCandidateEngine(
        environment: [String: String]
    ) async throws -> (any PolishEngine)? {
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

    private static func configuredOllamaPromptStyle(environment: [String: String]) -> OllamaPolishPromptStyle {
        guard let configured = environment["EPOS_OLLAMA_PROMPT_STYLE"] else {
            return .productionDefault
        }
        let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return OllamaPolishPromptStyle(rawValue: trimmed) ?? .productionDefault
    }

    private static func configuredPolishPromptStyleName(environment: [String: String]) -> String? {
        switch PolishEngineFactory.configuredEngine(environment: environment) {
        case .foundationModels:
            return nil
        case .ollama:
            return configuredOllamaPromptStyle(environment: environment).rawValue
        }
    }
}
