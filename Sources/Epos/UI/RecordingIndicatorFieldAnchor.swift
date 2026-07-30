import Foundation

/// Pure placement math for the compact, field-anchored recording chip shown while
/// the inline preview mirrors the transcript into the fn-press field. The primary
/// anchor is the caret-line rectangle the IME probe reads from the pinned client
/// (how native dictation and candidate windows position); the captured AX element
/// frame is the fallback, and only when it is plausibly a discrete field.
/// Returning nil means "anchor unavailable" and the caller keeps today's
/// bottom-center pill.
enum RecordingIndicatorFieldAnchorPolicy {
    struct Screen: Equatable {
        let frame: CGRect
        let visibleFrame: CGRect

        init(frame: CGRect, visibleFrame: CGRect) {
            self.frame = frame
            self.visibleFrame = visibleFrame
        }
    }

    struct Placement: Equatable {
        /// Where the visible chip's trailing edge and vertical span land.
        let chipFrame: CGRect
        /// The NSPanel frame that puts the trailing-aligned, vertically centered
        /// chip content exactly at `chipFrame`.
        let panelFrame: CGRect
        let placedBelowAnchor: Bool
    }

    /// Fixed compact-chip metrics shared by the SwiftUI layout and the panel
    /// placement so the on-screen chip lands where the math says it does. The
    /// chip hugs the panel's trailing edge; height is constant (meter + padding),
    /// width is the widest compact state ("Not inserted" notice).
    nonisolated static let chipSize = CGSize(width: 200, height: 32)
    nonisolated static let chipTrailingInset: CGFloat = 16
    nonisolated static let panelSize = CGSize(width: 320, height: 64)
    nonisolated static let clearance: CGFloat = 8
    /// Horizontal gap between the caret and the chip's leading edge. The chip
    /// leads the insertion point — sitting where text is about to appear, like
    /// the native dictation mic — instead of trailing back over what was just
    /// typed (which parked it at the pane's left edge on a fresh prompt).
    nonisolated static let caretGap: CGFloat = 6
    /// An AX element frame covering more than this fraction of its screen's
    /// visible area is not a discrete field (terminal panes, editor surfaces,
    /// whole Electron windows) — anchoring to its top-right corner would pin the
    /// chip to a screen corner, so such frames are rejected.
    nonisolated static let maxFieldFractionOfScreen: CGFloat = 0.5
    /// Minimum movement (either axis) before an anchored chip repositions.
    /// Smaller deltas are ignored so the chip glides occasionally as dictation
    /// flows instead of jittering with every word.
    nonisolated static let glideThreshold: CGFloat = 24

    nonisolated static func exceedsGlideThreshold(from current: CGRect, to proposed: CGRect) -> Bool {
        max(abs(proposed.midX - current.midX), abs(proposed.midY - current.midY)) > glideThreshold
    }

    /// Primary anchor: the caret-line rectangle from the IME channel. IMK's
    /// `attributesForCharacterIndex:lineHeightRectangle:` reports Cocoa screen
    /// coordinates — bottom-left origin, global across displays, NO flip
    /// (verified empirically: a TextEdit caret on a display arranged below the
    /// primary reported y = -160 inside that window's Cocoa span; a top-left
    /// reading would have placed it above the primary where no display exists).
    /// The chip sits clearance above the caret line and LEADS it: its leading
    /// edge starts `caretGap` right of the caret, where text is about to
    /// appear, clamped to the caret's screen; a caret too close to the screen
    /// top flips the chip below the line. The caret line itself is never
    /// covered.
    nonisolated static func caretPlacement(
        caretRect: CGRect?,
        screens: [Screen]
    ) -> Placement? {
        guard let caretRect else { return nil }
        let caret = caretRect.standardized
        guard caret.minX.isFinite, caret.minY.isFinite,
              caret.width.isFinite, caret.height.isFinite,
              caret.height >= 4, caret.height <= 200 else {
            return nil
        }
        guard let screen = screenContaining(caret, in: screens) else { return nil }
        return chipPlacement(
            anchor: caret,
            visible: screen.visibleFrame.standardized,
            alignment: .leadingCaret
        )
    }

    /// Fallback anchor: the captured AX element frame (top-left-origin global
    /// coordinates, flipped about the primary screen's top edge), accepted only
    /// for plausibly discrete fields. The chip goes just above the field's top
    /// edge, right-aligned to its right edge, clamped to the field's screen
    /// visible frame, flipping below when there is no room above.
    nonisolated static func fieldPlacement(
        axFieldFrame: CGRect?,
        screens: [Screen]
    ) -> Placement? {
        guard let field = cocoaFieldRect(axFieldFrame: axFieldFrame, screens: screens),
              let screen = screenContaining(field, in: screens) else {
            return nil
        }
        let visible = screen.visibleFrame.standardized
        // Anchor to the on-screen part of the field so a field that runs past a
        // screen edge still gets a visible, non-overlapping chip.
        let anchor = field.intersection(visible)
        guard !anchor.isNull, anchor.width >= 4, anchor.height >= 4 else { return nil }
        guard anchor.width * anchor.height
                <= maxFieldFractionOfScreen * visible.width * visible.height else {
            return nil
        }
        return chipPlacement(anchor: anchor, visible: visible, alignment: .trailingField)
    }

    private enum ChipAlignment {
        /// Chip leads the caret: leading edge `caretGap` right of the anchor.
        case leadingCaret
        /// Chip trails a discrete field: trailing edge at the field's right edge.
        case trailingField
    }

    /// Shared core: horizontal alignment per anchor kind, clearance above the
    /// anchor, flip below when the screen top is too close, clamp horizontally
    /// into the visible frame.
    private nonisolated static func chipPlacement(
        anchor: CGRect,
        visible: CGRect,
        alignment: ChipAlignment
    ) -> Placement? {
        guard visible.width >= chipSize.width, visible.height >= chipSize.height else {
            return nil
        }
        let chipMaxX: CGFloat
        switch alignment {
        case .leadingCaret:
            let leadingX = anchor.maxX + caretGap
            chipMaxX = min(
                max(leadingX + chipSize.width, visible.minX + chipSize.width),
                visible.maxX
            )
        case .trailingField:
            chipMaxX = min(max(anchor.maxX, visible.minX + chipSize.width), visible.maxX)
        }
        let aboveY = anchor.maxY + clearance
        let belowY = anchor.minY - clearance - chipSize.height
        let chipY: CGFloat
        let placedBelowAnchor: Bool
        if aboveY + chipSize.height <= visible.maxY {
            chipY = aboveY
            placedBelowAnchor = false
        } else if belowY >= visible.minY {
            chipY = belowY
            placedBelowAnchor = true
        } else {
            return nil
        }

        let chipFrame = CGRect(
            x: chipMaxX - chipSize.width,
            y: chipY,
            width: chipSize.width,
            height: chipSize.height
        )
        let panelFrame = CGRect(
            x: chipFrame.maxX + chipTrailingInset - panelSize.width,
            y: chipFrame.midY - panelSize.height / 2,
            width: panelSize.width,
            height: panelSize.height
        )
        return Placement(
            chipFrame: chipFrame,
            panelFrame: panelFrame,
            placedBelowAnchor: placedBelowAnchor
        )
    }

    /// AX frames use top-left-origin coordinates spanning all displays; Cocoa
    /// flips y about the primary screen's top edge (the screen whose Cocoa frame
    /// origin is zero).
    private nonisolated static func cocoaFieldRect(
        axFieldFrame: CGRect?,
        screens: [Screen]
    ) -> CGRect? {
        guard let axFieldFrame, let first = screens.first else { return nil }
        let field = axFieldFrame.standardized
        guard field.minX.isFinite, field.minY.isFinite,
              field.width.isFinite, field.height.isFinite,
              field.width >= 4, field.height >= 8 else {
            return nil
        }
        let primary = screens.first(where: { $0.frame.origin == .zero }) ?? first
        return CGRect(
            x: field.minX,
            y: primary.frame.maxY - field.maxY,
            width: field.width,
            height: field.height
        )
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
