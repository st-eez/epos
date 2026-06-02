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
/// Not an `actor`: `accept(_:)` must be callable *synchronously* from the realtime audio
/// thread (the `AudioCapture` tap), which actor isolation would force to be `async`. Hence
/// the manual `NSLock` + `@unchecked Sendable` rather than compiler-enforced isolation.
/// `finish()` is idempotent and safe to call concurrently with — or immediately after —
/// `start()`. The lock-install inside `start()` precedes the `await` on analyzer start,
/// so a `finish()` racing the in-flight start sees the install and tears down cleanly.
public final class Transcriber: @unchecked Sendable {
    public let locale: Locale

    static let speechPreset = SpeechTranscriber.Preset(
        transcriptionOptions: [],
        reportingOptions: [.volatileResults, .fastResults],
        attributeOptions: [.transcriptionConfidence]
    )

    private static let log = EposLogger(category: "transcriber")
    private static let logFinalAlternativesKey = "debug.speech.logFinalAlternatives"

    private let lock = NSLock()
    private var session: Session?

    /// All per-recording state, installed and torn down as a unit under `lock`. Grouping
    /// it means `finish()` extracts a single value instead of a six-field tuple, and the
    /// install/teardown can't drift field-by-field.
    private struct Session {
        let analyzer: SpeechAnalyzer
        let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
        let eventContinuation: AsyncStream<TranscriptEvent>.Continuation
        let drainTask: Task<Void, Never>
        let startTask: Task<Void, Error>
        var hasReceivedBuffer: Bool
    }

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
    ///
    /// `contextualStrings` biases recognition toward known vocabulary via
    /// `AnalysisContext`. It defaults to empty for tests and ad hoc callers; the
    /// production coordinator passes correction vocabulary for each recording.
    public func start(contextualStrings: [String] = []) async throws -> AsyncStream<TranscriptEvent> {
        let alreadyRunning = lock.withLock { self.session != nil }
        if alreadyRunning {
            throw TranscriberError.alreadyRunning
        }
        let transcriber = Self.makeTranscriber(locale: locale)
        let analysisContext = Self.analysisContext(contextualStrings: contextualStrings)

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
            if let analysisContext {
                do {
                    try await analyzer.setContext(analysisContext)
                } catch {
                    // Context is a recognition-quality optimization, not load-bearing:
                    // a failure to apply it must not abort the session.
                    Self.log.error("speech context apply failed: \(String(describing: error))")
                }
            }
            try await analyzer.start(inputSequence: inputStream)
        }

        // Install state BEFORE awaiting startT.value so a racing finish() can observe + drive teardown.
        lock.withLock {
            self.session = Session(
                analyzer: analyzer,
                inputContinuation: inputCont,
                eventContinuation: eventCont,
                drainTask: drain,
                startTask: startT,
                hasReceivedBuffer: false
            )
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

    /// Build an `AnalysisContext` from a bias list, trimming and de-duplicating.
    /// Returns nil for an empty list so the caller skips `setContext` entirely.
    static func analysisContext(contextualStrings: [String]) -> AnalysisContext? {
        var seen: Set<String> = []
        let strings = contextualStrings.compactMap { string -> String? in
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            guard seen.insert(trimmed.lowercased()).inserted else { return nil }
            return trimmed
        }
        .prefix(TranscriptCanonicalizer.maxSpeechContextualStringCount)
        guard !strings.isEmpty else { return nil }

        let context = AnalysisContext()
        context.contextualStrings[.general] = Array(strings)
        log.info("applying speech context count=\(strings.count)")
        return context
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
            session?.hasReceivedBuffer = true
            session?.inputContinuation.yield(AnalyzerInput(buffer: buffer))
        }
    }

    /// End the session. Idempotent — repeat calls after the first are no-ops.
    /// Falls back to `cancelAndFinishNow()` when no audio buffers ever reached the
    /// analyzer; `finalizeAndFinishThroughEndOfInput()` hangs on empty input.
    public func finish() async {
        let session = lock.withLock { () -> Session? in
            defer { self.session = nil }
            return self.session
        }
        guard let session else { return }

        // Wait for any in-flight analyzer.start to settle before tearing down.
        _ = try? await session.startTask.value

        session.inputContinuation.finish()

        if session.hasReceivedBuffer {
            do {
                try await session.analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                let message = String(describing: error)
                Self.log.error("finalize failed: \(message)")
                // A failed finalize can leave `transcriber.results` dangling;
                // force-close the event stream and cancel the drain so the
                // `await drainTask.value` below cannot hang.
                session.eventContinuation.finish()
                session.drainTask.cancel()
            }
            await session.drainTask.value
        } else {
            // `cancelAndFinishNow()` returns promptly, but Apple's
            // `SpeechTranscriber.results` AsyncSequence does NOT terminate
            // when no input was ever fed. Awaiting `drainTask.value` here would
            // block forever (rapid-fn-tap hang). Force-close our event
            // stream and cancel the drain task so finish() always returns.
            await session.analyzer.cancelAndFinishNow()
            session.eventContinuation.finish()
            session.drainTask.cancel()
        }

        Self.log.info("session finished (hadInput=\(session.hasReceivedBuffer)) locale=\(self.locale.identifier)")
    }
}

enum TranscriberError: Error {
    case alreadyRunning
}
