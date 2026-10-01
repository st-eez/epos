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
    /// Hold startup until the test explicitly releases it.
    var holdStart = false
    /// Recognition produced while finishing captured audio, if any reached it.
    var finalTranscriptOnFinish: String?

    private let lock = NSLock()
    private var continuation: AsyncStream<TranscriptEvent>.Continuation?
    private var startCount = 0
    private var acceptedBuffers = 0
    private var pendingStart: CheckedContinuation<Void, Never>?
    private var finishCalls = 0
    private var firstFinishBufferCount: Int?
    private var format: AVAudioFormat? = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)

    /// `start` runs off the main actor, so its bookkeeping is read under the lock.
    var didStart: Bool { lock.withLock { startCount > 0 } }
    var acceptedBufferCount: Int { lock.withLock { acceptedBuffers } }
    var isStartWaiting: Bool { lock.withLock { pendingStart != nil } }
    var finishCallCount: Int { lock.withLock { finishCalls } }
    var buffersAtFirstFinish: Int? { lock.withLock { firstFinishBufferCount } }

    /// What `bestAudioFormat()` resolves. Settable so a readiness re-check can be
    /// given a pipeline that resolves no format until the speech model lands.
    var audioFormat: AVAudioFormat? {
        get { lock.withLock { format } }
        set { lock.withLock { format = newValue } }
    }

    func bestAudioFormat() async -> AVAudioFormat? {
        audioFormat
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
        if holdStart {
            await withCheckedContinuation { continuation in
                lock.withLock { pendingStart = continuation }
            }
        }
        return stream
    }

    func completeStart() {
        let pending = lock.withLock {
            defer { pendingStart = nil }
            return pendingStart
        }
        pending?.resume()
    }

    func accept(_ buffer: AVAudioPCMBuffer) {
        lock.withLock { acceptedBuffers += 1 }
    }

    /// The real `finish()` ends the event stream once the analyzer has drained.
    func finish() async {
        let hasAudio = lock.withLock {
            finishCalls += 1
            if firstFinishBufferCount == nil { firstFinishBufferCount = acceptedBuffers }
            return acceptedBuffers > 0
        }
        if hasAudio, let finalTranscriptOnFinish {
            emit(.final(finalTranscriptOnFinish))
        }
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
