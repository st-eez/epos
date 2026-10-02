import AVFoundation
import Darwin
import Foundation

// This probe opens no capture, writes no preferences, and changes no HAL default.
// Keep the isolated engine allocated until the process ends, matching app ownership.
let engine = AVAudioEngine()

enum InputProbeFailure: Error {
    case activeIO
    case changedSystemDefault
    case setterNotExercised
    case mismatchedNodeReadback
}

func checkStoppedIO() throws {
    let node = engine.inputNode
    let unit = node.auAudioUnit
    guard !engine.isRunning, !unit.isRunning, !unit.renderResourcesAllocated,
          !node.isVoiceProcessingEnabled else { throw InputProbeFailure.activeIO }
}

func checkSystemDefault(_ before: AudioInputDeviceSnapshot, defaultID: AudioDeviceID) throws {
    let after = try AudioInputDevices.snapshot()
    let afterDefaultID = try after.deviceID(for: nil)
    guard before.defaultInputDeviceUID == after.defaultInputDeviceUID,
          defaultID == afterDefaultID else { throw InputProbeFailure.changedSystemDefault }
}

func verifyInputBinding() throws {
    let before = try AudioInputDevices.snapshot()
    let defaultID = try before.deviceID(for: nil)
    let originalID = engine.inputNode.auAudioUnit.deviceID
    try checkStoppedIO()
    defer {
        do {
            try AudioInputDeviceBinding.bind(originalID, to: engine.inputNode)
            try checkStoppedIO()
            try checkSystemDefault(before, defaultID: defaultID)
            print("Original route restored. System default unchanged. Engine and unit stayed stopped, render resources unallocated, voice processing off.")
        } catch {
            print("Isolated-engine route restoration failed. Error code: \((error as NSError).code).")
            exit(2)
        }
    }
    try AudioInputDeviceBinding.bind(defaultID, to: engine.inputNode)
    try checkStoppedIO()
    try checkSystemDefault(before, defaultID: defaultID)
    print("Input devices: \(before.devices.count). Current-default binding/readback passed.")

    guard let alternate = before.devices.first(where: { $0.deviceID != defaultID }) else {
        print("Alternate input check skipped. No other available input.")
        return
    }
    let unit = engine.inputNode.auAudioUnit
    var setterCalls = 0
    try AudioInputDeviceBinding.bind(
        alternate.deviceID,
        currentDeviceID: unit.deviceID,
        setDevice: {
            setterCalls += 1
            try unit.setDeviceID($0)
        },
        readDevice: { unit.deviceID }
    )
    guard setterCalls == 1 else { throw InputProbeFailure.setterNotExercised }
    guard engine.inputNode.auAudioUnit.deviceID == alternate.deviceID else {
        throw InputProbeFailure.mismatchedNodeReadback
    }
    try checkStoppedIO()
    try checkSystemDefault(before, defaultID: defaultID)
    print("Alternate input binding/readback passed. Native setter calls: \(setterCalls).")
}

do {
    try verifyInputBinding()
} catch {
    if let check = error as? InputProbeFailure {
        print("Native input verification failed: \(check).")
    } else {
        print("Native input verification failed. Error code: \((error as NSError).code).")
    }
    exit(1)
}
