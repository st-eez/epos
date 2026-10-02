import AVFoundation
import CoreAudio
import XCTest
@testable import Epos

@MainActor
final class AudioInputDeviceTests: XCTestCase {
    private let builtIn = AudioInputDevice(uid: "built-in", name: "Built-in microphone", deviceID: 10)
    private let headset = AudioInputDevice(uid: "headset", name: "Headset", deviceID: 20)

    private func snapshot(
        _ devices: [AudioInputDevice], defaultUID: String? = "built-in"
    ) -> AudioInputDeviceSnapshot {
        AudioInputDeviceSnapshot(devices: devices, defaultInputDeviceUID: defaultUID)
    }

    private func configuration(uid: String?, echoCancellation: Bool = true) -> AudioCaptureInputConfiguration {
        AudioCaptureInputConfiguration(
            targetFormat: AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!,
            echoCancellation: echoCancellation, inputDeviceUID: uid
        )
    }

    func testPinnedInputIgnoresAnotherSystemDefault() throws {
        let devices = snapshot([builtIn, headset], defaultUID: headset.uid)
        XCTAssertEqual(try devices.deviceID(for: builtIn.uid), builtIn.deviceID)
        XCTAssertEqual(try devices.deviceID(for: nil), headset.deviceID)
    }

    func testMissingPinDoesNotFallBackToAvailableDefault() {
        let devices = snapshot([headset], defaultUID: headset.uid)
        XCTAssertThrowsError(try devices.deviceID(for: builtIn.uid))
    }

    func testNoSystemDefaultDoesNotSelectTheFirstAvailableInput() {
        let devices = snapshot([builtIn, headset], defaultUID: nil)
        XCTAssertThrowsError(try devices.deviceID(for: nil))
    }

    func testUnknownDeviceIDCannotBeResolved() {
        let invalid = AudioInputDevice(uid: "invalid", name: "Unavailable", deviceID: kAudioObjectUnknown)
        XCTAssertThrowsError(try snapshot([invalid], defaultUID: invalid.uid).deviceID(for: nil))
    }

    /// Run the shared initial-open/recovery configuration twice. The saved UID and
    /// echo mode stay frozen while a reconnection replaces the native device ID.
    func testRecoveryResolvesTheSameUIDAgainAndReappliesModeBeforeBinding() throws {
        let route = configuration(uid: builtIn.uid)
        var inventory = snapshot([builtIn, headset])
        var events: [String] = []
        let configure = {
            try route.configureDevice(snapshotReader: { inventory }, applyVoiceProcessing: {
                events.append("mode-\($0)")
            }, bindDevice: { events.append("bind-\($0)") })
        }
        XCTAssertEqual(try configure(), 10)
        let reconnected = AudioInputDevice(uid: builtIn.uid, name: builtIn.name, deviceID: 30)
        inventory = snapshot([reconnected, headset], defaultUID: headset.uid)
        XCTAssertEqual(try configure(), 30)
        XCTAssertEqual(events, ["mode-true", "bind-10", "mode-true", "bind-30"])
    }

    func testDefaultRecoveryResolvesTheCurrentDefault() throws {
        let route = configuration(uid: nil, echoCancellation: false)
        var inventory = snapshot([builtIn, headset])
        var boundIDs: [AudioDeviceID] = []
        let configure = {
            try route.configureDevice(snapshotReader: { inventory }, applyVoiceProcessing: { _ in },
                                      bindDevice: { boundIDs.append($0) })
        }
        _ = try configure()
        inventory = snapshot([builtIn, headset], defaultUID: headset.uid)
        _ = try configure()
        XCTAssertEqual(boundIDs, [builtIn.deviceID, headset.deviceID])
    }

    func testDisconnectedPinRefusesRecoveryBeforeModeOrBinding() {
        let route = configuration(uid: builtIn.uid)
        var didConfigure = false
        XCTAssertThrowsError(try route.configureDevice(
            snapshotReader: { self.snapshot([self.headset], defaultUID: self.headset.uid) },
            applyVoiceProcessing: { _ in didConfigure = true }, bindDevice: { _ in didConfigure = true }
        ))
        XCTAssertFalse(didConfigure)
    }

    func testUnchangedBindingDoesNotCallTheNativeSetter() throws {
        var didSet = false
        try AudioInputDeviceBinding.bind(10, currentDeviceID: 10, setDevice: { _ in didSet = true },
                                         readDevice: { 10 })
        XCTAssertFalse(didSet)
    }

    func testBindingFailureAndIncorrectReadbackAreReported() {
        struct Refused: Error {}
        XCTAssertThrowsError(try AudioInputDeviceBinding.bind(
            10, currentDeviceID: 20, setDevice: { _ in throw Refused() }, readDevice: { 20 }
        ))
        XCTAssertThrowsError(try AudioInputDeviceBinding.bind(
            10, currentDeviceID: 20, setDevice: { _ in }, readDevice: { 20 }
        ))
    }

    func testMonitorPublishesLossAndReconnectFromInjectedInventory() {
        var inventory = snapshot([builtIn, headset])
        let monitor = AudioInputDeviceMonitor(snapshotReader: { inventory }, observeHardwareChanges: false)
        var changes: [AudioInputDeviceSnapshot] = []
        monitor.onChange = { changes.append($0) }
        monitor.refresh()
        XCTAssertTrue(changes.isEmpty)

        inventory = snapshot([headset], defaultUID: headset.uid)
        monitor.refresh()
        XCTAssertEqual(changes, [inventory])
        XCTAssertThrowsError(try monitor.snapshot.deviceID(for: builtIn.uid))

        let reconnected = AudioInputDevice(uid: builtIn.uid, name: builtIn.name, deviceID: 30)
        inventory = snapshot([reconnected, headset], defaultUID: headset.uid)
        monitor.refresh()
        XCTAssertEqual(changes.count, 2)
        XCTAssertEqual(try monitor.snapshot.deviceID(for: builtIn.uid), reconnected.deviceID)
    }

    func testInventoryReadFailurePublishesUnavailableInsteadOfStaleDevices() {
        struct Unavailable: Error {}
        var fail = false
        let monitor = AudioInputDeviceMonitor(snapshotReader: {
            if fail { throw Unavailable() }
            return self.snapshot([self.builtIn])
        }, observeHardwareChanges: false)
        var changed = false
        monitor.onChange = { _ in changed = true }
        fail = true
        monitor.refresh()
        XCTAssertTrue(changed)
        XCTAssertTrue(monitor.snapshot.devices.isEmpty)
        XCTAssertNil(monitor.snapshot.defaultInputDeviceUID)
    }
}
