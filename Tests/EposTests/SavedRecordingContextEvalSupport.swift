import AVFoundation
import Foundation
import Speech
@testable import Epos

extension SavedRecordingEvalSupport {
    static func transcribeForContextEval(
        recording: URL,
        locale: Locale,
        contextualStrings: [String],
        applicationMode: SpeechContextApplicationMode,
        includeAlternatives: Bool
    ) async throws -> Transcription {
        let transcriber = evalTranscriber(locale: locale, includeAlternatives: includeAlternatives)
        guard let targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw SavedRecordingEvalError.noCompatibleFormat
        }

        let analysisContext = Transcriber.analysisContext(contextualStrings: contextualStrings)
        let (inputStream, inputCont) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = analyzer(
            transcriber: transcriber,
            inputStream: inputStream,
            analysisContext: analysisContext,
            applicationMode: applicationMode
        )
        let collector = Task { await collectResults(from: transcriber) }

        let contextReadback: [String]
        do {
            contextReadback = try await startIfNeeded(
                analyzer,
                inputStream: inputStream,
                analysisContext: analysisContext,
                applicationMode: applicationMode
            )
            try feed(recording: recording, targetFormat: targetFormat) { buffer in
                inputCont.yield(AnalyzerInput(buffer: buffer))
            }
            inputCont.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            inputCont.finish()
            await analyzer.cancelAndFinishNow()
            collector.cancel()
            throw error
        }

        let collected = await collector.value
        let transcription = Transcription(
            text: collected.text,
            failureMessages: collected.failureMessages,
            alternatives: includeAlternatives ? collected.alternatives : [],
            alternativeTranscripts: includeAlternatives ? collected.alternativeTranscripts : [],
            alternativeTranscriptCandidates: includeAlternatives ? collected.alternativeTranscriptCandidates : [],
            confidenceMean: collected.confidenceMean,
            confidenceMinimum: collected.confidenceMinimum,
            contextReadback: contextReadback
        )
        if let failure = transcription.failureMessages.first {
            throw SavedRecordingEvalError.transcriptionFailed(recording.lastPathComponent, failure)
        }
        return transcription
    }

    private static func evalTranscriber(locale: Locale, includeAlternatives: Bool) -> SpeechTranscriber {
        var reportingOptions: Set<SpeechTranscriber.ReportingOption> = [.volatileResults, .fastResults]
        if includeAlternatives {
            reportingOptions.insert(.alternativeTranscriptions)
        }
        return SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: reportingOptions,
            attributeOptions: [.transcriptionConfidence]
        )
    }

    private static func analyzer(
        transcriber: SpeechTranscriber,
        inputStream: AsyncStream<AnalyzerInput>,
        analysisContext: AnalysisContext?,
        applicationMode: SpeechContextApplicationMode
    ) -> SpeechAnalyzer {
        switch applicationMode {
        case .setContextBeforeStart:
            SpeechAnalyzer(modules: [transcriber])
        case .initializer:
            SpeechAnalyzer(
                inputSequence: inputStream,
                modules: [transcriber],
                analysisContext: analysisContext ?? AnalysisContext()
            )
        }
    }

    private static func startIfNeeded(
        _ analyzer: SpeechAnalyzer,
        inputStream: AsyncStream<AnalyzerInput>,
        analysisContext: AnalysisContext?,
        applicationMode: SpeechContextApplicationMode
    ) async throws -> [String] {
        switch applicationMode {
        case .setContextBeforeStart:
            if let analysisContext {
                try await analyzer.setContext(analysisContext)
            }
            let contextReadback = await analyzer.context.contextualStrings[.general] ?? []
            try await analyzer.start(inputSequence: inputStream)
            return contextReadback
        case .initializer:
            return await analyzer.context.contextualStrings[.general] ?? []
        }
    }

    private static func collectResults(from transcriber: SpeechTranscriber) async -> Transcription {
        var finalSegments: [SpeechContextAlternativeSegment] = []
        var failures: [String] = []
        do {
            for try await result in transcriber.results {
                guard result.isFinal else { continue }
                finalSegments.append(SpeechContextAlternativeSegment(
                    text: attributedText(result.text),
                    alternatives: result.alternatives.map(attributedText(_:))
                ))
            }
        } catch {
            failures.append(String(describing: error))
        }
        let finalText = finalSegments.map(\.text.text).joined()
        let alternatives = finalSegments.flatMap { segment in segment.alternatives.map(\.text) }
        let candidateTranscripts = alternativeTranscriptCandidates(from: finalSegments)
        let confidenceSummary = confidenceSummary(finalSegments.map(\.text))
        return Transcription(
            text: finalText.trimmingCharacters(in: .whitespacesAndNewlines),
            failureMessages: failures,
            alternatives: uniqueNonEmpty(alternatives),
            alternativeTranscripts: candidateTranscripts.map(\.text),
            alternativeTranscriptCandidates: candidateTranscripts,
            confidenceMean: confidenceSummary.mean,
            confidenceMinimum: confidenceSummary.minimum
        )
    }

    private static func alternativeTranscriptCandidates(
        from segments: [SpeechContextAlternativeSegment]
    ) -> [AlternativeTranscriptCandidate] {
        let canonicalText = segments.map(\.text.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates: [AlternativeTranscriptCandidate] = []
        var seen: Set<String> = []
        for (index, segment) in segments.enumerated() {
            for alternative in segment.alternatives {
                var candidateSegments = segments.map(\.text)
                candidateSegments[index] = alternative
                let candidate = candidateSegments.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
                guard candidate != canonicalText else { continue }
                guard !candidate.isEmpty else { continue }
                guard seen.insert(candidate.lowercased()).inserted else { continue }
                candidates.append(AlternativeTranscriptCandidate(
                    text: candidate,
                    confidenceMean: confidenceSummary(candidateSegments).mean
                ))
            }
        }
        return candidates
    }

    private static func attributedText(_ value: AttributedString) -> SpeechContextAttributedText {
        let text = String(value.characters)
        let confidences = value.runs.compactMap {
            $0[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self]
        }
        return SpeechContextAttributedText(
            text: text,
            confidenceMean: mean(confidences),
            confidenceMinimum: confidences.min()
        )
    }

    private static func confidenceSummary(
        _ values: [SpeechContextAttributedText]
    ) -> (mean: Double?, minimum: Double?) {
        let means = values.compactMap(\.confidenceMean)
        let minimums = values.compactMap(\.confidenceMinimum)
        return (mean(means), minimums.min())
    }

    private static func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func uniqueNonEmpty(_ strings: [String]) -> [String] {
        var seen: Set<String> = []
        return strings.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            guard seen.insert(trimmed.lowercased()).inserted else { return nil }
            return trimmed
        }
    }
}

private struct SpeechContextAlternativeSegment {
    let text: SpeechContextAttributedText
    let alternatives: [SpeechContextAttributedText]
}

private struct SpeechContextAttributedText {
    let text: String
    let confidenceMean: Double?
    let confidenceMinimum: Double?
}
