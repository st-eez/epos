import CryptoKit
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
/// - `EPOS_EVAL_DEFAULTS_DOMAIN`: UserDefaults domain to load correction records from,
///   such as the installed app's bundle identifier.
/// - `EPOS_EVAL_GROUND_TRUTH_ONLY=1`: limit selection to recordings with
///   human-intended transcripts in the ground-truth manifest.
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
        let groundTruthManifest = try SavedRecordingEvalSupport.groundTruthManifest(
            in: recordingsDirectory,
            environment: environment
        )
        let outputURL = SavedRecordingEvalSupport.outputURL(
            environment: environment,
            defaultPath: ".build/evals/speech-context-eval.jsonl"
        )
        let allSelectedRecordings = try SavedRecordingEvalSupport.selectedRecordings(
            in: recordingsDirectory,
            limit: environment["EPOS_EVAL_LIMIT"].flatMap(Int.init),
            latest: SavedRecordingEvalSupport.isTruthy(environment["EPOS_EVAL_LATEST"]),
            environment: environment
        )
        let selectedRecordings = Self.filteredForGroundTruthIfNeeded(
            allSelectedRecordings,
            manifest: groundTruthManifest,
            environment: environment
        )
        try XCTSkipIf(selectedRecordings.isEmpty, "No .wav recordings found at \(recordingsDirectory.path)")

        let correctionDictionary = Self.correctionDictionary(environment: environment)
        let canonicalizer = TranscriptCanonicalizer(
            rules: CorrectionRuleCompiler.compile(records: correctionDictionary.records)
        )
        let correctionDictionaryFingerprint = try Self.fingerprint(correctionDictionary)
        let variants = Self.contextVariants(canonicalizer: canonicalizer)
        let baselineVariant = variants[0]
        try SavedRecordingEvalSupport.prepareOutput(outputURL)

        var summary = SpeechContextEvalSummary()
        var rows: [SpeechContextEvalRow] = []
        for recording in selectedRecordings {
            let audioDuration = try SavedRecordingEvalSupport.durationSeconds(recording: recording)
            let audioSHA256 = try Self.fileFingerprint(recording)
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
                    alternativeTranscripts: transcription.alternativeTranscripts,
                    alternativeTranscriptCandidates: transcription.alternativeTranscriptCandidates,
                    confidenceMean: transcription.confidenceMean,
                    confidenceMinimum: transcription.confidenceMinimum,
                    elapsedSeconds: Date().timeIntervalSince(started)
                ))
            }

            let baseline = try XCTUnwrap(results.first)
            let humanIntendedTranscript = groundTruthManifest.transcript(for: recording)
            let baselineTranscriptScore = humanIntendedTranscript.map {
                TranscriptEvalScoring.wordErrorScore(reference: $0, hypothesis: baseline.text)
            }
            let baselineCanonicalizedTranscriptScore = humanIntendedTranscript.map {
                TranscriptEvalScoring.wordErrorScore(reference: $0, hypothesis: baseline.canonicalizedText)
            }
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
                let variantTranscriptScore = humanIntendedTranscript.map {
                    TranscriptEvalScoring.wordErrorScore(reference: $0, hypothesis: result.text)
                }
                let variantCanonicalizedTranscriptScore = humanIntendedTranscript.map {
                    TranscriptEvalScoring.wordErrorScore(reference: $0, hypothesis: result.canonicalizedText)
                }
                let bestAlternative = humanIntendedTranscript.flatMap { reference in
                    Self.bestAlternativeTranscript(
                        candidates: result.alternativeTranscriptCandidates,
                        reference: reference
                    )
                }
                let bestCanonicalizedAlternative = humanIntendedTranscript.flatMap { reference in
                    Self.bestAlternativeTranscript(
                        candidates: result.alternativeTranscriptCandidates.map {
                            SavedRecordingEvalSupport.AlternativeTranscriptCandidate(
                                text: canonicalizer.canonicalize($0.text),
                                confidenceMean: $0.confidenceMean
                            )
                        },
                        reference: reference
                    )
                }
                let alternativeReranking = Self.alternativeReranking(
                    result: result,
                    canonicalizer: canonicalizer,
                    humanIntendedTranscript: humanIntendedTranscript
                )

                let row = SpeechContextEvalRow(
                    evalSchemaVersion: 1,
                    file: recording.lastPathComponent,
                    audioSHA256: audioSHA256,
                    localeIdentifier: locale.identifier,
                    audioDurationSeconds: audioDuration,
                    humanIntendedTranscript: humanIntendedTranscript,
                    baselineVariant: baselineVariant.name,
                    variant: result.variant,
                    contextTermCount: result.contextTermCount,
                    applicationMode: result.applicationMode,
                    includeAlternatives: result.includeAlternatives,
                    contextReadbackCount: result.contextReadback.count,
                    contextReadbackTerms: result.contextReadback,
                    contextReadbackMatches: contextReadbackMatches,
                    baselineText: baseline.text,
                    variantText: result.text,
                    baselineTranscriptScore: baselineTranscriptScore,
                    variantTranscriptScore: variantTranscriptScore,
                    baselineCanonicalized: baseline.canonicalizedText,
                    variantCanonicalized: result.canonicalizedText,
                    baselineCanonicalizedTranscriptScore: baselineCanonicalizedTranscriptScore,
                    variantCanonicalizedTranscriptScore: variantCanonicalizedTranscriptScore,
                    baselineVocabularyHits: Self.vocabularyHits(in: baseline.text, terms: result.contextualStrings),
                    variantVocabularyHits: result.vocabularyHits,
                    variantAlternatives: result.alternatives,
                    variantAlternativeTranscriptCandidates: result.alternativeTranscripts,
                    variantConfidenceMean: result.confidenceMean,
                    variantConfidenceMinimum: result.confidenceMinimum,
                    correctionDictionaryFingerprint: correctionDictionaryFingerprint,
                    appliedCorrectionRecordIDs: correctionDictionary.appliedRecordIDs(in: result.text),
                    bestAlternativeTranscript: bestAlternative?.text,
                    bestAlternativeTranscriptScore: bestAlternative?.score,
                    bestAlternativeTranscriptConfidenceMean: bestAlternative?.confidenceMean,
                    bestCanonicalizedAlternativeTranscript: bestCanonicalizedAlternative?.text,
                    bestCanonicalizedAlternativeTranscriptScore: bestCanonicalizedAlternative?.score,
                    bestCanonicalizedAlternativeTranscriptConfidenceMean: bestCanonicalizedAlternative?.confidenceMean,
                    alternativeReranking: alternativeReranking,
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
            groundTruthSourceURL: groundTruthManifest.sourceURL,
            outputURL: outputURL,
            rows: rows
        ))
    }

    private static func filteredForGroundTruthIfNeeded(
        _ recordings: [URL],
        manifest: HumanIntendedTranscriptManifest,
        environment: [String: String]
    ) -> [URL] {
        guard SavedRecordingEvalSupport.isTruthy(environment["EPOS_EVAL_GROUND_TRUTH_ONLY"]) else {
            return recordings
        }
        return recordings.filter { manifest.transcript(for: $0) != nil }
    }

    private static func correctionDictionary(
        environment: [String: String]
    ) -> CorrectionDictionary {
        let domain = environment["EPOS_EVAL_DEFAULTS_DOMAIN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let domain, !domain.isEmpty else {
            return CorrectionDictionary.load()
        }

        guard let defaults = UserDefaults(suiteName: domain) else {
            return CorrectionDictionary.load()
        }
        return CorrectionDictionary.load(from: defaults)
    }

    private static func fingerprint(_ dictionary: CorrectionDictionary) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(dictionary.records)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func fileFingerprint(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func alternativeReranking(
        result: SpeechContextVariantResult,
        canonicalizer: TranscriptCanonicalizer,
        humanIntendedTranscript: String?
    ) -> AlternativeTranscriptRerankingEvalResult? {
        guard result.includeAlternatives else { return nil }
        let selection = AlternativeTranscriptReranker.rerank(
            topTranscript: result.text,
            topConfidenceMean: result.confidenceMean,
            candidates: result.alternativeTranscriptCandidates
        )
        return selection.scored(
            reference: humanIntendedTranscript,
            canonicalizedTranscript: canonicalizer.canonicalize(selection.selectedTranscript)
        )
    }

    private static func bestAlternativeTranscript(
        candidates: [SavedRecordingEvalSupport.AlternativeTranscriptCandidate],
        reference: String
    ) -> (text: String, score: TranscriptWordErrorScore, confidenceMean: Double?)? {
        candidates
            .map { candidate in
                (
                    text: candidate.text,
                    score: TranscriptEvalScoring.wordErrorScore(reference: reference, hypothesis: candidate.text),
                    confidenceMean: candidate.confidenceMean
                )
            }
            .min { lhs, rhs in
                if lhs.score.wordErrorRate != rhs.score.wordErrorRate {
                    return lhs.score.wordErrorRate < rhs.score.wordErrorRate
                }
                return lhs.score.wordErrors < rhs.score.wordErrors
            }
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
