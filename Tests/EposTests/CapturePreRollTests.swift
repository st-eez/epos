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
