import AVFoundation
import XCTest
@testable import Epos

final class AudioInputRingTests: XCTestCase {
    private func format(channels: AVAudioChannelCount = 1, interleaved: Bool = false) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                      channels: channels, interleaved: interleaved)!
    }

    private func buffer(_ values: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer {
        let frames = values.count / Int(format.channelCount)
        let result = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(frames))!
        result.frameLength = UInt32(frames)
        let channels = Int(format.channelCount)
        for frame in 0..<frames {
            for channel in 0..<channels {
                if format.isInterleaved {
                    result.floatChannelData![0][frame * channels + channel] = values[frame * channels + channel]
                } else {
                    result.floatChannelData![channel][frame] = values[frame * channels + channel]
                }
            }
        }
        return result
    }

    private func values(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let channels = Int(buffer.format.channelCount)
        return (0..<Int(buffer.frameLength)).flatMap { frame in
            (0..<channels).map { channel in
                buffer.format.isInterleaved
                    ? buffer.floatChannelData![0][frame * channels + channel]
                    : buffer.floatChannelData![channel][frame]
            }
        }
    }

    func testWrapPreservesFrameAndChannelOrderForBothLayouts() throws {
        for interleaved in [false, true] {
            let format = format(channels: 2, interleaved: interleaved)
            let ring = try XCTUnwrap(AudioInputRing(format: format, capacity: 8))
            let first = buffer((0..<12).map(Float.init), format: format)
            ring.write(first.audioBufferList, frames: first.frameLength)
            XCTAssertEqual(values(try XCTUnwrap(ring.read(maximumFrames: 4))), (0..<8).map(Float.init))
            let second = buffer((12..<24).map(Float.init), format: format)
            ring.write(second.audioBufferList, frames: second.frameLength)
            XCTAssertEqual(values(try XCTUnwrap(ring.read())), (8..<24).map(Float.init))
            XCTAssertNil(try ring.read())
            XCTAssertEqual(ring.failure, .none)
        }
    }

    func testCopiesSurviveSourceReuseAndRingOverwrite() throws {
        let format = format()
        let ring = try XCTUnwrap(AudioInputRing(format: format, capacity: 4))
        let source = buffer([1, 2, 3, 4], format: format)
        ring.write(source.audioBufferList, frames: 4)
        source.floatChannelData![0][0] = 99
        let retained = try XCTUnwrap(ring.read())
        ring.write(source.audioBufferList, frames: 4)
        XCTAssertEqual(values(try XCTUnwrap(ring.read())), [99, 2, 3, 4])
        XCTAssertEqual(values(retained), [1, 2, 3, 4])
    }

    func testOverflowFailsWithoutOverwritingQueuedSpeech() throws {
        let format = format()
        let ring = try XCTUnwrap(AudioInputRing(format: format, capacity: 4))
        let source = buffer([1, 2, 3, 4], format: format)
        ring.write(source.audioBufferList, frames: 4)
        ring.write(source.audioBufferList, frames: 1)
        XCTAssertEqual(ring.failure, .overflow)
        XCTAssertEqual(values(try XCTUnwrap(ring.read())), [1, 2, 3, 4])
        ring.write(source.audioBufferList, frames: 4)
        XCTAssertNil(try ring.read(), "a failed stream must not resume after losing audio")
    }

    func testInvalidBufferDoesNotPublishPartialChannels() throws {
        let stereo = format(channels: 2)
        let ring = try XCTUnwrap(AudioInputRing(format: stereo, capacity: 4))
        let source = buffer([1, 2, 3, 4], format: stereo)
        let raw = source.mutableAudioBufferList
        let buffers = UnsafeMutableAudioBufferListPointer(raw)
        buffers[1].mDataByteSize = 0
        ring.write(UnsafePointer(raw), frames: 2)
        XCTAssertEqual(ring.failure, .invalidBuffer)
        XCTAssertNil(try ring.read())
    }

    func testFinalShortBufferCanBeDrainedWithoutPadding() throws {
        let format = format()
        let ring = try XCTUnwrap(AudioInputRing(format: format, capacity: 8))
        let source = buffer([1, 2, 3], format: format)
        ring.write(source.audioBufferList, frames: 3)
        XCTAssertNil(try ring.read(minimumFrames: 4))
        XCTAssertEqual(values(try XCTUnwrap(ring.read())), [1, 2, 3])
        XCTAssertNil(try ring.read())
    }

    func testConcurrentProducerConsumerPreservesEveryFrame() throws {
        let format = format()
        let ring = try XCTUnwrap(AudioInputRing(format: format, capacity: 131_072))
        let group = DispatchGroup()
        let frameCount = 100_000
        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 100)!
        input.frameLength = 100
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            for first in stride(from: 0, to: frameCount, by: 100) {
                for offset in 0..<100 { input.floatChannelData![0][offset] = Float(first + offset) }
                ring.write(input.audioBufferList, frames: 100)
            }
            group.leave()
        }
        var received: [Float] = []
        let deadline = ContinuousClock.now + .seconds(3)
        while received.count < frameCount, ContinuousClock.now < deadline {
            if let output = try ring.read(maximumFrames: 173) { received += values(output) }
            else { Thread.sleep(forTimeInterval: 0.0001) }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 1), .success)
        withExtendedLifetime(input) {}
        XCTAssertEqual(ring.failure, .none)
        XCTAssertEqual(received, (0..<frameCount).map(Float.init))
    }
}
