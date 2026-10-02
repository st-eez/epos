import AVFoundation
import Darwin
import Foundation

// This probe opens no capture, writes no preferences, and changes no HAL default.
// Keep the isolated engine allocated until the process ends, matching app ownership.
let engine = AVAudioEngine()
do {
    let before = try AudioInputDevices.snapshot()
    let defaultID = try before.deviceID(for: nil)
    precondition(!engine.isRunning)
    try AudioInputDeviceBinding.bind(defaultID, to: engine.inputNode)
    precondition(engine.inputNode.auAudioUnit.deviceID == defaultID)
    precondition(!engine.isRunning)
    let after = try AudioInputDevices.snapshot()
    precondition(before.defaultInputDeviceUID == after.defaultInputDeviceUID)
    let afterDefaultID = try after.deviceID(for: nil)
    precondition(defaultID == afterDefaultID)
    print("Input devices: \(before.devices.count). Native binding/readback passed. System default unchanged. Engine remained stopped.")
} catch {
    print("Native input verification unavailable: \(error)")
    exit(1)
}
