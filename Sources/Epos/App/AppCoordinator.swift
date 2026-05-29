import AVFoundation
import Foundation
import ServiceManagement
import SwiftUI

public enum CoordinatorState: Equatable {
    case idle
    case recording
    case finalizing
}

@MainActor
public final class AppCoordinator: ObservableObject {
    @Published public private(set) var state: CoordinatorState = .idle
    @Published public private(set) var finalText: String = ""
    @Published public private(set) var partial: String = ""
    @Published public private(set) var amplitude: Float = 0
    @Published public private(set) var settings: Settings

    /// Running display: committed finals + in-progress partial. The partial replaces
    /// only the tail because `SpeechTranscriber` emits volatile partials for the
    /// in-progress segment alongside committed per-segment finals.
    public var displayText: String { finalText + partial }

    private let hotkey: FnHotkey
    private let audio: AudioCapture
    private let transcriber: Transcriber
    private let textInsertion: TextInsertionBackend
    private let polishEngine: any PolishEngine
    private let permissions: PermissionsGate
    private let assets: AssetManager
    /// Shared correction rules: this coordinator canonicalizes against it; the Corrections
    /// editor mutates the same instance (the app hands the editor `coordinator.corrections`).
    public let corrections = CorrectionStore()
    // Opt-in `.wav` capture for local eval material. Disabled by default.
    private let dogfood = DogfoodTap()
    private let log = EposLogger(category: "coordinator")
    private var transcriptTiming = TranscriptTimingDiagnostics()

    private var transcriptionTask: Task<Void, Never>?
    private var captureFormat: AVAudioFormat?
    private var textInsertionSession: ProgressiveTranscriptInsertionSession?
    private var didBootstrap = false
    private lazy var indicator: RecordingIndicatorController = {
        let controller = RecordingIndicatorController()
        controller.attach(content: RecordingIndicator(coordinator: self))
        return controller
    }()

    public init(
        hotkey: FnHotkey = FnHotkey(),
        audio: AudioCapture = AudioCapture(),
        textInsertion: TextInsertionBackend = KeystrokeTextInjector(),
        settings: Settings = Settings.load(),
        polishEngine: any PolishEngine = FoundationModelsPolishEngine(),
        autoStart: Bool = true
    ) {
        self.hotkey = hotkey
        self.audio = audio
        self.textInsertion = textInsertion
        self.polishEngine = polishEngine
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

    public var saveAudioSamples: Bool { settings.saveAudioSamples }

    public func setSaveAudioSamples(_ enabled: Bool) {
        guard settings.saveAudioSamples != enabled else { return }
        settings.saveAudioSamples = enabled
        settings.save()
        log.info("audio sample capture \(enabled ? "enabled" : "disabled")")
    }

    public var polishEnabled: Bool { settings.polishEnabled }

    public func setPolishEnabled(_ enabled: Bool) {
        guard settings.polishEnabled != enabled else { return }
        settings.polishEnabled = enabled
        settings.save()
        log.info("dictation polish \(enabled ? "enabled" : "disabled")")
    }

    /// Built fresh from current settings so a mid-session toggle takes effect on
    /// the next recording. The engine is shared (model assets are global).
    private var polisher: TranscriptPolisher {
        TranscriptPolisher(enabled: settings.polishEnabled, engine: polishEngine)
    }

    /// Live launch-at-login state from the system — the source of truth, which the user
    /// can also change in System Settings — not the cached `settings` copy.
    public var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    public func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            settings.launchAtLogin = enabled
            settings.save()
            log.info("launch-at-login \(enabled ? "enabled" : "disabled")")
        } catch {
            log.error("launch-at-login toggle failed: \(String(describing: error))")
        }
    }

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
        finalText = ""
        partial = ""
        amplitude = 0
        textInsertionSession = ProgressiveTranscriptInsertionSession(
            insertionSession: textInsertion.startInsertionSession(),
            canonicalize: { [corrections] text in corrections.canonicalize(text) },
            target: AXInsertionTargetObserver()
        )
        transcriptTiming.start()
        indicator.show()
        polisher.prewarm()
        log.info("recording start")

        transcriptionTask = Task { [weak self] in
            await self?.runSession(format: format)
        }
    }

    public func finishRecording() {
        guard state == .recording else { return }
        state = .finalizing
        log.info("recording finalize")
        audio.stop()
        let transcriber = transcriber
        Task { await transcriber.finish() }
    }

    private func runSession(format: AVAudioFormat) async {
        let transcriber = self.transcriber
        let audio = self.audio
        let dogfood = self.dogfood
        let shouldSaveAudioSamples = settings.saveAudioSamples

        let events: AsyncStream<TranscriptEvent>
        do {
            events = try await transcriber.start()
            guard state == .recording else {
                cancelTextInsertionSession()
                await resetToIdle()
                return
            }
            audio.onBuffer = { buffer in transcriber.accept(buffer) }
            audio.onAmplitude = { [weak self] amp in
                Task { @MainActor in
                    guard let self, self.state == .recording else { return }
                    self.amplitude = amp
                }
            }
            if shouldSaveAudioSamples {
                audio.onRawBuffer = { buffer in dogfood.write(buffer) }
            } else {
                audio.onRawBuffer = nil
            }
            try audio.start(targetFormat: format)
        } catch {
            log.error("recording setup failed: \(String(describing: error))")
            dogfood.stop(keeping: false)
            cancelTextInsertionSession()
            await resetToIdle()
            return
        }

        for await event in events {
            switch event {
            case .partial(let text):
                handlePartialTranscript(text)
                logTranscriptTiming(kind: .partial, eventText: text)
            case .final(let text):
                handleFinalTranscriptSegment(text)
                logTranscriptTiming(kind: .final, eventText: text)
            case .failed(let message):
                log.error("transcription failed: \(message)")
            }
        }

        audio.stop()

        let hasTranscribedText = !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        dogfood.stop(keeping: shouldSaveAudioSamples && hasTranscribedText)

        if hasTranscribedText {
            // Opt-in LLM polish runs once on the final transcript while the
            // indicator is still up (state == .finalizing). It never throws and
            // falls back to the raw text, so the reconcile below is unchanged
            // when polish is off, unavailable, or rejected by the guard.
            let polished = await polisher.polish(finalText)
            insertFinalTranscript(polished)
            finishTextInsertionSession()
        } else {
            cancelTextInsertionSession()
        }

        await resetToIdle()
        log.info("recording done (finalChars=\(self.finalText.count))")
    }

    func handlePartialTranscript(_ text: String) {
        partial = text
        textInsertionSession?.acceptPartialTranscript(displayText)
    }

    func handleFinalTranscriptSegment(_ text: String) {
        finalText += text
        partial = ""
        textInsertionSession?.acceptFinalTranscript(finalText)
    }

    func insertFinalTranscript(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let textInsertionSession {
            textInsertionSession.acceptFinalTranscript(text)
            return
        }

        let oneShotSession = ProgressiveTranscriptInsertionSession(
            insertionSession: textInsertion.startInsertionSession(),
            canonicalize: { [corrections] text in corrections.canonicalize(text) },
            target: AXInsertionTargetObserver()
        )
        oneShotSession.acceptFinalTranscript(text)
        oneShotSession.finish()
    }

    func logTranscriptTiming(kind: TranscriptTimingEventKind, eventText: String) {
        log.info(transcriptTiming.eventMessage(
            kind: kind,
            eventText: eventText,
            finalText: finalText,
            partialText: partial
        ))
    }

    private func finishTextInsertionSession() {
        textInsertionSession?.finish()
        textInsertionSession = nil
    }

    private func cancelTextInsertionSession() {
        textInsertionSession?.cancel()
        textInsertionSession = nil
    }

    /// Common teardown shared by every exit from `runSession`. Each piece is idempotent
    /// (callbacks set to nil, `finish()` is idempotent). Path-specific work — `audio.stop()`,
    /// `dogfood.stop(keeping:)`, insertion session closeout — stays at the call sites; only
    /// what every path does identically lives here, so the three exits can't drift apart again.
    private func resetToIdle() async {
        audio.onBuffer = nil
        audio.onAmplitude = nil
        audio.onRawBuffer = nil
        await transcriber.finish()
        indicator.hide()
        amplitude = 0
        partial = ""
        transcriptionTask = nil
        transcriptTiming.finish()
        state = .idle
    }
}
