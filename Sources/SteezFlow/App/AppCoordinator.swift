import AVFoundation
import Foundation
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

    /// Running display: committed finals + in-progress partial. The partial replaces
    /// only the tail because `SpeechTranscriber` emits volatile partials for the
    /// in-progress segment alongside committed per-segment finals.
    public var displayText: String { finalText + partial }

    private let hotkey: FnHotkey
    private let audio: AudioCapture
    private let transcriber: Transcriber
    private let injector: TextInjector
    private let canonicalizerProvider: () -> TranscriptCanonicalizer
    private let permissions: PermissionsGate
    private let assets: AssetManager
    private let settings: Settings
    // Dogfood `.wav` capture — temporary, remove with DogfoodTap.swift + AudioCapture.onRawBuffer.
    private let dogfood = DogfoodTap()
    private let log = SteezFlowLogger(category: "coordinator")

    private var transcriptionTask: Task<Void, Never>?
    private var captureFormat: AVAudioFormat?
    private var didBootstrap = false
    private lazy var indicator: RecordingIndicatorController = {
        let controller = RecordingIndicatorController()
        controller.attach(content: RecordingIndicator(coordinator: self))
        return controller
    }()

    public init(
        hotkey: FnHotkey = FnHotkey(),
        audio: AudioCapture = AudioCapture(),
        injector: TextInjector = TextInjector(),
        canonicalizerProvider: @escaping () -> TranscriptCanonicalizer = { .load() },
        settings: Settings = Settings.load(),
        autoStart: Bool = true
    ) {
        self.hotkey = hotkey
        self.audio = audio
        self.injector = injector
        self.canonicalizerProvider = canonicalizerProvider
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
        finalText = ""
        partial = ""
        amplitude = 0
        indicator.show()
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

        let events: AsyncStream<TranscriptEvent>
        do {
            events = try await transcriber.start()
            guard state == .recording else {
                await transcriber.finish()
                indicator.hide()
                amplitude = 0
                partial = ""
                transcriptionTask = nil
                state = .idle
                return
            }
            audio.onBuffer = { buffer in transcriber.accept(buffer) }
            audio.onAmplitude = { [weak self] amp in
                Task { @MainActor in
                    guard let self, self.state == .recording else { return }
                    self.amplitude = amp
                }
            }
            audio.onRawBuffer = { buffer in dogfood.write(buffer) }
            try audio.start(targetFormat: format)
        } catch {
            log.error("recording setup failed: \(String(describing: error))")
            audio.onBuffer = nil
            audio.onAmplitude = nil
            audio.onRawBuffer = nil
            dogfood.stop(keeping: false)
            await transcriber.finish()
            indicator.hide()
            state = .idle
            return
        }

        for await event in events {
            switch event {
            case .partial(let text):
                partial = text
            case .final(let text):
                finalText += text
                partial = ""
            case .failed(let message):
                log.error("transcription failed: \(message)")
            }
        }

        audio.stop()
        audio.onBuffer = nil
        audio.onAmplitude = nil
        audio.onRawBuffer = nil
        await transcriber.finish()

        let hasTranscribedText = !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        dogfood.stop(keeping: hasTranscribedText)

        if hasTranscribedText {
            injector.paste(canonicalizerProvider().canonicalize(finalText))
        }

        indicator.hide()
        amplitude = 0
        partial = ""
        transcriptionTask = nil
        state = .idle
        log.info("recording done (finalChars=\(self.finalText.count))")
    }
}
