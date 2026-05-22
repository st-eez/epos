import AppKit
import Foundation

/// Push-to-talk fn-key global hotkey.
/// Carbon's RegisterEventHotKey does not support fn-only, so we listen via NSEvent.
@MainActor
public final class FnHotkey {
    public var onPress: (() -> Void)?
    public var onRelease: (() -> Void)?

    private var monitor: Any?
    private var isDown = false

    public init() {}

    public func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let pressed = event.modifierFlags.contains(.function)
            Task { @MainActor [weak self] in
                self?.handle(pressed: pressed)
            }
        }
    }

    public func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        isDown = false
    }

    private func handle(pressed: Bool) {
        guard pressed != isDown else { return }
        isDown = pressed
        pressed ? onPress?() : onRelease?()
    }
}
