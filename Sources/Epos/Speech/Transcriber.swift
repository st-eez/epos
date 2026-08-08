import AVFoundation
import Foundation
import Speech

/// Streaming result emitted by `Transcriber` while a recording is in progress.
public enum TranscriptEvent: Equatable, Sendable {
    case partial(String)
    case final(String)
    case failed(String)
}

/// The recognizer seam `AppCoordinator` drives. `Transcriber` is the only
/// production conformance; the protocol exists because the recording state
/// machine's failure paths — a result stream that dies mid-hold, a release that
/// beats the analyzer's start — cannot be provoked on a live `SpeechAnalyzer`.
public protocol SpeechTranscribing: Sendable {
    func bestAudioFormat() async -> AVAudioFormat?
    func start(contextualStrings: [String]) async throws -> AsyncStream<TranscriptEvent>
    func accept(_ buffer: AVAudioPCMBuffer)
    func finish() async
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
public final class Transcriber: SpeechTranscribing, @unchecked Sendable {
    public let locale: Locale

    static let speechPreset = SpeechTranscriber.Preset(
        transcriptionOptions: [],
        reportingOptions: [.volatileResults, .fastResults],
        attributeOptions: [.transcriptionConfidence]
    )

    private static let log = EposLogger(category: "transcriber")

    /// Wall-clock bound on the with-input finalize + drain sequence in `finish()`. Raw
    /// finalize completes well under 2s across all observed real sessions; 10s is a
    /// generous escape hatch for an Apple-framework hang, not a tuning knob.
    static let finishTimeout: Duration = .seconds(10)

    /// Bound on how many un-analyzed audio buffers the input stream may hold.
    /// `AudioCapture` taps 4096 frames at 48 kHz and converts each one, so a buffer is
    /// ~85 ms of audio however it is resampled: 512 queued buffers is ~44 s the analyzer
    /// has not consumed — far past any real push-to-talk hold plus the pre-roll burst.
    /// Under the default `.unlimited` policy an analyzer that stopped draining retained
    /// every buffer of the recording forever. Reaching this bound therefore means the
    /// analyzer is wedged, not that the user talked a long time, and the session is
    /// failed rather than grown without limit.
    static let maxQueuedInputBuffers = 512

    private let lock = NSLock()
    private var session: Session?

    /// All per-recording state, installed and torn down as a unit under `lock`. Grouping
    /// it means `finish()` extracts a single value instead of a six-field tuple, and the
    /// install/teardown can't drift field-by-field. Internal so `closeSession` can be
    /// driven with a start that never settles, which no live analyzer can be made to do.
    struct Session {
        let analyzer: SpeechAnalyzer
        let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
        let eventContinuation: AsyncStream<TranscriptEvent>.Continuation
        let drainTask: Task<Void, Never>
        let startTask: Task<Void, Error>
        var hasReceivedBuffer: Bool
        /// Latches once the input bound is hit so the failure is reported exactly
        /// once, not on every buffer the wedged analyzer refuses.
        var didOverflowInput: Bool = false
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

        let (inputStream, inputCont) = Self.makeInputStream()
        // The event stream stays unbounded on purpose: it carries small strings at
        // roughly one per second for the length of one hold, and its only consumer
        // (`AppCoordinator.runSession`) drains it in a `for await`. There is no
        // volume here to bound.
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
        // A finish() racing the await above nils the session and closes the event
        // continuation; returning the stream then hands the caller a dead, already-finished
        // stream with no error. Re-check that the installed session is still ours.
        let stillCurrent = lock.withLock { self.session?.analyzer === analyzer }
        guard stillCurrent else {
            throw TranscriberError.tornDownDuringStart
        }
        return eventStream
    }

    /// The audio input stream, bounded at `maxQueuedInputBuffers`. `.bufferingOldest`
    /// keeps the contiguous opening of the utterance and reports the buffer it refused
    /// as `.dropped`, which is what `accept(_:)` turns into an honest session failure.
    /// Internal so a test can pin the bound without a live analyzer.
    static func makeInputStream() -> (AsyncStream<AnalyzerInput>, AsyncStream<AnalyzerInput>.Continuation) {
        AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(maxQueuedInputBuffers))
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

    /// Feed a captured audio buffer into the active session. Thread-safe.
    /// A buffer refused by the bounded input stream means the analyzer stopped
    /// draining; that fails the session instead of silently dropping audio.
    public func accept(_ buffer: AVAudioPCMBuffer) {
        let overflowedSession = lock.withLock { () -> Session? in
            guard var current = session else { return nil }
            current.hasReceivedBuffer = true
            let yielded = current.inputContinuation.yield(AnalyzerInput(buffer: buffer))
            var overflowed = false
            if case .dropped = yielded, !current.didOverflowInput {
                current.didOverflowInput = true
                overflowed = true
            }
            session = current
            return overflowed ? current : nil
        }
        guard let overflowedSession else { return }
        Self.reportInputOverflow(overflowedSession)
    }

    /// The analyzer stopped consuming audio. Close the input so nothing further is
    /// retained and report a recognizer failure on the event stream — the same signal
    /// the coordinator already handles for a results stream that dies mid-hold, so the
    /// recording ends as `.recognizerFailed` instead of a clean but truncated finalize.
    /// Teardown itself stays with the coordinator's normal `finish()`.
    /// Static and internal so a test can drive it with a constructed session.
    static func reportInputOverflow(_ session: Session) {
        let message = "audio input backlog exceeded \(maxQueuedInputBuffers) buffers; analyzer stopped draining"
        log.error("\(message)")
        session.inputContinuation.finish()
        session.eventContinuation.yield(.failed(message))
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
        await Self.closeSession(session, timeout: Self.finishTimeout)
        Self.log.info("session finished (hadInput=\(session.hasReceivedBuffer)) locale=\(self.locale.identifier)")
    }

    /// Tear one extracted session down within `timeout`, whatever hangs.
    ///
    /// EVERY framework await lives inside the race, not just the finalize: the
    /// settle-wait on `analyzer.setContext` / `analyzer.start(inputSequence:)` and
    /// `cancelAndFinishNow()` can each park without throwing, exactly as
    /// `finalizeAndFinishThroughEndOfInput()` can. Any one of them outside the bound
    /// wedges the caller forever — the event stream never closes, the coordinator
    /// never leaves `.finalizing`, and nothing watches the transcription task, so the
    /// app is dead until quit. `finish()` must ALWAYS return within the bound.
    ///
    /// Static and internal so tests can drive the timeout path with a start task that
    /// never settles.
    static func closeSession(_ session: Session, timeout: Duration) async {
        let completed = await Self.completed(within: timeout) {
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
                    session.eventContinuation.yield(.failed(message))
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
        }
        guard !completed else { return }

        let message = "transcriber finish timed out after \(timeout)"
        Self.log.error("\(message); forcing session closed")
        // Session state was already extracted and nilled by the caller, so the next
        // start() is unaffected. Cancel the start in case it is somewhere
        // cancellable, force-close both continuations so the caller's event loop
        // ends, and report the hang as a recognizer failure — the recording's
        // outcome must not read as a clean finalize. The analyzer is cancelled
        // without awaiting it: one hung framework call can hang the next.
        session.startTask.cancel()
        session.inputContinuation.finish()
        session.eventContinuation.yield(.failed(message))
        session.eventContinuation.finish()
        session.drainTask.cancel()
        Task { await session.analyzer.cancelAndFinishNow() }
    }

    /// Race `operation` against a wall-clock timeout. Returns true if it completed,
    /// false on timeout. Deliberately uses unstructured tasks: a task group would await
    /// all children before returning, which re-introduces the hang this exists to escape.
    /// On timeout the operation task is cancelled but may stay suspended inside
    /// non-cancellable framework code; the suspended continuation is the unavoidable
    /// residue of an external hang and must not block the caller.
    static func completed(within timeout: Duration, _ operation: @escaping @Sendable () async -> Void) async -> Bool {
        let (raceStream, raceCont) = AsyncStream<Bool>.makeStream()
        let work = Task {
            await operation()
            raceCont.yield(true)
        }
        let timer = Task {
            try? await Task.sleep(for: timeout)
            raceCont.yield(false)
        }
        var iterator = raceStream.makeAsyncIterator()
        let result = await iterator.next() ?? false
        work.cancel()
        timer.cancel()
        return result
    }
}

enum TranscriberError: Error {
    case alreadyRunning
    /// A concurrent `finish()` tore the session down while `start()` was awaiting
    /// `analyzer.start`; the event stream is already closed and must not be returned.
    case tornDownDuringStart
}
