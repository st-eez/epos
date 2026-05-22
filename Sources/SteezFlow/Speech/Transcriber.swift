import AVFoundation
import Foundation
import Speech

/// Streaming result emitted by `Transcriber` while a recording is in progress.
public enum TranscriptEvent: Equatable {
    case partial(String)
    case final(String)
    case failed(String)
}

/// Wraps `SpeechAnalyzer` + a `SpeechTranscriber` module for one recording session.
/// Build a fresh instance per recording; do not reuse across sessions.
public final class Transcriber {
    public let locale: Locale

    public init(locale: Locale = Locale(identifier: "en-US")) {
        self.locale = locale
    }

    /// Begin a new transcription session. Returns an async stream of partial + final results.
    /// Caller feeds PCM buffers via `accept(_:)` and ends the session with `finish()`.
    public func start() -> AsyncStream<TranscriptEvent> {
        AsyncStream { continuation in
            // TODO: build SpeechAnalyzer + SpeechTranscriber(locale:, options: [.partialResults])
            // TODO: subscribe to results stream, map -> TranscriptEvent, yield to continuation
            continuation.finish()
        }
    }

    /// Feed a captured audio buffer into the active session.
    public func accept(_ buffer: AVAudioPCMBuffer) {
        // TODO: convert to AnalyzerInput, send to SpeechAnalyzer input sequence
    }

    /// Signal end of input; the session will emit a final result then complete the stream.
    public func finish() async {
        // TODO: close analyzer input sequence, await final result
    }
}
