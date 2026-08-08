import AVFoundation
import XCTest
@testable import Epos

/// The mic opens at fn press, before the analyzer can accept anything. What the
/// tap captures in that window is the opening of the utterance, so the relay has
/// to hand it over intact and in order — dropping it would reproduce the loss the
/// early mic start exists to fix.
final class CapturePreRollTests: XCTestCase {
    private static let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!

    private final class Sink {
        var frames: [AVAudioFrameCount] = []
    }

    /// Frame length is the only thing this test needs to tell buffers apart.
    private func makeBuffer(frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: frames)!
        buffer.frameLength = frames
        return buffer
    }

    func testBuffersCapturedBeforeTheAnalyzerAreHandedOverInOrder() {
        let preRoll = CapturePreRoll()
        let sink = Sink()

        preRoll.accept(makeBuffer(frames: 1))
        preRoll.accept(makeBuffer(frames: 2))
        preRoll.accept(makeBuffer(frames: 3))
        let handedOver = preRoll.attach { sink.frames.append($0.frameLength) }

        XCTAssertEqual(handedOver, 3)
        XCTAssertEqual(sink.frames, [1, 2, 3])
    }

    func testBuffersAfterAttachFlowStraightThrough() {
        let preRoll = CapturePreRoll()
        let sink = Sink()
        preRoll.accept(makeBuffer(frames: 1))
        preRoll.attach { sink.frames.append($0.frameLength) }

        preRoll.accept(makeBuffer(frames: 2))

        XCTAssertEqual(sink.frames, [1, 2])
    }

    /// A start that never settles must not retain mic buffers forever: past the
    /// cap the queue keeps the newest audio, so what reaches the analyzer runs
    /// unbroken into the live feed instead of splicing a hole into the middle.
    func testQueueIsCappedAndKeepsTheNewestAudio() {
        let preRoll = CapturePreRoll()
        let sink = Sink()
        let secondOfAudio = AVAudioFrameCount(Self.format.sampleRate)
        let halfSecondOfAudio = secondOfAudio / 2
        for _ in 0 ..< 9 {
            preRoll.accept(makeBuffer(frames: secondOfAudio))
        }
        // A last buffer of a different length, so the hand-over shows which end of
        // the 9.5s of audio survived.
        preRoll.accept(makeBuffer(frames: halfSecondOfAudio))

        let handedOver = preRoll.attach { sink.frames.append($0.frameLength) }

        XCTAssertEqual(handedOver, 3)
        XCTAssertEqual(sink.frames, [secondOfAudio, secondOfAudio, halfSecondOfAudio])
    }

    /// The cap is on retained audio, not buffer count: many short buffers below
    /// the cap are all still the opening of the utterance and must survive.
    func testShortBuffersUnderTheCapAreAllKept() {
        let preRoll = CapturePreRoll()
        let sink = Sink()
        // 100 × 10ms = 1s, well under the cap.
        for _ in 0 ..< 100 {
            preRoll.accept(makeBuffer(frames: AVAudioFrameCount(Self.format.sampleRate / 100)))
        }

        let handedOver = preRoll.attach { sink.frames.append($0.frameLength) }

        XCTAssertEqual(handedOver, 100)
    }

    /// Eviction is bookkeeping too: a capped queue that is drained must not leave
    /// the next pre-roll thinking it is already full.
    func testCapAccountingResetsAfterAttach() {
        let preRoll = CapturePreRoll()
        let sink = Sink()
        let secondOfAudio = AVAudioFrameCount(Self.format.sampleRate)
        for _ in 0 ..< 10 {
            preRoll.accept(makeBuffer(frames: secondOfAudio))
        }
        preRoll.attach { sink.frames.append($0.frameLength) }
        sink.frames = []

        preRoll.accept(makeBuffer(frames: secondOfAudio))

        XCTAssertEqual(sink.frames, [secondOfAudio])
    }

    /// The queue is handed over exactly once; a later live buffer must not replay
    /// the pre-roll behind it.
    func testPreRollIsNotReplayed() {
        let preRoll = CapturePreRoll()
        let sink = Sink()
        preRoll.accept(makeBuffer(frames: 1))
        preRoll.attach { sink.frames.append($0.frameLength) }
        sink.frames = []

        preRoll.accept(makeBuffer(frames: 2))

        XCTAssertEqual(sink.frames, [2])
    }
}
