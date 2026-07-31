import Foundation

/// Pure placement math for the caret mic badge — the small round indicator
/// shown at the insertion point while dictation is live but no text is
/// streaming (before the first word, and during silences), the way native
/// dictation places its mic bubble. Caret rects arrive from the IME probe in
/// Cocoa screen coordinates (bottom-left origin, global across displays, no
/// flip). Returning nil means "no usable anchor"; the caller falls back to
/// the bottom-center pill.
enum RecordingCaretBadgePolicy {
    struct Screen: Equatable {
        let frame: CGRect
        let visibleFrame: CGRect

        init(frame: CGRect, visibleFrame: CGRect) {
            self.frame = frame
            self.visibleFrame = visibleFrame
        }
    }

    /// Panel edge; the SwiftUI badge circle fills it minus `badgeInset` per
    /// side, leaving room for its soft shadow.
    nonisolated static let panelEdge: CGFloat = 40
    nonisolated static let badgeInset: CGFloat = 4
    /// Vertical gap between the caret line and the badge edge.
    nonisolated static let clearance: CGFloat = 5

    /// Centers the badge on the caret's x, hanging just below the caret line
    /// (native dictation's position), flipping above when the screen bottom is
    /// too close, clamped into the caret's screen visible frame.
    nonisolated static func panelFrame(
        caretRect: CGRect?,
        screens: [Screen]
    ) -> CGRect? {
        guard let caretRect else { return nil }
        let caret = caretRect.standardized
        guard caret.minX.isFinite, caret.minY.isFinite,
              caret.width.isFinite, caret.height.isFinite,
              caret.height >= 4, caret.height <= 200 else {
            return nil
        }
        guard let screen = screenContaining(caret, in: screens) else { return nil }
        let visible = screen.visibleFrame.standardized
        guard visible.width >= panelEdge, visible.height >= panelEdge else { return nil }

        let x = min(
            max(caret.midX - panelEdge / 2, visible.minX),
            visible.maxX - panelEdge
        )
        let belowY = caret.minY - clearance - panelEdge
        let aboveY = caret.maxY + clearance
        let y: CGFloat
        if belowY >= visible.minY {
            y = belowY
        } else if aboveY + panelEdge <= visible.maxY {
            y = aboveY
        } else {
            return nil
        }
        return CGRect(x: x, y: y, width: panelEdge, height: panelEdge)
    }

    private nonisolated static func screenContaining(
        _ anchor: CGRect,
        in screens: [Screen]
    ) -> Screen? {
        let best = screens.max { lhs, rhs in
            overlapArea(anchor, lhs.frame) < overlapArea(anchor, rhs.frame)
        }
        guard let best, overlapArea(anchor, best.frame) > 0 else { return nil }
        return best
    }

    private nonisolated static func overlapArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }
}
