import AVFoundation
import Foundation
import OSLog
import Speech

/// Streaming result emitted by `Transcriber` while a recording is in progress.
public enum TranscriptEvent: Equatable {
    case partial(String)
    case final(String)
    case failed(String)
}

/// Wraps `SpeechAnalyzer` + a `SpeechTranscriber` module.
/// `start()` builds a fresh analyzer + module per call; do not reuse a single session.
/// `accept(_:)` is safe to call from the audio thread.
public final class Transcriber: @unchecked Sendable {
    public let locale: Locale

    private static let log = Logger(subsystem: "com.steez.SteezFlow", category: "transcriber")

    private let lock = NSLock()
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var eventContinuation: AsyncStream<TranscriptEvent>.Continuation?
    private var drainTask: Task<Void, Never>?

    public init(locale: Locale = Locale(identifier: "en-US")) {
        self.locale = locale
    }

    /// Best PCM format the underlying `SpeechTranscriber` accepts for this locale.
    /// Call once at bootstrap; the coordinator hands the result to `AudioCapture.start`.
    public func bestAudioFormat() async -> AVAudioFormat? {
        let probe = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        return await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [probe])
    }

    /// Begin a new transcription session. Returns an async stream of partial + final results.
    /// Caller feeds PCM buffers via `accept(_:)` and ends the session with `finish()`.
    /// Throws `TranscriberError.alreadyRunning` if a prior session hasn't been `finish`ed.
    public func start() async throws -> AsyncStream<TranscriptEvent> {
        let alreadyRunning = lock.withLock { self.analyzer != nil }
        if alreadyRunning {
            throw TranscriberError.alreadyRunning
        }
        // `init(inputSequence:modules:)` is sync — it only stores references.
        // The analyzer does not begin consuming the sequence until `start(inputSequence:)`.
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)

        let (inputStream, inputCont) = AsyncStream<AnalyzerInput>.makeStream()
        let (eventStream, eventCont) = AsyncStream<TranscriptEvent>.makeStream()

        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // Drain must subscribe BEFORE analyzer.start, otherwise early results are dropped.
        let drain = Task {
            var count = 0
            do {
                for try await result in transcriber.results {
                    count += 1
                    let text = String(result.text.characters)
                    if result.isFinal {
                        eventCont.yield(.final(text))
                    } else {
                        eventCont.yield(.partial(text))
                    }
                }
                Self.log.info("results stream completed (results=\(count, privacy: .public))")
                eventCont.finish()
            } catch {
                let message = String(describing: error)
                Self.log.error("results stream failed after \(count, privacy: .public): \(message, privacy: .public)")
                eventCont.yield(.failed(message))
                eventCont.finish()
            }
        }

        try await analyzer.start(inputSequence: inputStream)

        lock.withLock {
            self.analyzer = analyzer
            self.inputContinuation = inputCont
            self.eventContinuation = eventCont
            self.drainTask = drain
        }

        Self.log.info("session started for locale \(self.locale.identifier, privacy: .public)")
        return eventStream
    }

    /// Feed a captured audio buffer into the active session. Thread-safe.
    public func accept(_ buffer: AVAudioPCMBuffer) {
        let continuation = lock.withLock { inputContinuation }
        continuation?.yield(AnalyzerInput(buffer: buffer))
    }

    /// Signal end of input; the session will emit a final result then complete the stream.
    public func finish() async {
        let (analyzer, inputCont, drain) = lock.withLock {
            () -> (SpeechAnalyzer?, AsyncStream<AnalyzerInput>.Continuation?, Task<Void, Never>?) in
            let analyzer = self.analyzer
            let inputCont = self.inputContinuation
            let drain = self.drainTask
            self.analyzer = nil
            self.inputContinuation = nil
            self.drainTask = nil
            // Keep eventContinuation alive so the drain Task can finish it.
            self.eventContinuation = nil
            return (analyzer, inputCont, drain)
        }

        inputCont?.finish()

        if let analyzer {
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                let message = String(describing: error)
                Self.log.error("finalize failed: \(message, privacy: .public)")
            }
        }

        await drain?.value
        Self.log.info("session finished for locale \(self.locale.identifier, privacy: .public)")
    }
}

enum TranscriberError: Error {
    case alreadyRunning
}
