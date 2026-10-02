import CoreAudio
import Foundation

/// The coordinator owns this catalog and forwards changes to the capture and menu.
@MainActor
public final class AudioInputDeviceMonitor {
    public private(set) var snapshot = AudioInputDeviceSnapshot(devices: [], defaultInputDeviceUID: nil)
    public var onChange: ((AudioInputDeviceSnapshot) -> Void)?
    private let snapshotReader: () throws -> AudioInputDeviceSnapshot
    private let observeHardwareChanges: Bool
    private var systemObservations: [AudioInputPropertyObservation] = []
    private var deviceObservations: [AudioInputPropertyObservation] = []
    private static let log = EposLogger(category: "audio")

    public init(
        snapshotReader: @escaping () throws -> AudioInputDeviceSnapshot = AudioInputDevices.snapshot,
        observeHardwareChanges: Bool = true
    ) {
        self.snapshotReader = snapshotReader
        self.observeHardwareChanges = observeHardwareChanges
        refresh()
        if observeHardwareChanges {
            systemObservations = [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice]
                .compactMap { observe(object: AudioObjectID(kAudioObjectSystemObject), selector: $0) }
        }
    }

    public func refresh() {
        let next: AudioInputDeviceSnapshot
        do {
            next = try snapshotReader()
        } catch {
            Self.log.error("input device inventory unavailable: \(String(describing: error))")
            next = AudioInputDeviceSnapshot(devices: [], defaultInputDeviceUID: nil)
        }
        if observeHardwareChanges {
            deviceObservations = next.devices.flatMap { device in
                [kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyName].compactMap {
                    observe(object: device.deviceID, selector: $0)
                }
            }
        }
        guard next != snapshot else { return }
        snapshot = next
        onChange?(next)
    }

    private func observe(
        object: AudioObjectID, selector: AudioObjectPropertySelector
    ) -> AudioInputPropertyObservation? {
        AudioInputPropertyObservation(object: object, selector: selector) { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
    }
}

/// Owns matching Core Audio registration and removal arguments across actor teardown.
private final class AudioInputPropertyObservation: @unchecked Sendable {
    private let object: AudioObjectID
    private let property: AudioObjectPropertyAddress
    private let listener: AudioObjectPropertyListenerBlock

    init?(object: AudioObjectID, selector: AudioObjectPropertySelector, onChange: @escaping @Sendable () -> Void) {
        self.object = object
        property = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        listener = { _, _ in onChange() }
        var address = property
        guard AudioObjectAddPropertyListenerBlock(object, &address, .main, listener) == noErr else { return nil }
    }

    deinit {
        var address = property
        AudioObjectRemovePropertyListenerBlock(object, &address, .main, listener)
    }
}
