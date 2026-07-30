import AppKit
import SwiftUI

/// Floating borderless `NSPanel` that hosts a SwiftUI view supplied by the caller.
/// A `Window` scene cannot give us non-activating + floats-above-all behavior, so we
/// manage the panel directly. Default position is centered horizontally, ~60pt above
/// the active screen's bottom edge; while the inline preview mirrors into the
/// fn-press field the panel instead anchors a compact chip beside that field.
@MainActor
public final class RecordingIndicatorController {
    private enum Presentation {
        case bottomCenter
        case fieldAnchored(CGRect)
    }

    private var panel: NSPanel?
    private var presentation: Presentation = .bottomCenter
    private let log = EposLogger(category: "indicator")

    private static let panelSize = CGSize(width: 360, height: 110)

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
        // Purely informational HUD — never intercept clicks meant for the app below.
        panel.ignoresMouseEvents = true

        let host = NSHostingView(rootView: content)
        host.frame = frame
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        self.panel = panel
    }

    /// Order the panel front in its current presentation (used by notice flashes,
    /// which must not move an anchored chip away from the field the user watched).
    public func show() {
        guard let panel else {
            log.error("show() called before attach(content:); ignoring")
            return
        }
        switch presentation {
        case .bottomCenter:
            repositionToActiveScreen(panel)
        case .fieldAnchored(let frame):
            panel.setFrame(frame, display: true)
        }
        panel.orderFrontRegardless()
    }

    /// Today's default presentation: the full pill, bottom-center on the active
    /// screen. Also the live restore path when the inline preview degrades.
    public func showBottomCenter() {
        presentation = .bottomCenter
        show()
    }

    /// Anchor the compact chip beside the live caret when the IME channel
    /// reported one, else beside the captured AX element when it is plausibly a
    /// discrete field. Returns false — leaving the current bottom-center
    /// presentation untouched — when neither anchor yields a usable placement.
    /// The AX fallback frame is an autoclosure so its bounded AX read only
    /// happens when the caret rect did not already decide the placement.
    public func anchorNearCaret(
        caretRect: CGRect?,
        fallbackAXFieldFrame: @autoclosure () -> CGRect?
    ) -> Bool {
        let screens = NSScreen.screens.map {
            RecordingIndicatorFieldAnchorPolicy.Screen(frame: $0.frame, visibleFrame: $0.visibleFrame)
        }
        let placement = RecordingIndicatorFieldAnchorPolicy.caretPlacement(
            caretRect: caretRect,
            screens: screens
        ) ?? RecordingIndicatorFieldAnchorPolicy.fieldPlacement(
            axFieldFrame: fallbackAXFieldFrame(),
            screens: screens
        )
        guard let placement else {
            log.info("caret/field anchor unavailable; keeping bottom-center pill")
            return false
        }
        presentation = .fieldAnchored(placement.panelFrame)
        show()
        return true
    }

    public func hide() {
        panel?.orderOut(nil)
    }

    private func repositionToActiveScreen(_ panel: NSPanel) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        let frame = RecordingIndicatorPlacementPolicy.bottomCenterFrame(
            in: visible,
            indicatorSize: Self.panelSize
        )
        panel.setFrame(frame, display: true)
    }
}

struct RecordingIndicatorPlacementPolicy {
    nonisolated static let fallbackBottomInset: CGFloat = 60

    nonisolated static func bottomCenterFrame(
        in visibleFrame: CGRect,
        indicatorSize: CGSize
    ) -> CGRect {
        let visibleFrame = visibleFrame.standardized
        let indicatorSize = CGSize(
            width: max(0, indicatorSize.width),
            height: max(0, indicatorSize.height)
        )
        let x = clamped(
            visibleFrame.midX - indicatorSize.width / 2,
            lower: visibleFrame.minX,
            upper: visibleFrame.maxX - indicatorSize.width
        )
        let y = clamped(
            visibleFrame.minY + fallbackBottomInset,
            lower: visibleFrame.minY,
            upper: visibleFrame.maxY - indicatorSize.height
        )
        return CGRect(origin: CGPoint(x: x, y: y), size: indicatorSize)
    }

    private nonisolated static func clamped(
        _ value: CGFloat,
        lower: CGFloat,
        upper: CGFloat
    ) -> CGFloat {
        guard upper >= lower else { return lower }
        return min(max(value, lower), upper)
    }
}
