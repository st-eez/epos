import AVFoundation
import Foundation

/// Captures microphone audio via `AVAudioEngine` and emits PCM buffers in the format the
/// downstream `SpeechTranscriber` expects (obtained from `Transcriber.bestAudioFormat`).
/// Callbacks fire on the engine's audio thread; consumers must be thread-safe.
public final class AudioCapture {
    public var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    public var onAmplitude: ((Float) -> Void)?

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?

    public init() {}

    /// Begin capture. Converts the input node's native format to `targetFormat` via
    /// `AVAudioConverter` and emits converted buffers on `onBuffer`. RMS amplitude is
    /// computed off the pre-conversion buffer and reported via `onAmplitude`.
    public func start(targetFormat: AVAudioFormat) throws {
        // TODO: build fresh AVAudioEngine, install tap on inputNode, build AVAudioConverter
        // from inputNode.outputFormat(forBus: 0) to targetFormat; in the tap callback compute
        // RMS amplitude, convert the buffer, fire onBuffer/onAmplitude; engine.prepare()/start().
    }

    /// Tear down the engine fully so the next `start` builds a fresh one.
    public func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        converter = nil
    }
}
