import AVFoundation
import Foundation
@testable import Epos

/// Drives the coordinator's recognizer events by hand. Nothing here talks to
/// `SpeechAnalyzer`, so the paths a live recognizer cannot be provoked into —
/// a result stream that dies mid-hold, a release that beats the analyzer's
/// start — are reachable from `swift test`.
final class FakeTranscriber: SpeechTranscribing, @unchecked Sendable {
    /// Thrown from `start` instead of opening an event stream.
    var startError: (any Error)?

    private let lock = NSLock()
    private var continuation: AsyncStream<TranscriptEvent>.Continuation?
    private var startCount = 0
    private var acceptedBuffers = 0

    /// `start` runs off the main actor, so its bookkeeping is read under the lock.
    var didStart: Bool { lock.withLock { startCount > 0 } }
    var acceptedBufferCount: Int { lock.withLock { acceptedBuffers } }

    func bestAudioFormat() async -> AVAudioFormat? {
        AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)
    }

    func start(contextualStrings: [String]) async throws -> AsyncStream<TranscriptEvent> {
        if let startError {
            throw startError
        }
        let (stream, continuation) = AsyncStream<TranscriptEvent>.makeStream()
        lock.withLock {
            startCount += 1
            self.continuation = continuation
        }
        return stream
    }

    func accept(_ buffer: AVAudioPCMBuffer) {
        lock.withLock { acceptedBuffers += 1 }
    }

    /// The real `finish()` ends the event stream once the analyzer has drained.
    func finish() async {
        endStream()
    }

    func emit(_ event: TranscriptEvent) {
        lock.withLock { continuation }?.yield(event)
    }

    /// The recognizer's stream closing — what the coordinator's event loop exits on.
    func endStream() {
        let continuation = lock.withLock { () -> AsyncStream<TranscriptEvent>.Continuation? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.finish()
    }
}
