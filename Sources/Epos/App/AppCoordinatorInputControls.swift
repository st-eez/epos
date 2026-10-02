import Foundation

extension AppCoordinator {
    public var dictationShortcut: DictationShortcut { settings.dictationShortcut }
    public var inputDeviceUID: String? { settings.inputDeviceUID }
    public var availableMicrophones: [AudioInputDevice] { inputDeviceSnapshot.devices }

    public var selectedMicrophoneName: String {
        guard let uid = inputDeviceUID else { return "System default" }
        return availableMicrophones.first(where: { $0.uid == uid })?.name ?? "Unavailable"
    }

    @discardableResult
    public func setDictationShortcut(_ shortcut: DictationShortcut) -> Bool {
        guard canChangeInputControls else { return false }
        guard settings.dictationShortcut != shortcut else { return true }
        cancelDeferredStart()
        updateSettings { $0.dictationShortcut = shortcut }
        hotkey.setShortcut(shortcut)
        return true
    }

    @discardableResult
    public func setInputDeviceUID(_ uid: String?) -> Bool {
        guard canChangeInputControls else { return false }
        refreshInputDevices()
        if let uid, !availableMicrophones.contains(where: { $0.uid == uid }) { return false }
        guard settings.inputDeviceUID != uid else { return true }
        updateSettings { $0.inputDeviceUID = uid }
        return true
    }

    /// The recorder releases every candidate key before ending suspension and
    /// applying its binding. Deferred presses cannot survive into that edit.
    @discardableResult
    public func setRecordingShortcut(_ recording: Bool) -> Bool {
        if recording {
            guard canChangeInputControls else { return false }
            cancelDeferredStart()
        }
        isRecordingShortcut = recording
        hotkey.setRecordingShortcut(recording)
        if !recording { _ = snapshotPermissions() }
        return true
    }
}
