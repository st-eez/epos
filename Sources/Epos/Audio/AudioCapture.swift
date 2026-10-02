@preconcurrency import AVFoundation
import CoreAudio
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
    /// `echoCancellation` runs the input through Apple's voice-processing IO, which
    /// subtracts what the machine is playing out of the mic signal. Read per session
    /// because the mode can only be changed while the engine is stopped.
    /// An unset UID follows System default. A chosen UID never falls back to another input.
    func start(targetFormat: AVAudioFormat, echoCancellation: Bool, inputDeviceUID: String?) throws
    /// Recheck the active route after the coordinator's hardware catalog changes.
    func inputDevicesDidChange()
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
    /// Frozen for the hold. Recovery resolves the same UID to a fresh hardware ID.
    private var activeConfiguration: AudioCaptureInputConfiguration?
    private var activeInputDeviceID: AudioDeviceID?
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
    public func start(targetFormat: AVAudioFormat, echoCancellation: Bool, inputDeviceUID: String?) throws {
        let configuration = AudioCaptureInputConfiguration(
            targetFormat: targetFormat, echoCancellation: echoCancellation, inputDeviceUID: inputDeviceUID
        )
        do {
            try openInputPath(configuration: configuration)
        } catch {
            closeInputPath()
            throw error
        }
        activeConfiguration = configuration
        isRunning = true
    }

    public func inputDevicesDidChange() {
        guard isRunning, let configuration = activeConfiguration else { return }
        do {
            let deviceID = try configuration.resolveDeviceID()
            if deviceID != activeInputDeviceID || engine.inputNode.auAudioUnit.deviceID != deviceID {
                handleConfigurationChange()
            }
        } catch {
            closeInputPath()
            Self.log.error("active input device unavailable: \(String(describing: error))")
            onCaptureFailure?(error)
        }
    }

    /// Put the input node into (or out of) Apple's voice-processing mode — the same
    /// AUVoiceProcessingIO path Siri and FaceTime use. Its echo canceller references
    /// what the *device* is rendering, not just what this app renders, so music or a
    /// video playing through the speakers is subtracted from the mic signal instead of
    /// being transcribed alongside the user. It also brings noise suppression and AGC.
    ///
    /// A device that refuses the mode is not a reason to lose the dictation the user is
    /// already speaking: log it and capture raw. The recording still happens, and the
    /// log names which mode it ran in, so a "why did it hear my music" report is
    /// answerable after the fact.
    private func applyVoiceProcessing(enabled: Bool) {
        let inputNode = engine.inputNode
        guard inputNode.isVoiceProcessingEnabled != enabled else { return }
        do {
            try inputNode.setVoiceProcessingEnabled(enabled)
            if enabled {
                // The least ducking the platform offers. This feature exists to clean up
                // the MIC signal; turning down what the user is deliberately listening to
                // is not a tool it gets to reach for. Ducking cannot be switched off on
                // macOS — the level enum has no "off", and the AudioUnit property that
                // could (`kAUVoiceIOProperty_DuckNonVoiceAudio`) is iOS-only and
                // deprecated — so `.min` is the floor.
                //
                // The tradeoff this accepts: cancellation alone leaks. Measured against
                // speech played from the speakers during a hold, raw mic transcribed 84
                // chars and `.min` still let 55 through (`.max` reached 0, at the cost of
                // flattening the user's audio, which is not a trade this app makes). The
                // canceller is adaptive and every fn press starts it unconverged, which is
                // the real limit here — not the ducking level.
                var ducking = inputNode.voiceProcessingOtherAudioDuckingConfiguration
                ducking.duckingLevel = .min
                inputNode.voiceProcessingOtherAudioDuckingConfiguration = ducking
            }
            Self.log.info("voice processing \(enabled ? "enabled" : "disabled")")
        } catch {
            Self.log.error(
                "voice processing \(enabled ? "enable" : "disable") failed; "
                    + "capturing raw input: \(String(describing: error))"
            )
        }
    }

    /// Stop capture: halt the engine and remove the tap, keeping the engine allocated
    /// (see the `engine` property note). Idempotent. The next `start` reinstalls.
    public func stop() {
        guard isRunning else { return }
        Self.log.info("capture stopping")
        closeInputPath()
        Self.log.info("capture stopped")
    }

    /// Shared unwind for a finished capture and a failed open or recovery. An open
    /// can enable voice processing before it throws, without reaching isRunning.
    private func closeInputPath() {
        isRunning = false
        activeConfiguration = nil
        activeInputDeviceID = nil
        engine.stop()                          // synchronous; quiesces the HAL IO thread
        engine.inputNode.removeTap(onBus: 0)   // safe only after the engine has stopped
        converter = nil
        // Leave voice processing off between recordings. The engine is long-lived and
        // never released, so a voice-processing unit left enabled here stays alive for
        // the whole run of the app — and its ducking is not gated on speech, so every
        // other sound on the machine stays attenuated long after the hold ends. Stopping
        // the engine is not enough to release it; the mode has to be turned off.
        applyVoiceProcessing(enabled: false)
    }

    /// Build the converter, install the tap, and start the engine. Shared by `start`
    /// and the recovery after an input-device change, so both paths configure the
    /// input path identically.
    private func openInputPath(configuration: AudioCaptureInputConfiguration) throws {
        let deviceID = try configuration.configureDevice(
            applyVoiceProcessing: applyVoiceProcessing,
            bindDevice: { try AudioInputDeviceBinding.bind($0, to: engine.inputNode) }
        )
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        let targetFormat = configuration.targetFormat

        guard inputFormat.sampleRate > 0 else {
            throw AudioCaptureError.zeroSampleRate
        }
        guard let converter = Self.makeConverter(from: inputFormat, to: targetFormat) else {
            throw AudioCaptureError.converterUnavailable
        }

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
            Self.log.error("engine start failed: \(String(describing: error))")
            throw AudioCaptureError.engineFailed(error)
        }

        self.converter = converter
        activeInputDeviceID = deviceID
        Self.log.info("capture started: input \(inputFormat.sampleRate)Hz/\(inputFormat.channelCount)ch -> target \(targetFormat.sampleRate)Hz/\(targetFormat.channelCount)ch voiceProcessing=\(inputNode.isVoiceProcessingEnabled)")
    }

    /// Recover the in-flight capture after the input hardware changed underneath it.
    ///
    /// `AVAudioEngine` handles a device change (AirPods connecting, a USB interface
    /// unplugged, a sample-rate switch) by stopping itself, uninitializing, and removing
    /// every installed tap. Rebuilding the input path reapplies the frozen input UID
    /// and capture mode at the same target format. A missing chosen input or failed
    /// rebuild ends the recording through the existing microphone failure path.
    private func handleConfigurationChange() {
        guard isRunning, let configuration = activeConfiguration else { return }
        Self.log.info("input configuration changed during capture; restarting engine")
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        do {
            try openInputPath(configuration: configuration)
            Self.log.info("capture resumed on the reconfigured input")
        } catch {
            closeInputPath()
            Self.log.error(
                "capture restart failed after input configuration change: \(String(describing: error))"
            )
            onCaptureFailure?(error)
        }
    }

    /// The mic-to-recognizer converter, configured identically wherever it is built.
    ///
    /// `channelMap` is the load-bearing line. Voice processing replaces the 1-channel
    /// hardware input with a 9-channel stream tagged `DiscreteInOrder`, carrying nine
    /// copies of the same processed mono signal. `AVAudioConverter`'s implicit N→1 mix
    /// for that layout emits digital silence — measured 0.000x gain against a real
    /// capture — which would turn every dictation into an empty transcript with no
    /// error anywhere. Selecting channel 0 explicitly is lossless (0.963x, which is
    /// the 48 kHz → 16 kHz low-pass, not attenuation).
    static func makeConverter(
        from inputFormat: AVAudioFormat,
        to targetFormat: AVAudioFormat
    ) -> AVAudioConverter? {
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            return nil
        }
        // Per Apple docs and swift-scribe pattern: skip filter priming so converter state
        // persists cleanly across per-buffer calls; first samples may be lower quality.
        converter.primeMethod = .none
        if targetFormat.channelCount == 1, inputFormat.channelCount > 1 {
            converter.channelMap = [0]
        }
        return converter
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

/// Initial open and recovery share the frozen choices, but never cache a hardware ID.
struct AudioCaptureInputConfiguration {
    let targetFormat: AVAudioFormat
    let echoCancellation: Bool
    let inputDeviceUID: String?

    func resolveDeviceID(
        snapshotReader: () throws -> AudioInputDeviceSnapshot = AudioInputDevices.snapshot
    ) throws -> AudioDeviceID {
        try snapshotReader().deviceID(for: inputDeviceUID)
    }

    func configureDevice(
        snapshotReader: () throws -> AudioInputDeviceSnapshot = AudioInputDevices.snapshot,
        applyVoiceProcessing: (Bool) -> Void,
        bindDevice: (AudioDeviceID) throws -> Void
    ) throws -> AudioDeviceID {
        let deviceID = try resolveDeviceID(snapshotReader: snapshotReader)
        // The toggle can replace the I/O unit. The binding closure fetches it after
        // applying the frozen mode, before the caller reads its format or adds a tap.
        applyVoiceProcessing(echoCancellation)
        try bindDevice(deviceID)
        return deviceID
    }
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
