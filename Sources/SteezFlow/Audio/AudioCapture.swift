@preconcurrency import AVFoundation
import Foundation
import OSLog

/// Captures microphone audio via `AVAudioEngine` and emits PCM buffers in the format the
/// downstream `SpeechTranscriber` expects (obtained from `Transcriber.bestAudioFormat`).
/// Callbacks fire on the engine's audio thread; consumers must be thread-safe.
public final class AudioCapture {
    public var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    public var onAmplitude: ((Float) -> Void)?

    private static let log = Logger(subsystem: "com.steez.SteezFlow", category: "audio")

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var audioFile: AVAudioFile?
    private var tapCount = 0
    private var emitCount = 0

    public init() {}

    /// Per-recording .wav of the converted (16 kHz mono Float32) stream — exactly
    /// what the analyzer sees. Lives in Caches; dogfooding + future eval material.
    private static func openRecordingFile(format: AVAudioFormat) -> AVAudioFile? {
        guard let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = cachesDir.appendingPathComponent("SteezFlow/recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        let url = dir.appendingPathComponent("\(formatter.string(from: Date())).wav")
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            log.info("recording to \(url.lastPathComponent, privacy: .public)")
            return file
        } catch {
            log.error("audio file open failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Begin capture. Converts the input node's native format to `targetFormat` via
    /// `AVAudioConverter` and emits converted buffers on `onBuffer`. RMS amplitude is
    /// computed off the pre-conversion buffer and reported via `onAmplitude`.
    public func start(targetFormat: AVAudioFormat) throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0 else {
            throw AudioCaptureError.zeroSampleRate
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioCaptureError.converterUnavailable
        }
        // Per Apple docs and swift-scribe pattern: skip filter priming so converter state
        // persists cleanly across per-buffer calls; first samples may be lower quality.
        converter.primeMethod = .none

        let rateRatio = targetFormat.sampleRate / inputFormat.sampleRate

        tapCount = 0
        emitCount = 0
        audioFile = Self.openRecordingFile(format: targetFormat)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.tapCount += 1

            if let amplitude = Self.rms(of: buffer) {
                self.onAmplitude?(amplitude)
            }

            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * rateRatio))
            guard capacity > 0,
                  let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
                return
            }

            // Box holds the input buffer for a single hand-off; nil-out after first use.
            // Reference type avoids `var` mutation in the @Sendable converter input block.
            let pending = InputBox(buffer)
            var convError: NSError?
            // Return `.noDataNow` (not `.endOfStream`) so the converter retains its SRC
            // filter state across calls instead of flushing/resetting every buffer.
            let status = converter.convert(to: output, error: &convError) { _, inputStatus in
                guard let next = pending.take() else {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                inputStatus.pointee = .haveData
                return next
            }

            if status == .error {
                if let convError {
                    Self.log.error("convert failed: \(String(describing: convError), privacy: .public)")
                }
                return
            }

            self.emitCount += 1
            if let file = self.audioFile {
                try? file.write(from: output)
            }
            self.onBuffer?(output)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            Self.log.error("engine start failed: \(String(describing: error), privacy: .public)")
            throw AudioCaptureError.engineFailed(error)
        }

        self.engine = engine
        self.converter = converter
        Self.log.info("capture started: input \(inputFormat.sampleRate, privacy: .public)Hz/\(inputFormat.channelCount, privacy: .public)ch -> target \(targetFormat.sampleRate, privacy: .public)Hz/\(targetFormat.channelCount, privacy: .public)ch commonFormat=\(targetFormat.commonFormat.rawValue, privacy: .public)")
    }

    /// Tear down the engine fully so the next `start` builds a fresh one.
    public func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        converter = nil
        // Nil after removeTap so an in-flight tap can't write to a closed file.
        audioFile = nil
        Self.log.info("capture stopped (taps=\(self.tapCount, privacy: .public) emits=\(self.emitCount, privacy: .public))")
    }

    /// RMS amplitude across the first channel, clamped to 0...1. Float32 buffers only.
    private static func rms(of buffer: AVAudioPCMBuffer) -> Float? {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else {
            return nil
        }
        let samples = channels[0]
        let count = Int(buffer.frameLength)
        var sumSquares: Float = 0
        for index in 0..<count {
            let sample = samples[index]
            sumSquares += sample * sample
        }
        let mean = sumSquares / Float(count)
        let rms = mean.squareRoot()
        return min(max(rms, 0), 1)
    }
}

enum AudioCaptureError: Error {
    case zeroSampleRate
    case converterUnavailable
    case engineFailed(Error)
}

/// Single-shot holder for the converter's input buffer. The converter's
/// `@Sendable` input block runs synchronously on the calling thread but Swift 6
/// cannot prove that, so we hand the buffer through a reference type.
private final class InputBox: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}
