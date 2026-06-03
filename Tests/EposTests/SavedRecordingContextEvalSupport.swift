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
        var finalText = ""
        var failures: [String] = []
        var alternatives: [String] = []
        do {
            for try await result in transcriber.results {
                guard result.isFinal else { continue }
                finalText += String(result.text.characters)
                alternatives += result.alternatives.map { String($0.characters) }
            }
        } catch {
            failures.append(String(describing: error))
        }
        return Transcription(
            text: finalText.trimmingCharacters(in: .whitespacesAndNewlines),
            failureMessages: failures,
            alternatives: uniqueNonEmpty(alternatives)
        )
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
