import AVFoundation
import Foundation
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
/// `finish()` is idempotent and safe to call concurrently with — or immediately after —
/// `start()`. The lock-install inside `start()` precedes the `await` on analyzer start,
/// so a `finish()` racing the in-flight start sees the install and tears down cleanly.
public final class Transcriber: @unchecked Sendable {
    public let locale: Locale

    static let speechPreset = SpeechTranscriber.Preset(
        transcriptionOptions: [],
        reportingOptions: [.volatileResults, .alternativeTranscriptions],
        attributeOptions: [.transcriptionConfidence]
    )

    private static let log = SteezFlowLogger(category: "transcriber")
    private static let logFinalAlternativesKey = "debug.speech.logFinalAlternatives"

    private let lock = NSLock()
    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var eventContinuation: AsyncStream<TranscriptEvent>.Continuation?
    private var drainTask: Task<Void, Never>?
    private var startTask: Task<Void, Error>?
    private var hasReceivedBuffer = false

    public init(locale: Locale = Locale(identifier: "en-US")) {
        self.locale = locale
    }

    /// Best PCM format the underlying `SpeechTranscriber` accepts for this locale.
    /// Call once at bootstrap; the coordinator hands the result to `AudioCapture.start`.
    public func bestAudioFormat() async -> AVAudioFormat? {
        let probe = Self.makeTranscriber(locale: locale)
        return await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [probe])
    }

    /// Begin a new transcription session. Awaits `analyzer.start(inputSequence:)` per the
    /// swift-scribe / WWDC25 sample ordering before returning the event stream. State is
    /// installed under `lock` BEFORE the await, so a concurrent `finish()` sees the session
    /// and can drive teardown via `startTask.value`.
    /// Throws `TranscriberError.alreadyRunning` if a prior session hasn't been `finish`ed.
    public func start() async throws -> AsyncStream<TranscriptEvent> {
        let alreadyRunning = lock.withLock {
            self.analyzer != nil || self.startTask != nil
        }
        if alreadyRunning {
            throw TranscriberError.alreadyRunning
        }
        let transcriber = Self.makeTranscriber(locale: locale)

        let (inputStream, inputCont) = AsyncStream<AnalyzerInput>.makeStream()
        let (eventStream, eventCont) = AsyncStream<TranscriptEvent>.makeStream()

        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // Drain subscribes to transcriber.results immediately so early results aren't dropped.
        let drain = Task {
            var count = 0
            do {
                for try await result in transcriber.results {
                    count += 1
                    let text = String(result.text.characters)
                    if result.isFinal {
                        Self.logFinalAlternativesIfEnabled(result)
                        eventCont.yield(.final(text))
                    } else {
                        eventCont.yield(.partial(text))
                    }
                }
                Self.log.info("results stream completed (results=\(count))")
            } catch {
                let message = String(describing: error)
                Self.log.error("results stream failed after \(count): \(message)")
                eventCont.yield(.failed(message))
            }
            eventCont.finish()
        }

        let startT = Task<Void, Error> {
            try await analyzer.start(inputSequence: inputStream)
        }

        // Install state BEFORE awaiting startT.value so a racing finish() can observe + drive teardown.
        lock.withLock {
            self.analyzer = analyzer
            self.inputContinuation = inputCont
            self.eventContinuation = eventCont
            self.drainTask = drain
            self.startTask = startT
            self.hasReceivedBuffer = false
        }

        Self.log.info("session starting for locale \(self.locale.identifier)")
        do {
            try await startT.value
        } catch {
            // Caller (e.g. AppCoordinator.runSession) logs the error with its String(describing:).
            // finish() handles teardown of the installed state and re-awaits the already-failed
            // startTask cheaply (a completed Task's value is just a load).
            await finish()
            throw error
        }
        return eventStream
    }

    static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, preset: speechPreset)
    }

    private static func logFinalAlternativesIfEnabled(_ result: SpeechTranscriber.Result) {
        guard UserDefaults.standard.bool(forKey: logFinalAlternativesKey) else { return }
        let candidates = ([result.text] + result.alternatives)
            .prefix(8)
            .enumerated()
            .map { index, alternative in
                "\(index): \(String(alternative.characters))"
            }
            .joined(separator: " | ")
        log.info("debug final alternatives count=\(result.alternatives.count) candidates=\(candidates)")
    }

    /// Feed a captured audio buffer into the active session. Thread-safe.
    public func accept(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard let continuation = inputContinuation else { return }
            hasReceivedBuffer = true
            continuation.yield(AnalyzerInput(buffer: buffer))
        }
    }

    /// End the session. Idempotent — repeat calls after the first are no-ops.
    /// Falls back to `cancelAndFinishNow()` when no audio buffers ever reached the
    /// analyzer; `finalizeAndFinishThroughEndOfInput()` hangs on empty input.
    public func finish() async {
        let (analyzer, inputCont, drain, startT, eventCont, hadInput) = lock.withLock {
            () -> (SpeechAnalyzer?, AsyncStream<AnalyzerInput>.Continuation?, Task<Void, Never>?, Task<Void, Error>?, AsyncStream<TranscriptEvent>.Continuation?, Bool) in
            let analyzer = self.analyzer
            let inputCont = self.inputContinuation
            let drain = self.drainTask
            let startT = self.startTask
            let eventCont = self.eventContinuation
            let hadInput = self.hasReceivedBuffer
            self.analyzer = nil
            self.inputContinuation = nil
            self.drainTask = nil
            self.startTask = nil
            self.eventContinuation = nil
            return (analyzer, inputCont, drain, startT, eventCont, hadInput)
        }

        // Wait for any in-flight analyzer.start to settle before tearing down.
        _ = try? await startT?.value

        inputCont?.finish()

        if let analyzer {
            if hadInput {
                do {
                    try await analyzer.finalizeAndFinishThroughEndOfInput()
                } catch {
                    let message = String(describing: error)
                    Self.log.error("finalize failed: \(message)")
                    // A failed finalize can leave `transcriber.results` dangling;
                    // force-close the event stream and cancel the drain so the
                    // `await drain?.value` below cannot hang.
                    eventCont?.finish()
                    drain?.cancel()
                }
                await drain?.value
            } else {
                // `cancelAndFinishNow()` returns promptly, but Apple's
                // `SpeechTranscriber.results` AsyncSequence does NOT terminate
                // when no input was ever fed. Awaiting `drain.value` here would
                // block forever (rapid-fn-tap hang). Force-close our event
                // stream and cancel the drain task so finish() always returns.
                await analyzer.cancelAndFinishNow()
                eventCont?.finish()
                drain?.cancel()
            }
        }

        Self.log.info("session finished (hadInput=\(hadInput)) locale=\(self.locale.identifier)")
    }
}

enum TranscriberError: Error {
    case alreadyRunning
}
