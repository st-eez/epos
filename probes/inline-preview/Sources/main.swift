import AppKit
import InputMethodKit

let bundle = Bundle.main
guard let bundleIdentifier = bundle.bundleIdentifier,
      let connectionName = bundle.object(forInfoDictionaryKey: "InputMethodConnectionName") as? String else {
    ProbeLog.write("fatal: missing bundle identifier or InputMethodConnectionName")
    exit(1)
}

ProbeLog.write("launch pid=\(getpid()) bundle=\(bundleIdentifier) connection=\(connectionName)")

// Retained for process lifetime; IMKServer owns the client connections.
let server = IMKServer(name: connectionName, bundleIdentifier: bundleIdentifier)
if server == nil {
    ProbeLog.write("fatal: IMKServer init returned nil")
    exit(1)
}

ProbeCommandSocket.shared.start()

let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
application.run()
