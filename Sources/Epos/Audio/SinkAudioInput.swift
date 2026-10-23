@preconcurrency import AVFoundation
import Foundation

/// Keeps allocation, conversion and client callbacks off AVAudioSinkNode's render thread.
final class SinkAudioInput: @unchecked Sendable {
    let node: AVAudioSinkNode
    let ring: AudioInputRing
    private let minimumFrames: Int
    private let queue = DispatchQueue(label: "com.steez.Epos.audio-input", qos: .userInitiated)
    private let timer: DispatchSourceTimer
    private let onBuffer: (AVAudioPCMBuffer) throws -> Void
    private let onFinish: () throws -> Void
    private let onFailure: (SinkAudioInput, Error) -> Void
    private var stopped = false
    private var failure: Error?

    init?(
        format: AVAudioFormat,
        onBuffer: @escaping (AVAudioPCMBuffer) throws -> Void,
        onFinish: @escaping () throws -> Void,
        onFailure: @escaping (SinkAudioInput, Error) -> Void
    ) {
        guard let ring = AudioInputRing(format: format) else { return nil }
        self.ring = ring
        self.minimumFrames = max(1, Int(ceil(format.sampleRate / 100)))
        self.onBuffer = onBuffer
        self.onFinish = onFinish
        self.onFailure = onFailure
        self.node = AVAudioSinkNode { _, frames, input in
            ring.write(input, frames: frames)
            return noErr
        }
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(2), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.drain(flush: false) }
        timer.resume()
    }

    /// The engine must stop its producer before this final synchronous drain.
    @discardableResult
    func stop() -> Error? {
        queue.sync {
            guard !stopped else { return failure }
            timer.cancel()
            drain(flush: true)
            if failure == nil {
                do { try onFinish() }
                catch { reportFailure(error) }
            }
            stopped = true
            return failure
        }
    }

    private func drain(flush: Bool) {
        guard !stopped, failure == nil else { return }
        switch ring.failure {
        case .none:
            do {
                while let buffer = try ring.read(minimumFrames: flush ? 1 : minimumFrames,
                                             maximumFrames: max(4_096, minimumFrames)) {
                    try onBuffer(buffer)
                }
            } catch { reportFailure(error) }
        case .overflow:
            reportFailure(AudioCaptureError.inputBacklogOverflow)
        case .invalidBuffer:
            reportFailure(AudioCaptureError.invalidInputBuffer)
        }
    }

    private func reportFailure(_ error: Error) {
        guard failure == nil else { return }
        failure = error
        timer.cancel()
        onFailure(self, error)
    }
}
