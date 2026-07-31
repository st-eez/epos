import AppKit
import SwiftUI

/// Floating borderless `NSPanel` that hosts a SwiftUI view supplied by the caller.
/// A `Window` scene cannot give us non-activating + floats-above-all behavior, so we
/// manage the panel directly. Position is centered horizontally, ~60pt above the
/// active screen's bottom edge.
@MainActor
public final class RecordingIndicatorController {
    private var panel: NSPanel?
    private let log = EposLogger(category: "indicator")
    /// Bumped on every show/hide so a hide fade that finishes after a newer
    /// show can never order out the re-shown panel.
    private var visibilityGeneration = 0

    private static let panelSize = CGSize(width: 360, height: 110)
    private static let showFadeDuration: TimeInterval = 0.12
    private static let hideFadeDuration: TimeInterval = 0.18

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

    /// Reposition to the active screen's bottom-center, order front, and fade
    /// in. Also the live restore path when the inline preview degrades
    /// mid-recording and for the failure notice flashes. A show landing during
    /// a hide fade reclaims the panel from whatever alpha the fade reached.
    public func show() {
        guard let panel else {
            log.error("show() called before attach(content:); ignoring")
            return
        }
        visibilityGeneration += 1
        repositionToActiveScreen(panel)
        if !panel.isVisible { panel.alphaValue = 0 }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.showFadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    /// Fade out, then order out — the pill yields to the text that just landed
    /// in the field instead of blinking off.
    public func hide() {
        guard let panel, panel.isVisible else { return }
        visibilityGeneration += 1
        let generation = visibilityGeneration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.hideFadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self, self.visibilityGeneration == generation else { return }
            panel.orderOut(nil)
        }
    }

    private func repositionToActiveScreen(_ panel: NSPanel) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        let frame = RecordingIndicatorPlacementPolicy.bottomCenterFrame(
            in: visible,
            indicatorSize: Self.panelSize
        )
        panel.setFrame(frame, display: false)
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
