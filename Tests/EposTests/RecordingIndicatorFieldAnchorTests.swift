import XCTest
@testable import Epos

/// Pins the pure placement math for the compact field-anchored recording chip:
/// caret rects (Cocoa screen coordinates, primary anchor) and AX element frames
/// (top-left-origin fallback, discrete fields only) → Cocoa panel frames, with
/// the above/below flip and edge clamping.
final class RecordingIndicatorFieldAnchorTests: XCTestCase {
    private typealias Policy = RecordingIndicatorFieldAnchorPolicy

    /// 1440x900 primary; menu bar shaves the top of the visible frame.
    private let primary = Policy.Screen(
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: CGRect(x: 0, y: 4, width: 1440, height: 871)
    )

    // MARK: - Caret anchor (primary)

    func testCaretMidScreenPlacesChipAboveLeadingTheCaret() throws {
        let caret = CGRect(x: 600, y: 300, width: 1, height: 18)
        let placement = try XCTUnwrap(Policy.caretPlacement(caretRect: caret, screens: [primary]))

        XCTAssertFalse(placement.placedBelowAnchor)
        // The chip LEADS the caret — sitting where text is about to appear —
        // instead of trailing back over what was just typed.
        XCTAssertEqual(placement.chipFrame.minX, caret.maxX + Policy.caretGap, accuracy: 0.001)
        XCTAssertEqual(placement.chipFrame.minY, caret.maxY + Policy.clearance, accuracy: 0.001)
        XCTAssertEqual(placement.chipFrame.size, Policy.chipSize)
        XCTAssertFalse(placement.chipFrame.intersects(caret))
        XCTAssertTrue(primary.visibleFrame.contains(placement.chipFrame))
        XCTAssertEqual(
            placement.panelFrame.maxX,
            placement.chipFrame.maxX + Policy.chipTrailingInset,
            accuracy: 0.001
        )
        XCTAssertEqual(placement.panelFrame.midY, placement.chipFrame.midY, accuracy: 0.001)
        XCTAssertEqual(placement.panelFrame.size, Policy.panelSize)
    }

    func testCaretNearScreenTopFlipsChipBelowTheLine() throws {
        let caret = CGRect(x: 600, y: 850, width: 1, height: 18)
        let placement = try XCTUnwrap(Policy.caretPlacement(caretRect: caret, screens: [primary]))

        XCTAssertTrue(placement.placedBelowAnchor)
        XCTAssertEqual(placement.chipFrame.maxY, caret.minY - Policy.clearance, accuracy: 0.001)
        XCTAssertFalse(placement.chipFrame.intersects(caret))
        XCTAssertTrue(primary.visibleFrame.contains(placement.chipFrame))
    }

    func testCaretNearRightEdgeClampsChipToVisibleFrame() throws {
        let caret = CGRect(x: 1439.5, y: 300, width: 1, height: 18)
        let placement = try XCTUnwrap(Policy.caretPlacement(caretRect: caret, screens: [primary]))

        XCTAssertEqual(placement.chipFrame.maxX, primary.visibleFrame.maxX, accuracy: 0.001)
        XCTAssertTrue(primary.visibleFrame.contains(placement.chipFrame))
    }

    func testUnusableCaretRectsAreUnavailable() {
        XCTAssertNil(Policy.caretPlacement(caretRect: nil, screens: [primary]))
        XCTAssertNil(Policy.caretPlacement(caretRect: .zero, screens: [primary]))
        // Degenerate height (no real text line is 300pt or 2pt tall).
        XCTAssertNil(Policy.caretPlacement(
            caretRect: CGRect(x: 600, y: 300, width: 1, height: 300),
            screens: [primary]
        ))
        XCTAssertNil(Policy.caretPlacement(
            caretRect: CGRect(x: 600, y: 300, width: 1, height: 2),
            screens: [primary]
        ))
        XCTAssertNil(Policy.caretPlacement(
            caretRect: CGRect(x: CGFloat.nan, y: 300, width: 1, height: 18),
            screens: [primary]
        ))
        // A caret on no connected screen.
        XCTAssertNil(Policy.caretPlacement(
            caretRect: CGRect(x: 5000, y: 300, width: 1, height: 18),
            screens: [primary]
        ))
    }

    // MARK: - AX field anchor (fallback)

    func testFieldFullyVisiblePlacesChipAboveRightAligned() throws {
        // AX: 400pt down from the screen top, so the field's Cocoa top edge is
        // 900 - 400 = 500.
        let axField = CGRect(x: 400, y: 400, width: 500, height: 60)
        let placement = try XCTUnwrap(Policy.fieldPlacement(axFieldFrame: axField, screens: [primary]))

        XCTAssertFalse(placement.placedBelowAnchor)
        XCTAssertEqual(placement.chipFrame.maxX, 900, accuracy: 0.001)
        XCTAssertEqual(placement.chipFrame.minY, 500 + Policy.clearance, accuracy: 0.001)
        XCTAssertTrue(primary.visibleFrame.contains(placement.chipFrame))
    }

    func testFieldNearScreenTopFlipsChipBelow() throws {
        // 30pt from the AX top → Cocoa maxY 870, no room above within visible 875.
        let axField = CGRect(x: 400, y: 30, width: 500, height: 40)
        let placement = try XCTUnwrap(Policy.fieldPlacement(axFieldFrame: axField, screens: [primary]))

        XCTAssertTrue(placement.placedBelowAnchor)
        // Field Cocoa bottom edge = 900 - 70 = 830; chip sits clearance below.
        XCTAssertEqual(placement.chipFrame.maxY, 830 - Policy.clearance, accuracy: 0.001)
        XCTAssertTrue(primary.visibleFrame.contains(placement.chipFrame))
    }

    func testFieldPastRightEdgeClampsChipToVisibleFrame() throws {
        // Field extends 110pt beyond the right screen edge.
        let axField = CGRect(x: 1350, y: 400, width: 200, height: 40)
        let placement = try XCTUnwrap(Policy.fieldPlacement(axFieldFrame: axField, screens: [primary]))

        XCTAssertEqual(placement.chipFrame.maxX, primary.visibleFrame.maxX, accuracy: 0.001)
        XCTAssertTrue(primary.visibleFrame.contains(placement.chipFrame))
    }

    func testFieldOnSecondaryDisplayConvertsAndAnchorsThere() throws {
        let secondary = Policy.Screen(
            frame: CGRect(x: 1440, y: 100, width: 1512, height: 982),
            visibleFrame: CGRect(x: 1440, y: 100, width: 1512, height: 982)
        )
        // AX y is measured from the primary screen's top edge across displays.
        let axField = CGRect(x: 2000, y: 300, width: 400, height: 44)
        let placement = try XCTUnwrap(Policy.fieldPlacement(
            axFieldFrame: axField,
            screens: [primary, secondary]
        ))

        // Cocoa field top edge = 900 - 300 = 600 → chip above it, on the
        // secondary screen, right-aligned to x = 2400.
        XCTAssertEqual(placement.chipFrame.minY, 600 + Policy.clearance, accuracy: 0.001)
        XCTAssertEqual(placement.chipFrame.maxX, 2400, accuracy: 0.001)
        XCTAssertTrue(secondary.visibleFrame.contains(placement.chipFrame))
        XCTAssertFalse(placement.placedBelowAnchor)
    }

    /// A pane-sized element (terminal, editor surface) is not a discrete field:
    /// anchoring to its corner pins the chip to a screen corner.
    func testScreenSizedElementFramesAreRejectedDiscreteFieldsAccepted() {
        // 1200x600 on-screen = 57% of the 1440x871 visible area → rejected.
        XCTAssertNil(Policy.fieldPlacement(
            axFieldFrame: CGRect(x: 0, y: 100, width: 1200, height: 600),
            screens: [primary]
        ))
        // 1200x500 = 48% → accepted.
        XCTAssertNotNil(Policy.fieldPlacement(
            axFieldFrame: CGRect(x: 0, y: 100, width: 1200, height: 500),
            screens: [primary]
        ))
    }

    func testUnusableFieldFramesFallBackToNil() {
        XCTAssertNil(Policy.fieldPlacement(axFieldFrame: nil, screens: [primary]))
        XCTAssertNil(Policy.fieldPlacement(
            axFieldFrame: CGRect(x: 100, y: 100, width: 0, height: 0),
            screens: [primary]
        ))
        XCTAssertNil(Policy.fieldPlacement(
            axFieldFrame: CGRect(x: CGFloat.nan, y: 100, width: 300, height: 40),
            screens: [primary]
        ))
        // A frame on no connected screen (stale AX read after display unplug).
        XCTAssertNil(Policy.fieldPlacement(
            axFieldFrame: CGRect(x: 9000, y: 300, width: 300, height: 40),
            screens: [primary]
        ))
        XCTAssertNil(Policy.fieldPlacement(
            axFieldFrame: CGRect(x: 100, y: 100, width: 300, height: 40),
            screens: []
        ))
    }

    // MARK: - Damped tracking

    func testGlideThresholdIgnoresSmallMovesAndAcceptsLargeOnes() {
        let current = CGRect(x: 100, y: 100, width: 320, height: 64)
        // 23pt to the right: below threshold, no move.
        XCTAssertFalse(Policy.exceedsGlideThreshold(
            from: current,
            to: current.offsetBy(dx: 23, dy: 0)
        ))
        // 25pt to the right: glide.
        XCTAssertTrue(Policy.exceedsGlideThreshold(
            from: current,
            to: current.offsetBy(dx: 25, dy: 0)
        ))
        // A pure line-wrap (vertical) jump also glides.
        XCTAssertTrue(Policy.exceedsGlideThreshold(
            from: current,
            to: current.offsetBy(dx: 0, dy: -30)
        ))
        XCTAssertFalse(Policy.exceedsGlideThreshold(from: current, to: current))
    }

    func testCompactChipAlwaysSurfacesFinalizingAndNotices() {
        XCTAssertFalse(RecordingIndicatorSurface.compactShowsStatusText(
            state: .recording, showingNotice: false
        ))
        XCTAssertTrue(RecordingIndicatorSurface.compactShowsStatusText(
            state: .recording, showingNotice: true
        ))
        XCTAssertTrue(RecordingIndicatorSurface.compactShowsStatusText(
            state: .finalizing, showingNotice: false
        ))
        XCTAssertTrue(RecordingIndicatorSurface.compactShowsStatusText(
            state: .idle, showingNotice: true
        ))
    }

    // MARK: - Probe rect reply parsing

    func testParseCaretRectAcceptsTheProbeReplyShape() {
        XCTAssertEqual(
            InlinePreviewSession.parseCaretRect("ok rect 875.0 -160.0 1.0 16.0"),
            CGRect(x: 875, y: -160, width: 1, height: 16)
        )
        XCTAssertNil(InlinePreviewSession.parseCaretRect("err rect unavailable"))
        XCTAssertNil(InlinePreviewSession.parseCaretRect("ok rect 1.0 2.0 3.0"))
        XCTAssertNil(InlinePreviewSession.parseCaretRect("ok marked 5 styled=true"))
        XCTAssertNil(InlinePreviewSession.parseCaretRect("ok rect a b c d"))
    }
}
