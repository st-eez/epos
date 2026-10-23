import AVFoundation
import XCTest
@testable import Epos

final class SinkAudioInputTests: XCTestCase {
    func testStopDeliversASubTenMillisecondTailExactlyOnce() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        var received: [Float] = []
        let input = try XCTUnwrap(SinkAudioInput(format: format, onBuffer: { buffer in
            received += Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        }, onFinish: {}, onFailure: { _, _ in XCTFail("valid audio must not fail") }))
        let tail = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 80))
        tail.frameLength = 80
        for index in 0..<80 { tail.floatChannelData![0][index] = Float(index) }
        input.ring.write(tail.audioBufferList, frames: 80)
        XCTAssertNil(input.stop())
        input.stop()
        XCTAssertEqual(received, (0..<80).map(Float.init))
    }

    func testMalformedInputReportsFailureOnceAndEmitsNoAudio() throws {
        let mono = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let stereo = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        var failures = 0
        let input = try XCTUnwrap(SinkAudioInput(format: mono, onBuffer: { _ in
            XCTFail("malformed input must not be delivered")
        }, onFinish: {}, onFailure: { _, error in
            if case AudioCaptureError.invalidInputBuffer = error { failures += 1 }
            else { XCTFail("unexpected error \(error)") }
        }))
        let bad = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 480))
        bad.frameLength = 480
        input.ring.write(bad.audioBufferList, frames: 480)
        XCTAssertNotNil(input.stop())
        XCTAssertNotNil(input.stop())
        XCTAssertEqual(failures, 1)
    }

    func testStopReportsConsumerFlushFailureOnce() throws {
        var failures = 0
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let input = try XCTUnwrap(SinkAudioInput(format: format, onBuffer: { _ in }, onFinish: {
            throw AudioCaptureError.conversionFailed(nil)
        }, onFailure: { _, _ in failures += 1 }))
        XCTAssertNotNil(input.stop())
        XCTAssertNotNil(input.stop())
        XCTAssertEqual(failures, 1)
    }

    func testConsumerFailureStopsDeliveryAndSkipsFlush() throws {
        var deliveries = 0
        var failures = 0
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let input = try XCTUnwrap(SinkAudioInput(format: format, onBuffer: { _ in
            deliveries += 1
            throw AudioCaptureError.conversionFailed(nil)
        }, onFinish: {
            XCTFail("a failed consumer must not finish successfully")
        }, onFailure: { _, _ in failures += 1 }))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_192))
        buffer.frameLength = 8_192
        input.ring.write(buffer.audioBufferList, frames: buffer.frameLength)
        XCTAssertNotNil(input.stop())
        XCTAssertNotNil(input.stop())
        XCTAssertEqual(deliveries, 1)
        XCTAssertEqual(failures, 1)
    }
}
