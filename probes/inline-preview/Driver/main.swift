import Carbon
import Foundation

let inputSourceID = ProcessInfo.processInfo.environment["EPOS_PROBE_SOURCE_ID"] ?? "com.steez.inputmethod.EposProbe"

struct Options {
    var doCommitPass = true
    var doCancelPass = true
    var select = true
    var deselect = false
    var statusOnly = false
    var words = ["marked", "text", "probe", "streaming"]
    var stepSeconds = 0.75
    var settleSeconds = 1.5
    /// Bundle id the passes are pinned to. "any" accepts whatever has focus when
    /// the countdown ends; a real id refuses to write anywhere else.
    var target = "any"
    var focusDelaySeconds = 4.0
    /// Pause with the full marked text still uncommitted, so preedit rendering
    /// can be eyeballed or screenshotted before commit/cancel.
    var holdSeconds = 0.0
    /// Plain-string marked text, to compare against the underlined attributed run.
    var plainMarkedText = false
}

func parseOptions() -> Options {
    var options = Options()
    var arguments = Array(CommandLine.arguments.dropFirst())
    while let argument = arguments.first {
        arguments.removeFirst()
        switch argument {
        case "--commit-only": options.doCancelPass = false
        case "--cancel-only": options.doCommitPass = false
        case "--no-select": options.select = false
        case "--deselect": options.deselect = true
        case "--status": options.statusOnly = true
        case "--step":
            options.stepSeconds = Double(arguments.removeFirst()) ?? options.stepSeconds
        case "--target":
            options.target = arguments.removeFirst()
        case "--focus-delay":
            options.focusDelaySeconds = Double(arguments.removeFirst()) ?? options.focusDelaySeconds
        case "--hold":
            options.holdSeconds = Double(arguments.removeFirst()) ?? options.holdSeconds
        case "--plain":
            options.plainMarkedText = true
        case "--words":
            options.words = arguments.removeFirst().split(separator: " ").map(String.init)
        case "-h", "--help":
            print("""
            usage: run-stream [--commit-only|--cancel-only] [--no-select] [--deselect]
                              [--status] [--step SECONDS] [--words "a b c"]
                              [--target BUNDLE_ID] [--focus-delay SECONDS]
                              [--hold SECONDS] [--plain]

            Each pass pins itself to the app focused when the countdown ends and
            refuses to write anywhere else. --target asserts that app up front.
            The previous keyboard source is restored after the run unless the
            user changes it. --no-select never changes keyboard sources.
            """)
            exit(0)
        default:
            FileHandle.standardError.write(Data("error: unknown argument \(argument)\n".utf8))
            exit(64)
        }
    }
    return options
}

// MARK: - Text Input Sources

func stringProperty(_ source: TISInputSource, _ key: CFString) -> String? {
    guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
    return (Unmanaged<CFTypeRef>.fromOpaque(raw).takeUnretainedValue() as? String)
}

func boolProperty(_ source: TISInputSource, _ key: CFString) -> Bool {
    guard let raw = TISGetInputSourceProperty(source, key) else { return false }
    return (Unmanaged<CFTypeRef>.fromOpaque(raw).takeUnretainedValue() as? NSNumber)?.boolValue ?? false
}

func findSource(_ identifier: String) -> TISInputSource? {
    let filter = [kTISPropertyInputSourceID as String: identifier] as CFDictionary
    let sources = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource]
    return sources?.first
}

func describeSource(_ source: TISInputSource) -> String {
    let category = stringProperty(source, kTISPropertyInputSourceCategory) ?? "?"
    let type = stringProperty(source, kTISPropertyInputSourceType) ?? "?"
    return "category=\(category) type=\(type) enabled=\(boolProperty(source, kTISPropertyInputSourceIsEnabled)) "
        + "selectable=\(boolProperty(source, kTISPropertyInputSourceIsSelectCapable)) "
        + "selected=\(boolProperty(source, kTISPropertyInputSourceIsSelected))"
}

// MARK: - Command socket

final class CommandClient {
    private let descriptor: Int32

    init?(path: String) {
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        // A departed companion must return through source restoration, rather
        // than terminating on SIGPIPE or leaving a blocked reply read behind.
        var suppressPipeSignal: Int32 = 1
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &suppressPipeSignal,
                         socklen_t(MemoryLayout<Int32>.size)) == 0,
              setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                         socklen_t(MemoryLayout<timeval>.size)) == 0,
              setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout,
                         socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            close(descriptor)
            return nil
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(descriptor)
            return nil
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            close(descriptor)
            return nil
        }
    }

    deinit { close(descriptor) }

    func send(_ command: String) -> String {
        let line = command + "\n"
        _ = line.withCString { write(descriptor, $0, strlen($0)) }
        var buffer = [UInt8](repeating: 0, count: 4096)
        var accumulated: [UInt8] = []
        while !accumulated.contains(0x0A) {
            let count = read(descriptor, &buffer, buffer.count)
            if count <= 0 { break }
            accumulated.append(contentsOf: buffer[0..<count])
        }
        return String(decoding: accumulated, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

func connectWithRetry(timeout: TimeInterval) -> CommandClient? {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let client = CommandClient(path: ProbePaths.socketPath) { return client }
        Thread.sleep(forTimeInterval: 0.2)
    }
    return nil
}

// MARK: - Run

let options = parseOptions()

struct KeyboardAcquisition {
    let previousSource: TISInputSource
    let previousIdentifier: String
    let argument: String

    init?() {
        guard let previous = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let previousID = stringProperty(previous, kTISPropertyInputSourceID),
              previousID != inputSourceID,
              let layout = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutID = stringProperty(layout, kTISPropertyInputSourceID) else { return nil }
        let kind = stringProperty(previous, kTISPropertyInputSourceType) == kTISTypeKeyboardLayout as String
            ? "acquire-layout" : "acquire-method"
        previousSource = previous
        previousIdentifier = previousID
        argument = "\(kind) \(previousID) \(layoutID)"
    }

    func select(_ source: TISInputSource) -> Bool {
        let current = currentIdentifier()
        if current == inputSourceID { return true }
        guard current == previousIdentifier else {
            print("FAIL keyboard source changed during the run; preserving the user's choice")
            return false
        }
        let result = TISSelectInputSource(source)
        print("TISSelectInputSource -> \(result)")
        return result == noErr && currentIdentifier() == inputSourceID
    }

    func restore() {
        guard currentIdentifier() == inputSourceID else { return }
        let result = TISSelectInputSource(previousSource)
        print("restore keyboard source -> \(result)")
    }

    private func currentIdentifier() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return stringProperty(source, kTISPropertyInputSourceID)
    }
}

func waitForFocus() {
    guard options.focusDelaySeconds > 0 else { return }
    print("focus the target field now (\(Int(options.focusDelaySeconds))s)...")
    Thread.sleep(forTimeInterval: options.focusDelaySeconds)
}

/// Returns false when the pass was refused, so a focus mismatch aborts loudly
/// instead of typing into an unrelated app.
func streamPass(client: CommandClient, acquisition: KeyboardAcquisition?, finish: String) -> Bool {
    // Selecting the input source tears down and rebuilds client sessions, so the
    // target's session can take several seconds to appear after focus lands.
    var began = ""
    let deadline = Date().addingTimeInterval(20)
    repeat {
        let argument = acquisition.map { " \($0.argument)" } ?? ""
        began = client.send("begin \(options.target)\(argument)")
        if began.hasPrefix("ok") { break }
        if began != "err input method activation pending" { break }
        Thread.sleep(forTimeInterval: 0.5)
    } while Date() < deadline
    print("  begin -> \(began)")
    guard began.hasPrefix("ok") else { return false }
    var ended = false
    defer {
        if !ended { print("  end -> \(client.send("end"))") }
    }

    let markVerb = options.plainMarkedText ? "markplain" : "mark"
    var spoken: [String] = []
    for word in options.words {
        spoken.append(word)
        let text = spoken.joined(separator: " ")
        let response = client.send("\(markVerb) \(text)")
        print("  mark \"\(text)\" -> \(response)")
        if !response.hasPrefix("ok") {
            _ = client.send("cancel")
            return false
        }
        Thread.sleep(forTimeInterval: options.stepSeconds)
    }
    if options.holdSeconds > 0 {
        print("  holding marked text for \(options.holdSeconds)s")
        Thread.sleep(forTimeInterval: options.holdSeconds)
    }
    let finished = client.send(finish)
    print("  \(finish) -> \(finished)")
    guard finished.hasPrefix("ok") else {
        // A missing commit acknowledgement can follow a successful insertion.
        // Only a confirmed refusal permits another composition command.
        if finish == "commit", finished.hasPrefix("err") { _ = client.send("cancel") }
        return false
    }
    let end = client.send("end")
    ended = true
    print("  end -> \(end)")
    return end.hasPrefix("ok")
}

func run() -> Int32 {
    guard let source = findSource(inputSourceID) else {
        print("FAIL input source not registered: \(inputSourceID)")
        print("     run ./install first")
        return 1
    }
    print("source \(inputSourceID) \(describeSource(source))")

    var acquisition: KeyboardAcquisition?
    if options.select {
        guard boolProperty(source, kTISPropertyInputSourceIsEnabled),
              stringProperty(source, kTISPropertyInputSourceType)
                == kTISTypeKeyboardInputMethodWithoutModes as String else {
            print("FAIL an enabled keyboard input method is required; enable the installed companion first")
            return 1
        }
        guard let saved = KeyboardAcquisition() else {
            print("FAIL could not capture the previous keyboard source and layout; select a normal source first")
            return 1
        }
        acquisition = saved
    }
    // Returning before exit runs this cleanup even on connection or pass failure.
    defer { acquisition?.restore() }
    if let acquisition, !acquisition.select(source) { return 1 }

    guard let client = connectWithRetry(timeout: 8) else {
        print("FAIL could not connect to \(ProbePaths.socketPath)")
        print("     the input method process may not have been launched by the system")
        return 1
    }
    print("connected \(ProbePaths.socketPath)")
    let ping = client.send("ping")
    print("ping -> \(ping)")
    guard ping == "pong" else { return 1 }
    print("status -> \(client.send("status"))")
    if options.statusOnly { return 0 }

    for (label, finish) in [("pass 1: stream then commit", "commit"),
                            ("pass 2: stream then cancel (field must end unchanged)", "cancel")] {
        guard finish == "commit" ? options.doCommitPass : options.doCancelPass else { continue }
        // The companion restores the previous source at end, so each pass borrows it anew.
        if let acquisition, !acquisition.select(source) { return 1 }
        print(label)
        waitForFocus()
        guard streamPass(client: client, acquisition: acquisition, finish: finish) else { return 1 }
        Thread.sleep(forTimeInterval: options.settleSeconds)
    }
    print("final status -> \(client.send("status"))")
    if options.deselect {
        print("--deselect: borrowed sources are restored automatically; --no-select leaves sources untouched")
    }
    print("done")
    return 0
}

exit(run())
