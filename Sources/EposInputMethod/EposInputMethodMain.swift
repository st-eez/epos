import AppKit
import InputMethodKit

@MainActor
private final class EposInputMethodApplication {
    private let server: IMKServer

    init() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            fatalError("Unable to initialize Epos input method server")
        }
        let connectionName = "\(bundleIdentifier)_Connection"
        guard let server = IMKServer(name: connectionName, bundleIdentifier: bundleIdentifier) else {
            fatalError("Unable to initialize Epos input method server")
        }
        self.server = server
    }

    func run() -> Never {
        NSApplication.shared.setActivationPolicy(.accessory)
        withExtendedLifetime(server) {
            NSApplication.shared.run()
        }
        fatalError("Input method server exited unexpectedly")
    }
}

@main
private enum EposInputMethodMain {
    static func main() {
        EposInputMethodApplication().run()
    }
}
