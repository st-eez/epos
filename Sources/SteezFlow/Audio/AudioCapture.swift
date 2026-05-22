import AVFoundation
import Foundation

/// Captures microphone audio via AVAudioEngine and exposes 16 kHz mono Float32 buffers.
public final class AudioCapture {
    public var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    public var onAmplitude: ((Float) -> Void)?

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?

    public init() {}

    public func start() throws {
        // TODO: install tap on engine.inputNode, build AVAudioConverter -> 16k mono Float32,
        // emit converted buffers via onBuffer, compute RMS amplitude via onAmplitude.
    }

    public func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
