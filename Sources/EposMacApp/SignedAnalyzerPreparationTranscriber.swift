#if DEBUG
import AVFoundation
import Darwin
import Epos
import Foundation
import Speech

enum AnalyzerPreparationArm: String, CaseIterable, Codable {
    case unprepared
    case inline
    case advance
}

struct AnalyzerPreparationAudio: @unchecked Sendable {
    let format: AVAudioFormat
    let buffers: [AVAudioPCMBuffer]
    let durationSeconds: Double

    var expectedFrames: UInt64 {
        buffers.reduce(0) { $0 + UInt64($1.frameLength) }
    }

    func feed(
        into continuation: AsyncStream<(AnalyzerInput, UInt64)>.Continuation,
        holdStarted: ContinuousClock.Instant,
        waitUntil: @Sendable (ContinuousClock.Instant) async throws -> Void = {
            try await ContinuousClock().sleep(until: $0)
        }
    ) async throws -> (submittedFrames: UInt64, firstInput: ContinuousClock.Instant?) {
        var submittedFrames: UInt64 = 0
        var firstInput: ContinuousClock.Instant?
        var elapsedAudioSeconds = 0.0
        for buffer in buffers {
            try Task.checkCancellation()
            elapsedAudioSeconds += Double(buffer.frameLength) / format.sampleRate
            // Capture starts at the hold, even while setup awaits. Buffers whose
            // tap time passed arrive as startup audio when the analyzer is ready.
            try await waitUntil(holdStarted.advanced(by: .seconds(elapsedAudioSeconds)))
            try Task.checkCancellation()
            if firstInput == nil { firstInput = .now }
            let frames = UInt64(buffer.frameLength)
            switch continuation.yield((AnalyzerInput(buffer: buffer), frames)) {
            case .enqueued:
                submittedFrames += frames
            case .dropped, .terminated:
                throw PreparationEvalError.audioInputRefused
            @unknown default:
                throw PreparationEvalError.audioInputRefused
            }
        }
        return (submittedFrames, firstInput)
    }

    func verifyFrames(submitted: UInt64, consumed: UInt64) throws {
        guard submitted == expectedFrames, consumed == expectedFrames else {
            throw PreparationEvalError.audioFrameMismatch
        }
    }

    static func load(recording: URL, locale: Locale) async throws -> Self {
        let probe = SpeechTranscriber(locale: locale, preset: Transcriber.speechPreset)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [probe]) else {
            throw PreparationEvalError.noCompatibleFormat
        }
        var buffers: [AVAudioPCMBuffer] = []
        try ApplePresetTranscriber.feed(recording: recording, targetFormat: format) {
            buffers.append($0)
        }
        guard !buffers.isEmpty else { throw PreparationEvalError.emptyAudio }
        let duration = buffers.reduce(0.0) { $0 + Double($1.frameLength) / format.sampleRate }
        return Self(format: format, buffers: buffers, durationSeconds: duration)
    }
}

struct AnalyzerPreparationMetrics: Codable {
    let preparationMilliseconds: Double
    let setupBeforeHoldMilliseconds: Double
    let idleSeconds: Double
    let analyzerStartMilliseconds: Double
    let holdToFirstResultMilliseconds: Double?
    let inputToFirstResultMilliseconds: Double?
    let releaseToFinalMilliseconds: Double
    let holdToCompletionMilliseconds: Double
    let expectedAudioFrames: UInt64
    let submittedAudioFrames: UInt64
    let consumedAudioFrames: UInt64
    let rssBeforeSetupBytes: UInt64?
    let rssAtReadinessBytes: UInt64?
    let rssAfterIdleBytes: UInt64?
}

struct AnalyzerPreparationResult {
    let transcript: String
    let contextReadback: [String]
    let metrics: AnalyzerPreparationMetrics
}

enum SignedAnalyzerPreparationTranscriber {
    static func transcribe(
        audio: AnalyzerPreparationAudio,
        locale: Locale,
        arm: AnalyzerPreparationArm,
        contextualStrings: [String],
        idleSeconds: Double
    ) async throws -> AnalyzerPreparationResult {
        let rssBefore = residentMemoryBytes()
        let setupStarted = ContinuousClock.now
        var holdStarted = setupStarted
        let module = SpeechTranscriber(locale: locale, preset: Transcriber.speechPreset)
        let analyzer = SpeechAnalyzer(modules: [module])
        let (stream, continuation) = AsyncStream<(AnalyzerInput, UInt64)>.makeStream(bufferingPolicy: .bufferingOldest(512))
        let consumedFrames = PreparationFrameCount()
        let trackedInput = stream.map { input, frames in
            consumedFrames.add(frames)
            return input
        }
        let collector = Task {
            var committed = ""
            var volatile = ""
            var firstResult: ContinuousClock.Instant?
            for try await result in module.results {
                let text = String(result.text.characters)
                if firstResult == nil, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    firstResult = .now
                }
                if result.isFinal {
                    committed += text
                    volatile = ""
                } else {
                    volatile = text
                }
            }
            return (text: (committed + volatile).trimmingCharacters(in: .whitespacesAndNewlines), firstResult: firstResult)
        }

        do {
            if let context = Transcriber.analysisContext(contextualStrings: contextualStrings) {
                try await analyzer.setContext(context)
            }
            let contextReadback = await analyzer.context.contextualStrings[.general] ?? []
            guard contextReadback == contextualStrings else {
                throw ApplePresetContextError.readbackMismatch
            }
            let preparationStarted = ContinuousClock.now
            if arm != .unprepared {
                try await analyzer.prepareToAnalyze(in: audio.format)
            }
            let preparationMilliseconds = arm == .unprepared ? 0 : milliseconds(since: preparationStarted)
            let rssAtReadiness = residentMemoryBytes()
            var rssAfterIdle: UInt64?
            var setupBeforeHoldMilliseconds = 0.0
            if arm == .advance {
                setupBeforeHoldMilliseconds = milliseconds(since: setupStarted)
                try await Task.sleep(for: .seconds(idleSeconds))
                rssAfterIdle = residentMemoryBytes()
                holdStarted = .now
            }
            try Task.checkCancellation()
            let startStarted = ContinuousClock.now
            try await analyzer.start(inputSequence: trackedInput)
            let analyzerStartMilliseconds = milliseconds(since: startStarted)
            let feed = try await audio.feed(into: continuation, holdStarted: holdStarted)
            let released = holdStarted.advanced(by: .seconds(audio.durationSeconds))
            continuation.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            let collected = try await collector.value
            try audio.verifyFrames(submitted: feed.submittedFrames, consumed: consumedFrames.value)
            return AnalyzerPreparationResult(
                transcript: collected.text,
                contextReadback: contextReadback,
                metrics: AnalyzerPreparationMetrics(
                    preparationMilliseconds: preparationMilliseconds,
                    setupBeforeHoldMilliseconds: setupBeforeHoldMilliseconds,
                    idleSeconds: arm == .advance ? idleSeconds : 0,
                    analyzerStartMilliseconds: analyzerStartMilliseconds,
                    holdToFirstResultMilliseconds: collected.firstResult.map { milliseconds(from: holdStarted, to: $0) },
                    inputToFirstResultMilliseconds: collected.firstResult.flatMap { firstResult in
                        feed.firstInput.map { milliseconds(from: $0, to: firstResult) }
                    },
                    releaseToFinalMilliseconds: milliseconds(since: released),
                    holdToCompletionMilliseconds: milliseconds(since: holdStarted),
                    expectedAudioFrames: audio.expectedFrames,
                    submittedAudioFrames: feed.submittedFrames,
                    consumedAudioFrames: consumedFrames.value,
                    rssBeforeSetupBytes: rssBefore,
                    rssAtReadinessBytes: rssAtReadiness,
                    rssAfterIdleBytes: rssAfterIdle
                )
            )
        } catch {
            continuation.finish()
            collector.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }

    static func residentMemoryBytes() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? info.resident_size : nil
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        milliseconds(from: start, to: .now)
    }

    private static func milliseconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: end).components
        return Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15
    }
}

private final class PreparationFrameCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count: UInt64 = 0
    var value: UInt64 { lock.withLock { count } }

    func add(_ frames: UInt64) {
        lock.withLock { count += frames }
    }
}

enum PreparationEvalError: Error {
    case noCompatibleFormat
    case emptyAudio
    case audioInputRefused
    case audioFrameMismatch
    case invalidConfiguration(String)
    case audioDigestMismatch(String)
    case assetsUnavailable(String)
}
#endif
