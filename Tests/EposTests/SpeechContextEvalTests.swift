import XCTest
@testable import Epos

/// Offline validation for recognition bias via `AnalysisContext.contextualStrings`.
/// Replays saved `.wav` captures through named context variants and reports how
/// often each variant changed the raw transcript, the canonicalized transcript,
/// vocabulary hits, and transcription latency versus the no-context baseline.
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
            latest: SavedRecordingEvalSupport.isTruthy(environment["EPOS_EVAL_LATEST"]),
            environment: environment
        )
        try XCTSkipIf(selectedRecordings.isEmpty, "No .wav recordings found at \(recordingsDirectory.path)")

        let canonicalizer = TranscriptCanonicalizer.load()
        let variants = Self.contextVariants(canonicalizer: canonicalizer)
        let baselineVariant = variants[0]
        try SavedRecordingEvalSupport.prepareOutput(outputURL)

        var summary = SpeechContextEvalSummary()
        var rows: [SpeechContextEvalRow] = []
        for recording in selectedRecordings {
            let audioDuration = try SavedRecordingEvalSupport.durationSeconds(recording: recording)
            var results: [SpeechContextVariantResult] = []
            for variant in variants {
                let started = Date()
                let transcription = try await SavedRecordingEvalSupport.transcribeForContextEval(
                    recording: recording,
                    locale: locale,
                    contextualStrings: variant.contextualStrings,
                    applicationMode: variant.applicationMode,
                    includeAlternatives: variant.includeAlternatives
                )
                results.append(SpeechContextVariantResult(
                    variant: variant.name,
                    contextTermCount: variant.contextualStrings.count,
                    contextualStrings: variant.contextualStrings,
                    applicationMode: variant.applicationMode,
                    includeAlternatives: variant.includeAlternatives,
                    contextReadback: transcription.contextReadback,
                    text: transcription.text,
                    canonicalizedText: canonicalizer.canonicalize(transcription.text),
                    vocabularyHits: Self.vocabularyHits(in: transcription.text, terms: variant.contextualStrings),
                    alternatives: transcription.alternatives,
                    elapsedSeconds: Date().timeIntervalSince(started)
                ))
            }

            let baseline = try XCTUnwrap(results.first)
            for result in results.dropFirst() {
                let contextReadbackMatches = Self.contextReadbackMatches(
                    expected: result.contextualStrings,
                    actual: result.contextReadback
                )
                XCTAssertTrue(
                    contextReadbackMatches,
                    "\(recording.lastPathComponent) \(result.variant) context readback did not match requested terms"
                )
                if result.includeAlternatives {
                    XCTAssertFalse(
                        result.alternatives.isEmpty,
                        "\(recording.lastPathComponent) \(result.variant) expected alternative transcriptions"
                    )
                }

                let row = SpeechContextEvalRow(
                    file: recording.lastPathComponent,
                    localeIdentifier: locale.identifier,
                    audioDurationSeconds: audioDuration,
                    baselineVariant: baselineVariant.name,
                    variant: result.variant,
                    contextTermCount: result.contextTermCount,
                    applicationMode: result.applicationMode,
                    includeAlternatives: result.includeAlternatives,
                    contextReadbackCount: result.contextReadback.count,
                    contextReadbackMatches: contextReadbackMatches,
                    baselineText: baseline.text,
                    variantText: result.text,
                    baselineCanonicalized: baseline.canonicalizedText,
                    variantCanonicalized: result.canonicalizedText,
                    baselineVocabularyHits: Self.vocabularyHits(in: baseline.text, terms: result.contextualStrings),
                    variantVocabularyHits: result.vocabularyHits,
                    variantAlternatives: result.alternatives,
                    baselineElapsedSeconds: baseline.elapsedSeconds,
                    variantElapsedSeconds: result.elapsedSeconds
                )
                rows.append(row)
                summary.add(row)
                try SavedRecordingEvalSupport.appendJSONL(row, to: outputURL)
            }
        }

        print(summary.report(
            recordingCount: selectedRecordings.count,
            variantCount: variants.count,
            outputURL: outputURL,
            rows: rows
        ))
    }

    private static func contextVariants(canonicalizer: TranscriptCanonicalizer) -> [SpeechContextEvalVariant] {
        let production = boundedContext(["Epos"] + canonicalizer.speechContextualStrings)
        return [
            SpeechContextEvalVariant(name: "none", contextualStrings: []),
            SpeechContextEvalVariant(name: "production-setContext", contextualStrings: production),
            SpeechContextEvalVariant(
                name: "production-initializer",
                contextualStrings: production,
                applicationMode: .initializer
            ),
            SpeechContextEvalVariant(
                name: "production-alternatives",
                contextualStrings: production,
                includeAlternatives: true
            ),
            SpeechContextEvalVariant(
                name: "project-expanded-setContext",
                contextualStrings: boundedContext(production + projectContextTerms)
            ),
            SpeechContextEvalVariant(
                name: "positive-control-alternatives",
                contextualStrings: boundedContext(positiveControlContextTerms),
                includeAlternatives: true
            )
        ]
    }

    private static func boundedContext(_ terms: [String]) -> [String] {
        var seen: Set<String> = []
        var output: [String] = []
        for term in terms {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard seen.insert(trimmed.lowercased()).inserted else { continue }
            output.append(trimmed)
            if output.count == TranscriptCanonicalizer.maxSpeechContextualStringCount {
                return output
            }
        }
        return output
    }

    private static func vocabularyHits(in text: String, terms: [String]) -> [String] {
        let lowercasedText = text.lowercased()
        return terms.filter { lowercasedText.contains($0.lowercased()) }
    }

    private static func contextReadbackMatches(expected: [String], actual: [String]) -> Bool {
        expected.map { $0.lowercased() } == actual.map { $0.lowercased() }
    }

    private static let projectContextTerms = [
        "Apple Speech",
        "FoundationModels",
        "Foundation Models",
        "SpeechTranscriber",
        "Speech Transcriber",
        "SpeechAnalyzer",
        "Speech Analyzer",
        "AnalysisContext",
        "contextualStrings",
        "TranscriptPolisher",
        "TranscriptCanonicalizer",
        "AppCoordinator",
        "DogfoodPipelineEvalTests",
        "SpeechContextEvalTests",
        "swift test",
        "swiftlint",
        "xcodebuild",
        "macOS",
        "Accessibility",
        "AVAudioEngine",
        "UserDefaults",
        "fn key",
        "push-to-talk",
        "canonicalizer",
        "prewarm"
    ]

    private static let positiveControlContextTerms = [
        "Epos",
        "CMUX",
        "CMOX",
        "Siemux",
        "see mux",
        "CLAUDE.md",
        "cloud.md",
        "cloud dot md",
        "project.yml",
        "project.yamo",
        "project dot yml",
        "AGENTS.md",
        "agent's file",
        "README.md",
        "read me",
        "Stath",
        "Stas",
        "NetSuite",
        "FoundationModels",
        "Foundation Models",
        "SpeechTranscriber"
    ]
}
