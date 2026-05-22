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
    private let log = Logger(subsystem: "com.steez.SteezFlow", category: "coordinator")

    private var transcriptionTask: Task<Void, Never>?

    public init(
        hotkey: FnHotkey = FnHotkey(),
        audio: AudioCapture = AudioCapture(),
        transcriber: Transcriber = Transcriber(),
        injector: TextInjector = TextInjector(),
        permissions: PermissionsGate = PermissionsGate(),
        assets: AssetManager = AssetManager()
    ) {
        self.hotkey = hotkey
        self.audio = audio
        self.transcriber = transcriber
        self.injector = injector
        self.permissions = permissions
        self.assets = assets
        bindHotkey()
    }

    private func bindHotkey() {
        hotkey.onPress = { [weak self] in self?.startRecording() }
        hotkey.onRelease = { [weak self] in self?.finishRecording() }
        hotkey.start()
    }

    public func startRecording() {
        guard state == .idle else { return }
        state = .recording
        partialTranscript = ""
        log.info("recording start")
        // TODO: audio.start, transcriber.start, stream partials -> partialTranscript
    }

    public func finishRecording() {
        guard state == .recording else { return }
        state = .finalizing
        log.info("recording finalize")
        // TODO: audio.stop, transcriber.finish -> await final, injector.paste(final), reset to idle
        state = .idle
    }
}
