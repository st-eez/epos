@preconcurrency import AVFoundation
import Foundation

/// The microphone the coordinator opens at fn press. `AudioCapture` is the only
/// production implementation; tests substitute a fake, because the coordinator now
/// opens the mic synchronously inside `startRecording` and `swift test` must not
/// touch the machine's real input device.
public protocol MicrophoneCapture: AnyObject {
    /// Converted buffer in the target format. Fires on the engine's audio thread.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)? { get set }
    /// Pre-conversion buffer in the mic's native format. Fires on the audio thread.
    var onRawBuffer: ((AVAudioPCMBuffer) -> Void)? { get set }
    var onAmplitude: ((Float) -> Void)? { get set }
    /// An in-flight capture died and could not be recovered. Delivered on the main
    /// actor so the coordinator can end the recording instead of leaving the glow
    /// advertising a mic that stopped producing buffers.
    var onCaptureFailure: ((Error) -> Void)? { get set }
    func start(targetFormat: AVAudioFormat) throws
    func stop()
}

/// Captures microphone audio via `AVAudioEngine` and emits PCM buffers in the format the
/// downstream `SpeechTranscriber` expects (obtained from `Transcriber.bestAudioFormat`).
/// Callbacks fire on the engine's audio thread; consumers must be thread-safe.
///
/// Unchecked-Sendable for one reason: the `AVAudioEngineConfigurationChange` observer is
/// posted on an arbitrary thread and has to reach this instance. It hops to the main actor
/// before touching anything, so every mutable field here stays main-thread confined —
/// `start`/`stop` are called from the coordinator, which is `@MainActor`.
public final class AudioCapture: MicrophoneCapture, @unchecked Sendable {
    /// Converted buffer in `targetFormat`. Fires on the engine's audio thread.
    /// Set before `start()`; the value is snapshotted there for the session's tap.
    public var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    /// Pre-conversion buffer in the mic's native format. Fires on the engine's audio
    /// thread. Used only when opt-in audio sample capture is enabled.
    public var onRawBuffer: ((AVAudioPCMBuffer) -> Void)?
    public var onAmplitude: ((Float) -> Void)?
    /// See `MicrophoneCapture.onCaptureFailure`. Called on the main actor.
    public var onCaptureFailure: ((Error) -> Void)?

    private static let log = EposLogger(category: "audio")

    /// Long-lived: the engine is created once and never deallocated while operating.
    /// Releasing an `AVAudioEngine` while CoreAudio's HAL IO thread is still rendering
    /// nulls the cached IOProc pointer → SIGSEGV on the audio thread (the rapid
    /// release-during-finalize crash). `stop()` only stops the engine and removes the
    /// tap; the next `start()` reinstalls a fresh tap + converter on the same engine.
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var isRunning = false
    /// The format the running capture converts to, kept so an input-device change can
    /// rebuild the same conversion into the same recording. Nil while stopped.
    private var activeTargetFormat: AVAudioFormat?
    private var configurationChangeObserver: (any NSObjectProtocol)?

    public init() {
        Self.log.info("audio engine created")
        // Registered for the engine's whole lifetime, not per recording: the engine
        // outlives every session and a change that arrives between recordings is a
        // no-op, while one that arrives during a hold is the case that matters.
        configurationChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.handleConfigurationChange() }
        }
    }

    deinit {
        if let configurationChangeObserver {
            NotificationCenter.default.removeObserver(configurationChangeObserver)
        }
    }

    /// Begin capture. Converts the input node's native format to `targetFormat` via
    /// `AVAudioConverter` and emits converted buffers on `onBuffer`. RMS amplitude is
    /// computed off the pre-conversion buffer and reported via `onAmplitude`.
    public func start(targetFormat: AVAudioFormat) throws {
        try openInputPath(targetFormat: targetFormat)
        activeTargetFormat = targetFormat
        isRunning = true
    }

    /// Stop capture: halt the engine and remove the tap, keeping the engine allocated
    /// (see the `engine` property note). Idempotent. The next `start` reinstalls.
    public func stop() {
        guard isRunning else { return }
        isRunning = false
        activeTargetFormat = nil
        Self.log.info("capture stopping")
        engine.stop()                          // synchronous; quiesces the HAL IO thread
        engine.inputNode.removeTap(onBus: 0)   // safe only after the engine has stopped
        converter = nil
        Self.log.info("capture stopped")
    }

    /// Build the converter, install the tap, and start the engine. Shared by `start`
    /// and the recovery after an input-device change, so both paths configure the
    /// input path identically.
    private func openInputPath(targetFormat: AVAudioFormat) throws {
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

        // Snapshot the callbacks now so the realtime audio thread reads stable locals
        // instead of these mutable properties (written on the main thread), closing
        // the cross-thread data race on the closure pointers. The tap captures only
        // value locals — no `self` — so there is nothing to tear out from under it.
        let onRawBuffer = self.onRawBuffer
        let onAmplitude = self.onAmplitude
        let onBuffer = self.onBuffer

        // Defensive: clear any tap left by a prior aborted session before reinstalling
        // (the engine is long-lived now, so a stale tap would survive across calls).
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            onRawBuffer?(buffer)

            if let amplitude = Self.rms(of: buffer) {
                onAmplitude?(amplitude)
            }

            // +1 frame: the SRC resampler can emit one extra frame on buffers where
            // accumulated fractional phase rolls over, beyond ceil(in * ratio).
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * rateRatio)) + 1
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
                    Self.log.error("convert failed: \(String(describing: convError))")
                }
                return
            }

            onBuffer?(output)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            Self.log.error("engine start failed: \(String(describing: error))")
            throw AudioCaptureError.engineFailed(error)
        }

        self.converter = converter
        Self.log.info("capture started: input \(inputFormat.sampleRate)Hz/\(inputFormat.channelCount)ch -> target \(targetFormat.sampleRate)Hz/\(targetFormat.channelCount)ch")
    }

    /// Recover the in-flight capture after the input hardware changed underneath it.
    ///
    /// `AVAudioEngine` handles a device change (AirPods connecting, a USB interface
    /// unplugged, a sample-rate switch) by stopping itself, uninitializing, and removing
    /// every installed tap. Nothing throws and nothing else notices: the tap simply never
    /// fires again, so the amplitude freezes, the glow keeps advertising a live mic, and
    /// every word after the switch is lost. Rebuilding the input path here keeps the
    /// dictation the user is still speaking going, on the new device, at the same target
    /// format. A rebuild that fails ends the recording honestly instead of silently.
    private func handleConfigurationChange() {
        guard isRunning, let targetFormat = activeTargetFormat else { return }
        Self.log.info("input configuration changed during capture; restarting engine")
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        do {
            try openInputPath(targetFormat: targetFormat)
            Self.log.info("capture resumed on the reconfigured input")
        } catch {
            isRunning = false
            activeTargetFormat = nil
            converter = nil
            Self.log.error(
                "capture restart failed after input configuration change: \(String(describing: error))"
            )
            onCaptureFailure?(error)
        }
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
