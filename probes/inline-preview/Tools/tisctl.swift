// Text Input Source query/registration helper used by install/uninstall.
// Run with: xcrun swift Tools/tisctl.swift <command> [args]
//   find <input-source-id>       exit 0 if present in the installed source list
//   register <bundle-path>       TISRegisterInputSource on the bundle
//   enable <input-source-id>     TISEnableInputSource
//   ready <input-source-id>      exit 0 if any matching keyboard method is ready
//   registered <input-source-id> exit 0 if a matching keyboard method is registered
//   list [substring]             print matching input source ids
//   current|layout               print the selected source or underlying layout id
//   select <input-source-id>     select an already enabled keyboard method
import Carbon
import Foundation

func stringProperty(_ source: TISInputSource, _ key: CFString) -> String? {
    guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
    return Unmanaged<CFTypeRef>.fromOpaque(raw).takeUnretainedValue() as? String
}

func boolProperty(_ source: TISInputSource, _ key: CFString) -> Bool {
    guard let raw = TISGetInputSourceProperty(source, key) else { return false }
    return (Unmanaged<CFTypeRef>.fromOpaque(raw).takeUnretainedValue() as? NSNumber)?.boolValue ?? false
}

func allSources() -> [TISInputSource] {
    TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource] ?? []
}

func source(matching identifier: String) -> TISInputSource? {
    allSources().first { stringProperty($0, kTISPropertyInputSourceID) == identifier }
}

func isKeyboardMethod(_ source: TISInputSource) -> Bool {
    stringProperty(source, kTISPropertyInputSourceCategory) == kTISCategoryKeyboardInputSource as String
        && stringProperty(source, kTISPropertyInputSourceType) == kTISTypeKeyboardInputMethodWithoutModes as String
}

func isReady(_ source: TISInputSource) -> Bool {
    isKeyboardMethod(source) && boolProperty(source, kTISPropertyInputSourceIsEnabled)
        && boolProperty(source, kTISPropertyInputSourceIsSelectCapable)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    FileHandle.standardError.write(Data("usage: tisctl.swift find|ready|registered|register|enable|list|current|layout|select [arg]\n".utf8))
    exit(64)
}

switch command {
case "current", "layout":
    let source = command == "current" ? TISCopyCurrentKeyboardInputSource() : TISCopyCurrentKeyboardLayoutInputSource()
    guard let source = source?.takeRetainedValue(),
          let identifier = stringProperty(source, kTISPropertyInputSourceID) else { exit(1) }
    print(identifier)

case "select":
    guard arguments.count > 1,
          let found = allSources().first(where: {
              stringProperty($0, kTISPropertyInputSourceID) == arguments[1] && isReady($0)
          }) else { exit(1) }
    exit(TISSelectInputSource(found) == noErr ? 0 : 1)

case "find":
    guard arguments.count > 1, let found = source(matching: arguments[1]) else { exit(1) }
    let category = stringProperty(found, kTISPropertyInputSourceCategory) ?? "?"
    let type = stringProperty(found, kTISPropertyInputSourceType) ?? "?"
    print("\(arguments[1]) category=\(category) type=\(type) "
        + "enabled=\(boolProperty(found, kTISPropertyInputSourceIsEnabled)) "
        + "selectable=\(boolProperty(found, kTISPropertyInputSourceIsSelectCapable))")
    exit(0)

case "register":
    guard arguments.count > 1 else { exit(64) }
    let url = URL(fileURLWithPath: arguments[1], isDirectory: true)
    let status = TISRegisterInputSource(url as CFURL)
    print("TISRegisterInputSource(\(url.lastPathComponent)) -> \(status)")
    exit(status == noErr ? 0 : 1)

case "ready", "registered":
    guard arguments.count > 1 else { exit(64) }
    let matches = allSources().filter { stringProperty($0, kTISPropertyInputSourceID) == arguments[1] }
    let ready = matches.contains(where: isReady)
    let registered = matches.contains(where: isKeyboardMethod)
    print("\(arguments[1]) matches=\(matches.count) registered=\(registered) ready=\(ready)")
    exit((command == "ready" ? ready : registered) ? 0 : 1)

case "enable":
    guard arguments.count > 1, let found = source(matching: arguments[1]) else { exit(1) }
    let status = TISEnableInputSource(found)
    print("TISEnableInputSource -> \(status)")
    exit(status == noErr ? 0 : 1)

case "list":
    let needle = arguments.count > 1 ? arguments[1] : ""
    for entry in allSources() {
        guard let identifier = stringProperty(entry, kTISPropertyInputSourceID) else { continue }
        if needle.isEmpty || identifier.localizedCaseInsensitiveContains(needle) {
            print(identifier)
        }
    }
    exit(0)

default:
    FileHandle.standardError.write(Data("error: unknown command \(command)\n".utf8))
    exit(64)
}
