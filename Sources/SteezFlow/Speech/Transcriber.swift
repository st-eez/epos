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
public final class Transcriber: @unchecked Sendable {
    public let locale: Locale

    public init(locale: Locale = Locale(identifier: "en-US")) {
        self.locale = locale
    }

    /// Best PCM format the underlying `SpeechTranscriber` accepts for this locale.
    /// Call once at bootstrap; the coordinator hands the result to `AudioCapture.start`.
    /// Returns nil if the locale's asset isn't installed/reserved yet.
    public func bestAudioFormat() async -> AVAudioFormat? {
        // TODO: build a throwaway SpeechTranscriber(locale:, preset: .progressiveTranscription),
        // ask SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:) for the format.
        nil
    }

    /// Begin a new transcription session. Returns an async stream of partial + final results.
    /// Caller feeds PCM buffers via `accept(_:)` and ends the session with `finish()`.
    public func start() async throws -> AsyncStream<TranscriptEvent> {
        // TODO: build fresh SpeechAnalyzer + SpeechTranscriber(locale:, preset: .progressiveTranscription,
        // reportingOptions: [.volatileResults]); wire an AsyncStream<AnalyzerInput> as the input
        // sequence; spawn a Task draining `transcriber.results`, mapping each Result -> .partial
        // (when !isFinal) or .final (when isFinal) into the returned event stream.
        AsyncStream { $0.finish() }
    }

    /// Feed a captured audio buffer into the active session. Thread-safe.
    public func accept(_ buffer: AVAudioPCMBuffer) {
        // TODO: wrap in AnalyzerInput(buffer:), yield to the active input continuation.
    }

    /// Signal end of input; the session will emit a final result then complete the stream.
    public func finish() async {
        // TODO: finish the input continuation, call analyzer.finalizeAndFinishThroughEndOfInput(),
        // then complete the event stream.
    }
}
