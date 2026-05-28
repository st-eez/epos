import AppKit
import InputMethodKit

@MainActor
private final class EposInputMethodApplication {
    private let server: IMKServer
    private let nativeMessageServer = EposNativeMessageServer(
        commitText: { text in EposInputController.commitExternalText(text) },
        updateMarkedText: { text in EposInputController.updateExternalMarkedText(text) },
        cancelMarkedText: { EposInputController.cancelExternalMarkedText() }
    )

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
        nativeMessageServer.start()
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
