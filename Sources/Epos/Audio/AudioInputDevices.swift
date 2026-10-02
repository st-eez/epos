import CoreAudio
import Foundation

public struct AudioInputDevice: Equatable, Sendable, Identifiable {
    public let uid: String
    public let name: String
    public let deviceID: AudioDeviceID
    public var id: String { uid }

    public init(uid: String, name: String, deviceID: AudioDeviceID) {
        self.uid = uid
        self.name = name
        self.deviceID = deviceID
    }
}

public struct AudioInputDeviceSnapshot: Equatable, Sendable {
    public let devices: [AudioInputDevice]
    public let defaultInputDeviceUID: String?

    public init(devices: [AudioInputDevice], defaultInputDeviceUID: String?) {
        self.devices = devices
        self.defaultInputDeviceUID = defaultInputDeviceUID
    }

    /// A missing pin stays unavailable. Only an unset pin follows System default.
    public func deviceID(for inputDeviceUID: String?) throws -> AudioDeviceID {
        guard let uid = inputDeviceUID ?? defaultInputDeviceUID,
              let device = devices.first(where: { $0.uid == uid }),
              device.deviceID != kAudioObjectUnknown else {
            throw AudioInputDeviceError.unavailable
        }
        return device.deviceID
    }
}

enum AudioInputDeviceError: Error {
    case unavailable
    case propertyReadFailed(OSStatus)
    case invalidPropertyData
    case bindingMismatch
}

/// Reads hardware metadata without opening an engine or changing system preferences.
public enum AudioInputDevices {
    public static func snapshot() throws -> AudioInputDeviceSnapshot {
        let deviceIDs = try readDeviceIDs()
        let devices = deviceIDs.compactMap { deviceID -> AudioInputDevice? in
            guard (try? readUInt32(deviceID, selector: kAudioDevicePropertyDeviceIsAlive)) == 1,
                  (try? inputChannelCount(deviceID)) ?? 0 > 0,
                  (try? readUInt32(deviceID, selector: kAudioDevicePropertyIsHidden)) != 1,
                  let uid = try? readString(deviceID, selector: kAudioDevicePropertyDeviceUID),
                  !uid.isEmpty,
                  let name = try? readString(deviceID, selector: kAudioObjectPropertyName) else {
                return nil
            }
            return AudioInputDevice(uid: uid, name: name, deviceID: deviceID)
        }.sorted { lhs, rhs in
            let comparison = lhs.name.localizedStandardCompare(rhs.name)
            return comparison == .orderedSame ? lhs.uid < rhs.uid : comparison == .orderedAscending
        }
        let defaultID = try? readUInt32(
            AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDefaultInputDevice
        )
        return AudioInputDeviceSnapshot(
            devices: devices,
            defaultInputDeviceUID: devices.first(where: { $0.deviceID == defaultID })?.uid
        )
    }

    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func readDeviceIDs() throws -> [AudioDeviceID] {
        var property = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        try check(AudioObjectGetPropertyDataSize(system, &property, 0, nil, &size))
        let stride = MemoryLayout<AudioDeviceID>.stride
        guard Int(size).isMultiple(of: stride) else { throw AudioInputDeviceError.invalidPropertyData }
        guard size > 0 else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / stride)
        try devices.withUnsafeMutableBytes { storage in
            try check(AudioObjectGetPropertyData(system, &property, 0, nil, &size, storage.baseAddress!))
        }
        return Array(devices.prefix(Int(size) / stride))
    }

    private static func readUInt32(
        _ object: AudioObjectID, selector: AudioObjectPropertySelector
    ) throws -> UInt32 {
        var property = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        try check(AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value))
        return value
    }

    private static func readString(
        _ object: AudioObjectID, selector: AudioObjectPropertySelector
    ) throws -> String {
        var property = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value)
        // Core Audio transfers ownership of these CFString properties to the caller.
        let string = value?.takeRetainedValue()
        try check(status)
        guard let string else { throw AudioInputDeviceError.invalidPropertyData }
        return string as String
    }

    private static func inputChannelCount(_ deviceID: AudioDeviceID) throws -> UInt32 {
        var property = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(deviceID, &property, 0, nil, &size))
        guard size > 0 else { return 0 }
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: max(Int(size), MemoryLayout<AudioBufferList>.size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }
        try check(AudioObjectGetPropertyData(deviceID, &property, 0, nil, &size, storage))
        let buffers = UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + $1.mNumberChannels }
    }

    private static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw AudioInputDeviceError.propertyReadFailed(status) }
    }
}
