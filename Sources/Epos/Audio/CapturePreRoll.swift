import AVFoundation
import Foundation

/// Holds the microphone buffers captured between fn press and the analyzer being
/// ready to receive them, then hands them over in capture order.
///
/// The mic opens at fn press so the start cue means "mic is hot", which is
/// necessarily before `SpeechAnalyzer` can be started — that is an async framework
/// call, and the AX baseline capture runs in the same window. Buffers arriving then
/// are the opening of the utterance, so they queue here instead of being dropped.
/// `attach(_:)` drains the queue and the relay forwards straight through for the
/// rest of the recording.
///
/// The queue is bounded in practice by how long `Transcriber.start` takes; a
/// recording whose analyzer never starts is torn down (and this relay released)
/// on the setup-failure path.
///
/// `accept(_:)` runs on the realtime audio thread and `attach(_:)` on the main
/// actor: the lock is what stops the hand-over from interleaving a live buffer
/// ahead of a queued one.
final class CapturePreRoll {
    private let lock = NSLock()
    private var pending: [AVAudioPCMBuffer] = []
    private var destination: ((AVAudioPCMBuffer) -> Void)?

    /// Audio thread. Forwards once a destination exists, queues until then.
    func accept(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            if let destination {
                destination(buffer)
            } else {
                pending.append(buffer)
            }
        }
    }

    /// Install the live sink and flush everything captured before it existed.
    /// Returns the number of pre-roll buffers handed over — the measurable width of
    /// the press → analyzer-ready window.
    @discardableResult
    func attach(_ destination: @escaping (AVAudioPCMBuffer) -> Void) -> Int {
        lock.withLock {
            let queued = pending
            pending = []
            self.destination = destination
            for buffer in queued {
                destination(buffer)
            }
            return queued.count
        }
    }
}
