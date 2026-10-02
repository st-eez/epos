import AVFoundation
import CoreAudio

enum AudioInputDeviceBinding {
    /// The caller stops the engine and applies voice processing before fetching this unit.
    static func bind(_ deviceID: AudioDeviceID, to inputNode: AVAudioInputNode) throws {
        let unit = inputNode.auAudioUnit
        try bind(deviceID, currentDeviceID: unit.deviceID, setDevice: { try unit.setDeviceID($0) },
                 readDevice: { unit.deviceID })
    }

    static func bind(
        _ deviceID: AudioDeviceID,
        currentDeviceID: AudioDeviceID,
        setDevice: (AudioDeviceID) throws -> Void,
        readDevice: () -> AudioDeviceID
    ) throws {
        guard deviceID != kAudioObjectUnknown else { throw AudioInputDeviceError.unavailable }
        // Repeated setters can generate configuration notifications that reopen the path.
        if currentDeviceID != deviceID { try setDevice(deviceID) }
        guard readDevice() == deviceID else { throw AudioInputDeviceError.bindingMismatch }
    }
}
