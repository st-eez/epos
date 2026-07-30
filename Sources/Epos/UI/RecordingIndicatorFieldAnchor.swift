import Foundation

/// Pure placement math for the compact, field-anchored recording chip shown while
/// the inline preview mirrors the transcript into the fn-press field. Converts the
/// captured AX element frame (top-left-origin global coordinates) into a Cocoa
/// panel frame beside the field. Returning nil means "anchor unavailable" and the
/// caller keeps today's bottom-center pill.
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
        let placedBelowField: Bool
    }

    /// Fixed compact-chip metrics shared by the SwiftUI layout and the panel
    /// placement so the on-screen chip lands where the math says it does. The
    /// chip hugs the panel's trailing edge; height is constant (meter + padding),
    /// width is the widest compact state ("Not inserted" notice).
    nonisolated static let chipSize = CGSize(width: 200, height: 32)
    nonisolated static let chipTrailingInset: CGFloat = 16
    nonisolated static let panelSize = CGSize(width: 320, height: 64)
    nonisolated static let clearance: CGFloat = 8

    /// The compact chip is shown only while the inline preview is the visible
    /// transcript surface AND the chip could be anchored beside the field.
    nonisolated static func isCompact(mirroring: Bool, anchored: Bool) -> Bool {
        mirroring && anchored
    }

    /// Places the chip just above the field's top edge, right-aligned to the
    /// field's right edge, clamped to the field's screen visible frame. A field
    /// too close to the screen top flips the chip below the field instead. The
    /// chip never overlaps the field's interior.
    nonisolated static func placement(
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
        guard !anchor.isNull, anchor.width >= 4, anchor.height >= 4,
              visible.width >= chipSize.width, visible.height >= chipSize.height else {
            return nil
        }

        let chipMaxX = min(max(anchor.maxX, visible.minX + chipSize.width), visible.maxX)
        let aboveY = anchor.maxY + clearance
        let belowY = anchor.minY - clearance - chipSize.height
        let chipY: CGFloat
        let placedBelowField: Bool
        if aboveY + chipSize.height <= visible.maxY {
            chipY = aboveY
            placedBelowField = false
        } else if belowY >= visible.minY {
            chipY = belowY
            placedBelowField = true
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
            placedBelowField: placedBelowField
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
        _ field: CGRect,
        in screens: [Screen]
    ) -> Screen? {
        let best = screens.max { lhs, rhs in
            overlapArea(field, lhs.frame) < overlapArea(field, rhs.frame)
        }
        guard let best, overlapArea(field, best.frame) > 0 else { return nil }
        return best
    }

    private nonisolated static func overlapArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }
}
