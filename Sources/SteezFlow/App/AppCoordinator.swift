import AVFoundation
import Foundation
import OSLog
import SwiftUI

public enum CoordinatorState: Equatable {
    case idle
    case recording
    case finalizing
}

@MainActor
public final class AppCoordinator: ObservableObject {
    @Published public private(set) var state: CoordinatorState = .idle
    @Published public private(set) var partialTranscript: String = ""
    @Published public private(set) var amplitude: Float = 0

    private let hotkey: FnHotkey
    private let audio: AudioCapture
    private let transcriber: Transcriber
    private let injector: TextInjector
    private let permissions: PermissionsGate
    private let assets: AssetManager
    private let settings: Settings
    private let log = Logger(subsystem: "com.steez.SteezFlow", category: "coordinator")

    private var transcriptionTask: Task<Void, Never>?
    private var captureFormat: AVAudioFormat?
    private var didBootstrap = false
    private lazy var indicator: RecordingIndicatorController = {
        let controller = RecordingIndicatorController()
        controller.attach(content: RecordingIndicator(coordinator: self))
        return controller
    }()

    // Race coordination between finishRecording and runSession. Both run on @MainActor
    // so plain Bools are safe; the race we're guarding is one happening across awaits.
    private var sessionReady = false
    private var finishRequested = false

    public init(
        hotkey: FnHotkey = FnHotkey(),
        audio: AudioCapture = AudioCapture(),
        injector: TextInjector = TextInjector(),
        settings: Settings = Settings.load(),
        autoStart: Bool = true
    ) {
        self.hotkey = hotkey
        self.audio = audio
        self.injector = injector
        self.settings = settings
        self.permissions = PermissionsGate()
        self.assets = AssetManager(locale: settings.locale)
        self.transcriber = Transcriber(locale: settings.locale)
        if autoStart {
            bindHotkey()
        }
    }

    /// Identifier of the locale this coordinator was configured with. Read-only —
    /// changing locales mid-session is post-baseline.
    public var localeIdentifier: String { settings.localeIdentifier }

    /// Synchronous read of current permission grants (no prompts).
    /// Used by MenuBarView to surface a warning row when something isn't granted.
    public func snapshotPermissions() -> PermissionsSnapshot {
        permissions.snapshot()
    }

    /// One-time launch wiring: prompt for permissions, install the locale asset,
    /// and cache the analyzer's preferred audio format. Safe to call repeatedly;
    /// downstream calls are idempotent.
    public func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        log.info("bootstrap begin")
        _ = await permissions.requestAll()
        _ = await assets.prepare()
        captureFormat = await transcriber.bestAudioFormat()
        log.info("bootstrap done format=\(String(describing: self.captureFormat))")
    }

    private func bindHotkey() {
        hotkey.onPress = { [weak self] in self?.startRecording() }
        hotkey.onRelease = { [weak self] in self?.finishRecording() }
        hotkey.start()
    }

    public func startRecording() {
        guard state == .idle else { return }
        guard let format = captureFormat else {
            log.error("cannot start: capture format unavailable (bootstrap incomplete?)")
            return
        }
        state = .recording
        partialTranscript = ""
        amplitude = 0
        sessionReady = false
        finishRequested = false
        indicator.show()
        log.info("recording start")

        let transcriber = transcriber
        let audio = audio
        let injector = injector

        transcriptionTask = Task { [weak self] in
            await self?.runSession(
                transcriber: transcriber,
                audio: audio,
                injector: injector,
                format: format
            )
        }
    }

    public func finishRecording() {
        guard state == .recording else { return }
        state = .finalizing
        log.info("recording finalize (sessionReady=\(self.sessionReady))")
        finishRequested = true
        if sessionReady {
            audio.stop()
            let transcriber = transcriber
            Task { await transcriber.finish() }
        }
        // If the session isn't ready yet, runSession will see finishRequested and
        // short-circuit immediately after start() resumes. Either way runSession
        // drives the cleanup + state -> .idle.
    }

    /// Drives one recording: starts transcription, plumbs audio buffers in, drains the
    /// event stream into the published UI state, and on stream completion pastes the
    /// final text and resets to idle. Always returns to `.idle` even on error.
    private func runSession(
        transcriber: Transcriber,
        audio: AudioCapture,
        injector: TextInjector,
        format: AVAudioFormat
    ) async {
        var finalText = ""
        do {
            let events = try await transcriber.start()

            if finishRequested {
                // User released fn before the analyzer was installed. Skip audio entirely
                // and finalize so the drain completes immediately.
                sessionReady = true
                await transcriber.finish()
            } else {
                audio.onBuffer = { buffer in transcriber.accept(buffer) }
                audio.onAmplitude = { [weak self] amp in
                    Task { @MainActor in self?.amplitude = amp }
                }
                try audio.start(targetFormat: format)
                sessionReady = true
                // If finish landed between sessionReady=false and audio.start, finishRecording
                // skipped its own audio.stop+finish path; cover the gap here.
                if finishRequested {
                    audio.stop()
                    await transcriber.finish()
                }
            }

            for await event in events {
                switch event {
                case .partial(let text):
                    partialTranscript = text
                case .final(let text):
                    finalText = text
                case .failed(let message):
                    log.error("transcription failed: \(message, privacy: .public)")
                }
            }
        } catch {
            log.error("session error: \(String(describing: error), privacy: .public)")
            audio.stop()
            await transcriber.finish()
        }

        audio.onBuffer = nil
        audio.onAmplitude = nil

        if !finalText.isEmpty {
            injector.paste(finalText)
        }

        indicator.hide()
        amplitude = 0
        partialTranscript = ""
        sessionReady = false
        finishRequested = false
        transcriptionTask = nil
        state = .idle
        log.info("recording done (finalChars=\(finalText.count))")
    }
}
