import AppKit
import SwiftUI

/// Floating borderless `NSPanel` that hosts a SwiftUI view supplied by the caller.
/// A `Window` scene cannot give us non-activating + floats-above-all behavior, so we
/// manage the panel directly. Centered horizontally, sat ~60pt above the active screen's
/// bottom edge; position is fixed by design.
@MainActor
public final class RecordingIndicatorController {
    private var panel: NSPanel?
    private let log = EposLogger(category: "indicator")

    private static let panelSize = CGSize(width: 700, height: 150)
    private static let bottomInset: CGFloat = 60

    public init() {}

    /// Build the floating panel and host the supplied SwiftUI content. Idempotent —
    /// subsequent calls are no-ops; the first content sticks.
    public func attach<Content: View>(content: Content) {
        guard panel == nil else { return }
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
        panel.hasShadow = false

        let host = NSHostingView(rootView: content)
        host.frame = frame
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        self.panel = panel
    }

    public func show() {
        guard let panel else {
            log.error("show() called before attach(content:); ignoring")
            return
        }
        repositionToActiveScreen(panel)
        panel.orderFrontRegardless()
    }

    public func hide() {
        panel?.orderOut(nil)
    }

    private func repositionToActiveScreen(_ panel: NSPanel) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        let x = visible.midX - Self.panelSize.width / 2
        let y = visible.minY + Self.bottomInset
        panel.setFrame(NSRect(origin: CGPoint(x: x, y: y), size: Self.panelSize), display: true)
    }
}
