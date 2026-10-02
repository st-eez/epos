import AppKit
import AVFoundation
import XCTest
@testable import Epos

@MainActor
final class CoordinatorInputControlsTests: XCTestCase {
    private final class Hardware {
        var held = false
        var snapshot = AudioInputDeviceSnapshot(
            devices: [
                AudioInputDevice(uid: "built-in-test", name: "Built-in test input", deviceID: 11),
                AudioInputDevice(uid: "wireless-test", name: "Wireless test input", deviceID: 22)
            ],
            defaultInputDeviceUID: "wireless-test"
        )
    }

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var hardware: Hardware!
    private var audio: FakeMicrophoneCapture!
    private var monitor: AudioInputDeviceMonitor!
    private var hotkey: DictationHotkey!

    override func setUp() async throws {
        suiteName = "com.steez.Epos.tests.input-controls.\(UUID())"
        defaults = UserDefaults(suiteName: suiteName)
        hardware = Hardware()
        audio = FakeMicrophoneCapture()
        monitor = AudioInputDeviceMonitor(
            snapshotReader: { [hardware = hardware!] in hardware.snapshot },
            observeHardwareChanges: false
        )
        hotkey = DictationHotkey(
            hardwareStateReader: { [hardware = hardware!] in hardware.held },
            installMonitor: { _ in NSObject() }, removeMonitor: { _ in }
        )
    }

    override func tearDown() async throws {
        hotkey.stop()
        monitor = nil
        hotkey = nil
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    private func makeCoordinator(settings: Settings = Settings()) -> AppCoordinator {
        let coordinator = AppCoordinator(
            hotkey: hotkey, audio: audio, transcriber: FakeTranscriber(),
            textInsertion: AcceptingBackend(),
            insertionTargetObserverFactory: { StableOpaqueObserver() },
            settings: settings, settingsDefaults: defaults, inputDevices: monitor,
            permissions: .stub(), inlinePreviewEnabled: false, autoStart: false
        )
        coordinator.captureFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)
        return coordinator
    }

    private func combination() throws -> DictationShortcut {
        try XCTUnwrap(DictationShortcut(modifierFlags: UInt64(NSEvent.ModifierFlags.control.rawValue), keyCode: 49))
    }

    func testSelectedShortcutInstallsAndPersistsThroughCoordinator() throws {
        let shortcut = try combination()
        let coordinator = makeCoordinator(settings: Settings(dictationShortcut: shortcut))
        XCTAssertEqual(hotkey.shortcut, shortcut)
        XCTAssertTrue(coordinator.setDictationShortcut(.functionKey))
        XCTAssertEqual(hotkey.shortcut, .functionKey)
        XCTAssertEqual(Settings.load(from: defaults).dictationShortcut, .functionKey)
    }

    func testMicrophoneChoiceIsForwardedAndCannotChangeDuringHold() async {
        let coordinator = makeCoordinator()
        XCTAssertTrue(coordinator.setInputDeviceUID("built-in-test"))
        XCTAssertEqual(Settings.load(from: defaults).inputDeviceUID, "built-in-test")
        coordinator.startRecording()
        XCTAssertEqual(audio.lastInputDeviceUID, "built-in-test")
        XCTAssertFalse(coordinator.setInputDeviceUID("wireless-test"))
        XCTAssertFalse(coordinator.setDictationShortcut(.functionKey))
        XCTAssertFalse(coordinator.setRecordingShortcut(true))
        XCTAssertEqual(coordinator.inputDeviceUID, "built-in-test")
        coordinator.finishRecording()
        XCTAssertFalse(coordinator.setInputDeviceUID(nil))
        await coordinator.transcriptionTask?.value
        XCTAssertTrue(coordinator.setInputDeviceUID(nil))
        XCTAssertNil(Settings.load(from: defaults).inputDeviceUID)
    }

    func testDisconnectedPinIsRetainedAndRefusesCaptureWithoutFallback() {
        let coordinator = makeCoordinator(settings: Settings(inputDeviceUID: "disconnected-test"))
        XCTAssertEqual(coordinator.startReadiness, .blocked(.microphoneUnavailable))
        XCTAssertEqual(coordinator.selectedMicrophoneName, "Unavailable")
        coordinator.startRecording()
        XCTAssertEqual(audio.startCount, 0)
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(coordinator.startNotice, "Mic unavailable")
        XCTAssertEqual(coordinator.inputDeviceUID, "disconnected-test")
        XCTAssertFalse(coordinator.setInputDeviceUID("another-disconnected-input"))
        XCTAssertTrue(coordinator.setInputDeviceUID(nil))
        XCTAssertEqual(coordinator.startReadiness, .ready)
    }

    func testInventoryChangeEndsLostCaptureAndKeepsPinForNextHold() async {
        let coordinator = makeCoordinator(settings: Settings(inputDeviceUID: "built-in-test"))
        coordinator.startRecording()
        audio.deviceChangeError = AudioInputDeviceError.unavailable
        hardware.snapshot = AudioInputDeviceSnapshot(
            devices: [hardware.snapshot.devices[1]], defaultInputDeviceUID: "wireless-test"
        )
        monitor.refresh()
        XCTAssertEqual(coordinator.state, .finalizing)
        XCTAssertTrue(coordinator.microphoneUnavailable)
        XCTAssertEqual(coordinator.inputDeviceUID, "built-in-test")
        XCTAssertEqual(coordinator.startReadiness, .blocked(.microphoneUnavailable))
        await coordinator.transcriptionTask?.value
        XCTAssertEqual(coordinator.state, .idle)
    }

    func testRecorderSuspensionCannotStartDictationAndAllowsApplyAfterRelease() throws {
        let coordinator = makeCoordinator()
        XCTAssertTrue(coordinator.setRecordingShortcut(true))
        coordinator.startRecording()
        XCTAssertEqual(audio.startCount, 0)
        XCTAssertFalse(coordinator.pendingDeferredStart)
        XCTAssertFalse(coordinator.setInputDeviceUID("built-in-test"))
        XCTAssertTrue(coordinator.setRecordingShortcut(false))
        XCTAssertTrue(coordinator.setDictationShortcut(try combination()))
        XCTAssertEqual(Settings.load(from: defaults).dictationShortcut, hotkey.shortcut)
    }

    func testReleaseClearsDeferredHoldBeforeControlsCanChange() throws {
        let coordinator = makeCoordinator()
        coordinator.captureFormat = nil
        hardware.held = true
        coordinator.startRecording()
        XCTAssertTrue(coordinator.pendingDeferredStart)
        XCTAssertFalse(coordinator.setRecordingShortcut(true))
        hardware.held = false
        coordinator.finishRecording()
        XCTAssertFalse(coordinator.pendingDeferredStart)
        XCTAssertTrue(coordinator.setDictationShortcut(try combination()))
    }

    func testCancelledReplayCannotStartWhileRecordingShortcut() async {
        let coordinator = makeCoordinator()
        coordinator.pendingDeferredStart = true
        hardware.held = true
        coordinator.replayDeferredStartIfNeeded()
        let replay = coordinator.deferredStartReplayTask
        hardware.held = false
        XCTAssertTrue(coordinator.setRecordingShortcut(true))
        await replay?.value
        XCTAssertEqual(audio.startCount, 0)
        XCTAssertFalse(coordinator.pendingDeferredStart)
        XCTAssertEqual(coordinator.state, .idle)
        _ = coordinator.setRecordingShortcut(false)
    }

    func testCustomBindingDeferredReplayUsesConfiguredHeldState() async throws {
        let coordinator = makeCoordinator(settings: Settings(dictationShortcut: try combination()))
        coordinator.captureFormat = nil
        hardware.held = true
        coordinator.startRecording()
        coordinator.captureFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)
        coordinator.replayDeferredStartIfNeeded()
        await coordinator.deferredStartReplayTask?.value
        XCTAssertEqual(audio.startCount, 1)
        coordinator.finishRecording()
        await coordinator.transcriptionTask?.value
    }
}

private final class AcceptingBackend: TextInsertionBackend {
    func startInsertionSession() -> any TextInsertionSession { AcceptingSession() }
}

private final class AcceptingSession: TextInsertionSession {
    func insert(_ text: String) -> Bool { true }
    func finish() {}
    func cancel() {}
}
