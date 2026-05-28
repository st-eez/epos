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

    private static let panelSize = CGSize(width: 180, height: 90)

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
        let frame = RecordingIndicatorPlacementPolicy.frame(
            in: visible,
            indicatorSize: Self.panelSize,
            protectedRect: nil
        )
        panel.setFrame(frame, display: true)
    }
}

struct RecordingIndicatorPlacementPolicy {
    nonisolated static let clearance: CGFloat = 12
    nonisolated static let fallbackBottomInset: CGFloat = 60

    nonisolated static func frame(
        in visibleFrame: CGRect,
        indicatorSize: CGSize,
        protectedRect: CGRect?
    ) -> CGRect {
        let visibleFrame = visibleFrame.standardized
        let indicatorSize = CGSize(
            width: max(0, indicatorSize.width),
            height: max(0, indicatorSize.height)
        )

        guard let protectedRect = saneProtectedRect(protectedRect, in: visibleFrame) else {
            return fallbackFrame(in: visibleFrame, indicatorSize: indicatorSize)
        }

        return caretAdjacentFrame(
            in: visibleFrame,
            indicatorSize: indicatorSize,
            protectedRect: protectedRect
        ) ?? fallbackFrame(in: visibleFrame, indicatorSize: indicatorSize)
    }

    private nonisolated static func caretAdjacentFrame(
        in visibleFrame: CGRect,
        indicatorSize: CGSize,
        protectedRect: CGRect
    ) -> CGRect? {
        let centeredX = protectedRect.midX - indicatorSize.width / 2
        let x = clamped(centeredX, lower: visibleFrame.minX, upper: visibleFrame.maxX - indicatorSize.width)
        let expandedProtectedRect = protectedRect.insetBy(dx: -clearance, dy: -clearance)

        let below = CGRect(
            x: x,
            y: protectedRect.minY - clearance - indicatorSize.height,
            width: indicatorSize.width,
            height: indicatorSize.height
        )
        if isUsable(below, in: visibleFrame, avoiding: expandedProtectedRect) {
            return below
        }

        let above = CGRect(
            x: x,
            y: protectedRect.maxY + clearance,
            width: indicatorSize.width,
            height: indicatorSize.height
        )
        if isUsable(above, in: visibleFrame, avoiding: expandedProtectedRect) {
            return above
        }

        let y = clamped(
            protectedRect.midY - indicatorSize.height / 2,
            lower: visibleFrame.minY,
            upper: visibleFrame.maxY - indicatorSize.height
        )
        let right = CGRect(
            x: protectedRect.maxX + clearance,
            y: y,
            width: indicatorSize.width,
            height: indicatorSize.height
        )
        if isUsable(right, in: visibleFrame, avoiding: expandedProtectedRect) {
            return right
        }

        let left = CGRect(
            x: protectedRect.minX - clearance - indicatorSize.width,
            y: y,
            width: indicatorSize.width,
            height: indicatorSize.height
        )
        if isUsable(left, in: visibleFrame, avoiding: expandedProtectedRect) {
            return left
        }

        return nil
    }

    private nonisolated static func fallbackFrame(
        in visibleFrame: CGRect,
        indicatorSize: CGSize
    ) -> CGRect {
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

    private nonisolated static func saneProtectedRect(
        _ rect: CGRect?,
        in visibleFrame: CGRect
    ) -> CGRect? {
        guard let candidate = rect else { return nil }
        let rect = candidate.standardized
        guard rect.minX.isFinite,
              rect.minY.isFinite,
              rect.width.isFinite,
              rect.height.isFinite,
              rect.width >= 0,
              rect.height >= 8 else {
            return nil
        }
        guard rect.maxX >= visibleFrame.minX,
              rect.minX <= visibleFrame.maxX,
              rect.maxY >= visibleFrame.minY,
              rect.minY <= visibleFrame.maxY else {
            return nil
        }
        return rect
    }

    private nonisolated static func isUsable(
        _ frame: CGRect,
        in visibleFrame: CGRect,
        avoiding protectedRect: CGRect
    ) -> Bool {
        visibleFrame.contains(frame) && !frame.intersects(protectedRect)
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
