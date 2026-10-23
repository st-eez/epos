import AVFoundation
import XCTest
@testable import Epos

/// The mic → recognizer format conversion. Pure DSP, so it is testable without
/// touching the machine's input device.
///
/// This exists because of a failure that is invisible from every other angle:
/// with voice processing on, the input node hands back nine `DiscreteInOrder`
/// channels, and `AVAudioConverter`'s implicit downmix for that layout emits
/// digital silence. No error is raised, buffers keep flowing at the right frame
/// counts, and the only symptom is that every transcript comes back empty.
final class AudioCaptureConverterTests: XCTestCase {
    private let targetFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!

    /// The shape voice processing actually produces on this hardware: nine
    /// deinterleaved 48 kHz channels, `kAudioChannelLayoutTag_DiscreteInOrder | 9`.
    private func voiceProcessingInputFormat() -> AVAudioFormat? {
        guard let layout = AVAudioChannelLayout(
            layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 9
        ) else { return nil }
        return AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            interleaved: false,
            channelLayout: layout
        )
    }

    /// A tone at `amplitude` replicated across every channel, which is what voice
    /// processing does with its single processed mono result.
    private func makeBuffer(
        format: AVAudioFormat,
        frames: AVAudioFrameCount,
        amplitude: Float
    ) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let channels = Int(format.channelCount)
        for frame in 0..<Int(frames) {
            let value = amplitude * Float(sin(Double(frame) * 2 * .pi * 440 / format.sampleRate))
            for channel in 0..<channels {
                buffer.floatChannelData![channel][frame] = value
            }
        }
        return buffer
    }

    private func rms(of buffer: AVAudioPCMBuffer) -> Double {
        let samples = buffer.floatChannelData![0]
        var sum = 0.0
        for frame in 0..<Int(buffer.frameLength) {
            let value = Double(samples[frame])
            sum += value * value
        }
        return (sum / Double(buffer.frameLength)).squareRoot()
    }

    /// The regression: signal energy must survive the 9 → 1 collapse. A downmix
    /// that averages nine identical copies would also pass, but the implicit one
    /// zeroes the stream, which is what this pins.
    func testVoiceProcessingMultichannelInputKeepsItsSignal() throws {
        let inputFormat = try XCTUnwrap(voiceProcessingInputFormat())
        let converter = try XCTUnwrap(AudioCapture.makeConverter(from: inputFormat, to: targetFormat))
        let input = makeBuffer(format: inputFormat, frames: 4_800, amplitude: 0.5)

        let output = try AudioCapture.convert(input, with: converter)

        XCTAssertGreaterThan(output.frameLength, 0)
        // 0.5 amplitude sine → 0.354 RMS. The resampler's low-pass costs a few
        // percent; anything near zero means the downmix ate the signal.
        XCTAssertEqual(rms(of: output), 0.354, accuracy: 0.05)
    }

    /// Voice processing off: the hardware input is already mono and must pass
    /// through the same factory untouched.
    func testMonoInputIsUnchangedByTheChannelSelection() throws {
        let inputFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let converter = try XCTUnwrap(AudioCapture.makeConverter(from: inputFormat, to: targetFormat))
        let input = makeBuffer(format: inputFormat, frames: 4_800, amplitude: 0.5)

        let output = try AudioCapture.convert(input, with: converter)

        XCTAssertGreaterThan(output.frameLength, 0)
        XCTAssertEqual(rms(of: output), 0.354, accuracy: 0.05)
    }

    func testSmallInputBatchesPreserveResampledAudio() throws {
        for channels in [1, 9] {
            let format = try XCTUnwrap(channels == 1
                ? AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)
                : voiceProcessingInputFormat())
            let input = makeBuffer(format: format, frames: 48_000, amplitude: 0.5)
            func samples(batchSize: Int) throws -> [Float] {
                let converter = try XCTUnwrap(AudioCapture.makeConverter(from: format, to: targetFormat))
                var result: [Float] = []
                for offset in stride(from: 0, to: Int(input.frameLength), by: batchSize) {
                    let count = min(batchSize, Int(input.frameLength) - offset)
                    let batch = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(count))!
                    batch.frameLength = UInt32(count)
                    for channel in 0..<channels {
                        batch.floatChannelData![channel].update(
                            from: input.floatChannelData![channel].advanced(by: offset), count: count
                        )
                    }
                    let output = try AudioCapture.convert(batch, with: converter)
                    result.append(contentsOf: UnsafeBufferPointer(
                        start: output.floatChannelData![0], count: Int(output.frameLength)
                    ))
                }
                try AudioCapture.finishConversion(converter) { tail in
                    result.append(contentsOf: UnsafeBufferPointer(
                        start: tail.floatChannelData![0], count: Int(tail.frameLength)
                    ))
                }
                return result
            }
            let large = try samples(batchSize: 4_800)
            let small = try samples(batchSize: 512)
            XCTAssertEqual(small.count, large.count)
            XCTAssertGreaterThan(small.count, 15_900)
            for (actual, expected) in zip(small, large) {
                XCTAssertEqual(actual, expected, accuracy: 0.000_01)
            }
        }
    }

    func testShortReleaseFlushesEveryConvertedFrame() throws {
        let format = try XCTUnwrap(voiceProcessingInputFormat())
        for frames: AVAudioFrameCount in [80, 511, 512, 997] {
            let converter = try XCTUnwrap(AudioCapture.makeConverter(from: format, to: targetFormat))
            let input = makeBuffer(format: format, frames: frames, amplitude: 0.5)
            let first = try AudioCapture.convert(input, with: converter)
            var total = first.frameLength
            try AudioCapture.finishConversion(converter) { total += $0.frameLength }
            let expected = UInt32(ceil(Double(frames) / 3))
            let padding = UInt32(ceil(Double(converter.primeInfo.leadingFrames + converter.primeInfo.trailingFrames) / 3))
            XCTAssertGreaterThanOrEqual(total, expected)
            XCTAssertLessThanOrEqual(total, expected + padding)
            XCTAssertGreaterThan(total, first.frameLength)
            var repeatedFlushFrames: UInt32 = 0
            try AudioCapture.finishConversion(converter) { repeatedFlushFrames += $0.frameLength }
            XCTAssertEqual(repeatedFlushFrames, 0)
        }
    }
}
