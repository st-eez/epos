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
/// Normally that window is well under a second, but the analyzer's startup bound
/// exceeds this queue's budget. A stalled start can feed it at ~192 KB/s until
/// the startup deadline. The queue is capped at `capSeconds` of audio and evicts
/// the OLDEST buffers to stay under it.
///
/// Dropping oldest rather than newest is a transcript-correctness choice. Both
/// policies lose audio once the cap is hit; the difference is where the seam
/// lands. Keeping the oldest would hand the analyzer the opening of the utterance
/// spliced directly onto live audio from seconds later — a stream with a hole in
/// the middle, which the recognizer reads as continuous speech and turns into a
/// fluent sentence whose middle words were never said. Keeping the newest instead
/// yields audio that runs unbroken up to `attach(_:)` and straight into the live
/// feed: the result is visibly missing its beginning, which is a truncation the
/// user can see, not a plausible-looking fabrication. Epos prefers the obviously
/// short write over the silently wrong one.
///
/// `accept(_:)` runs on the realtime audio thread and `attach(_:)` on the main
/// actor: the lock is what stops the hand-over from interleaving a live buffer
/// ahead of a queued one.
final class CapturePreRoll {
    /// Generous next to the sub-second window this bridges; reaching it means the
    /// start path is wedged, not slow.
    static let capSeconds: Double = 3

    private static let log = EposLogger(category: "audio")

    private let lock = NSLock()
    private var pending: [AVAudioPCMBuffer] = []
    private var pendingSeconds: Double = 0
    private var didReportCap = false
    private var accepting = true
    private var destination: ((AVAudioPCMBuffer) -> Void)?

    /// Audio thread. Forwards once a destination exists, queues until then.
    func accept(_ buffer: AVAudioPCMBuffer) {
        let hitCap: Bool = lock.withLock {
            guard accepting else { return false }
            if let destination {
                destination(buffer)
                return false
            }
            pending.append(buffer)
            pendingSeconds += Self.seconds(of: buffer)
            guard pendingSeconds > Self.capSeconds else { return false }
            while pendingSeconds > Self.capSeconds, let oldest = pending.first {
                pending.removeFirst()
                pendingSeconds -= Self.seconds(of: oldest)
            }
            defer { didReportCap = true }
            return !didReportCap
        }
        // Outside the lock: this is the audio thread, and the report is once per
        // relay, so it never lengthens the critical section a live buffer waits on.
        if hitCap {
            Self.log.error(
                "capture pre-roll hit its \(Self.capSeconds)s cap; the analyzer start has not settled"
            )
        }
    }

    /// End this hold's tap delivery while retaining startup audio for the handoff.
    /// A captured callback from an older tap cannot feed a later analyzer session.
    func stopAccepting() {
        lock.withLock { accepting = false }
    }

    private static func seconds(of buffer: AVAudioPCMBuffer) -> Double {
        Double(buffer.frameLength) / buffer.format.sampleRate
    }

    /// Install the live sink and flush everything captured before it existed.
    /// Returns the number of pre-roll buffers handed over — the measurable width of
    /// the press → analyzer-ready window.
    @discardableResult
    func attach(_ destination: @escaping (AVAudioPCMBuffer) -> Void) -> Int {
        lock.withLock {
            let queued = pending
            pending = []
            pendingSeconds = 0
            self.destination = destination
            for buffer in queued {
                destination(buffer)
            }
            return queued.count
        }
    }
}
