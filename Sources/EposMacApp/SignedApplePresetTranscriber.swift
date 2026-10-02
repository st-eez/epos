#if DEBUG
import AVFoundation
import Epos
import Foundation
import Speech

enum ApplePresetArm: String, CaseIterable, Codable {
    case speechProgressiveFast = "speech-progressive-fast"
    case speechProgressiveQuality = "speech-progressive-quality"
    case speechFinal = "speech-final"
    case dictationShort = "dictation-short"
    case dictationLong = "dictation-long"

    static let baseline = Self.speechProgressiveFast

    var configuration: String {
        switch self {
        case .speechProgressiveFast:
            "Production SpeechTranscriber preset with frozen canonical vocabulary"
        case .speechProgressiveQuality:
            "Unhinted SpeechTranscriber volatileResults"
        case .speechFinal:
            "Unhinted SpeechTranscriber.Preset.transcription"
        case .dictationShort:
            "Unhinted DictationTranscriber.Preset.shortDictation"
        case .dictationLong:
            "Unhinted DictationTranscriber.Preset.longDictation"
        }
    }
}

struct ApplePresetAvailability {
    let available: [ApplePresetArm: Locale]
    let unavailable: [ApplePresetArm: String]

    static func resolve(locale: Locale) async -> Self {
        var available: [ApplePresetArm: Locale] = [:]
        var unavailable: [ApplePresetArm: String] = [:]

        if let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            let module = SpeechTranscriber(locale: supported, preset: .transcription)
            let status = await AssetInventory.status(forModules: [module])
            for arm in [ApplePresetArm.speechProgressiveFast, .speechProgressiveQuality, .speechFinal] {
                if status == .installed {
                    available[arm] = supported
                } else {
                    unavailable[arm] = "assets are \(status), not installed"
                }
            }
        } else {
            for arm in [ApplePresetArm.speechProgressiveFast, .speechProgressiveQuality, .speechFinal] {
                unavailable[arm] = "SpeechTranscriber does not support \(locale.identifier)"
            }
        }

        if let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
            let module = DictationTranscriber(locale: supported, preset: .shortDictation)
            let preparation = await prepareIfNeeded(module: module)
            for arm in [ApplePresetArm.dictationShort, .dictationLong] {
                if preparation.installed {
                    available[arm] = supported
                } else {
                    unavailable[arm] = preparation.failure
                        ?? "assets are not installed"
                }
            }
        } else {
            for arm in [ApplePresetArm.dictationShort, .dictationLong] {
                unavailable[arm] = "DictationTranscriber does not support \(locale.identifier)"
            }
        }

        return Self(available: available, unavailable: unavailable)
    }

    private static func prepareIfNeeded<Module: SpeechModule>(
        module: Module
    ) async -> (installed: Bool, failure: String?) {
        let initial = await AssetInventory.status(forModules: [module])
        guard initial != .installed else { return (true, nil) }
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                try await request.downloadAndInstall()
            }
            let installed = await AssetInventory.status(forModules: [module]) == .installed
            return (installed, installed ? nil : "assets are not installed after preparation")
        } catch {
            return (false, String(describing: error))
        }
    }
}

enum ApplePresetTranscriber {
    static func transcribe(
        recording: URL,
        locale: Locale,
        arm: ApplePresetArm,
        contextualStrings: [String] = []
    ) async throws -> ApplePresetTranscription {
        switch arm {
        case .speechProgressiveFast:
            return try await transcribe(
                recording: recording,
                module: SpeechTranscriber(locale: locale, preset: Transcriber.speechPreset),
                analysisContext: Transcriber.analysisContext(contextualStrings: contextualStrings)
            ) { String($0.text.characters) }
        case .speechProgressiveQuality:
            let preset = SpeechTranscriber.Preset(
                transcriptionOptions: [],
                reportingOptions: [.volatileResults],
                attributeOptions: [.transcriptionConfidence]
            )
            return try await transcribe(
                recording: recording,
                module: SpeechTranscriber(locale: locale, preset: preset)
            ) { String($0.text.characters) }
        case .speechFinal:
            return try await transcribe(
                recording: recording,
                module: SpeechTranscriber(locale: locale, preset: .transcription)
            ) { String($0.text.characters) }
        case .dictationShort:
            return try await transcribe(
                recording: recording,
                module: DictationTranscriber(locale: locale, preset: .shortDictation)
            ) { String($0.text.characters) }
        case .dictationLong:
            return try await transcribe(
                recording: recording,
                module: DictationTranscriber(locale: locale, preset: .longDictation)
            ) { String($0.text.characters) }
        }
    }

    private static func transcribe<Module: SpeechModule>(
        recording: URL,
        module: Module,
        analysisContext: AnalysisContext? = nil,
        resultText: @escaping @Sendable (Module.Result) -> String
    ) async throws -> ApplePresetTranscription {
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw ApplePresetTranscriberError.noCompatibleFormat
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [module])
        let collector = Task {
            var committedText = ""
            var volatileText = ""
            do {
                for try await result in module.results {
                    let text = resultText(result)
                    if result.isFinal {
                        committedText += text
                        volatileText = ""
                    } else {
                        volatileText = text
                    }
                }
                return Result<String, Error>.success(committedText + volatileText)
            } catch {
                return .failure(error)
            }
        }

        let contextReadback: [String]
        do {
            if let analysisContext {
                try await analyzer.setContext(analysisContext)
            }
            contextReadback = await analyzer.context.contextualStrings[.general] ?? []
            try await analyzer.start(inputSequence: stream)
            try feed(recording: recording, targetFormat: format) {
                continuation.yield(AnalyzerInput(buffer: $0))
            }
            continuation.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            continuation.finish()
            await analyzer.cancelAndFinishNow()
            collector.cancel()
            throw error
        }

        return ApplePresetTranscription(
            text: try await collector.value.get().trimmingCharacters(in: .whitespacesAndNewlines),
            contextReadback: contextReadback
        )
    }

    static func feed(
        recording: URL,
        targetFormat: AVAudioFormat,
        accept: (AVAudioPCMBuffer) -> Void
    ) throws {
        let file = try AVAudioFile(forReading: recording)
        let inputFormat = file.processingFormat
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw ApplePresetTranscriberError.converterUnavailable
        }
        converter.primeMethod = .none

        while file.framePosition < file.length {
            let remaining = file.length - file.framePosition
            let capacity = AVAudioFrameCount(min(remaining, 4_096))
            guard let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: capacity) else {
                throw ApplePresetTranscriberError.bufferUnavailable
            }
            try file.read(into: input, frameCount: capacity)
            guard input.frameLength > 0 else { continue }

            let ratio = targetFormat.sampleRate / inputFormat.sampleRate
            let outputCapacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 1
            guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
                throw ApplePresetTranscriberError.bufferUnavailable
            }
            let pending = AudioInputBox(input)
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                guard let next = pending.take() else {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                inputStatus.pointee = .haveData
                return next
            }
            if status == .error {
                throw conversionError ?? ApplePresetTranscriberError.conversionFailed
            }
            if output.frameLength > 0 {
                accept(output)
            }
        }
    }
}

struct ApplePresetTranscription {
    let text: String
    let contextReadback: [String]
}

private final class AudioInputBox: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}

private enum ApplePresetTranscriberError: Error {
    case bufferUnavailable
    case converterUnavailable
    case conversionFailed
    case noCompatibleFormat
}
#endif
