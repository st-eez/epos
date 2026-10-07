import Carbon
import Foundation

func stringProperty(_ source: TISInputSource, _ key: CFString) -> String? {
    guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
    return Unmanaged<CFTypeRef>.fromOpaque(pointer).takeUnretainedValue() as? String
}

func boolProperty(_ source: TISInputSource, _ key: CFString) -> Bool {
    guard let pointer = TISGetInputSourceProperty(source, key) else { return false }
    return (Unmanaged<CFTypeRef>.fromOpaque(pointer).takeUnretainedValue() as? NSNumber)?.boolValue ?? false
}

let sourceID = "com.steez.inputmethod.EposProbe"
let sources = TISCreateInputSourceList([kTISPropertyInputSourceID as String: sourceID] as CFDictionary, true)?
    .takeRetainedValue() as? [TISInputSource] ?? []
var result: [String: Any] = ["registered": !sources.isEmpty]
if let source = sources.first {
    result["enabled"] = boolProperty(source, kTISPropertyInputSourceIsEnabled)
    result["selected"] = boolProperty(source, kTISPropertyInputSourceIsSelected)
}
if let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() {
    result["keyboard"] = stringProperty(source, kTISPropertyInputSourceID)
}
if let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() {
    result["layout"] = stringProperty(source, kTISPropertyInputSourceID)
}
let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
print(String(decoding: data, as: UTF8.self))
