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

    private func convert(_ input: AVAudioPCMBuffer, with converter: AVAudioConverter) -> AVAudioPCMBuffer {
        let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: input.frameLength + 1)!
        var consumed = false
        var error: NSError?
        _ = converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return input
        }
        XCTAssertNil(error)
        return output
    }

    /// The regression: signal energy must survive the 9 → 1 collapse. A downmix
    /// that averages nine identical copies would also pass, but the implicit one
    /// zeroes the stream, which is what this pins.
    func testVoiceProcessingMultichannelInputKeepsItsSignal() throws {
        let inputFormat = try XCTUnwrap(voiceProcessingInputFormat())
        let converter = try XCTUnwrap(AudioCapture.makeConverter(from: inputFormat, to: targetFormat))
        let input = makeBuffer(format: inputFormat, frames: 4_800, amplitude: 0.5)

        let output = convert(input, with: converter)

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

        let output = convert(input, with: converter)

        XCTAssertGreaterThan(output.frameLength, 0)
        XCTAssertEqual(rms(of: output), 0.354, accuracy: 0.05)
    }
}
