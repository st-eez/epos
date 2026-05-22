import AppKit
import SwiftUI

/// Floating borderless `NSPanel` that hosts the SwiftUI `RecordingIndicator`.
/// A `Window` scene cannot give us non-activating + floats-above-all behavior, so we
/// manage the panel directly. Centered horizontally, sat ~60pt above the active screen's
/// bottom edge; position is fixed by design.
@MainActor
public final class RecordingIndicatorController {
    private let coordinator: AppCoordinator
    private var panel: NSPanel?

    private static let panelSize = CGSize(width: 420, height: 56)
    private static let bottomInset: CGFloat = 60

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    public func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        repositionToActiveScreen(panel)
        panel.orderFrontRegardless()
    }

    public func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let frame = NSRect(origin: .zero, size: Self.panelSize)
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true

        let host = NSHostingView(rootView: RecordingIndicator(coordinator: coordinator))
        host.frame = frame
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        return panel
    }

    private func repositionToActiveScreen(_ panel: NSPanel) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        let x = visible.midX - Self.panelSize.width / 2
        let y = visible.minY + Self.bottomInset
        panel.setFrame(NSRect(origin: CGPoint(x: x, y: y), size: Self.panelSize), display: true)
    }
}
