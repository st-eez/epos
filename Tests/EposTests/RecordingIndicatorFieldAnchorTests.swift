import XCTest
@testable import Epos

/// Pins the pure placement math for the compact field-anchored recording chip:
/// AX top-left-origin field frames → Cocoa panel frames, per screen, with the
/// above-the-field/below-the-field flip and edge clamping.
final class RecordingIndicatorFieldAnchorTests: XCTestCase {
    private typealias Policy = RecordingIndicatorFieldAnchorPolicy

    /// 1440x900 primary; menu bar shaves the top of the visible frame.
    private let primary = Policy.Screen(
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: CGRect(x: 0, y: 4, width: 1440, height: 871)
    )

    func testFieldFullyVisiblePlacesChipAboveRightAligned() throws {
        // AX: 400pt down from the screen top, so the field's Cocoa top edge is
        // 900 - 400 = 500.
        let axField = CGRect(x: 400, y: 400, width: 500, height: 60)
        let placement = Policy.placement(axFieldFrame: axField, screens: [primary])

        let chip = try XCTUnwrap(placement).chipFrame
        XCTAssertFalse(try XCTUnwrap(placement).placedBelowField)
        // Right-aligned to the field's right edge.
        XCTAssertEqual(chip.maxX, 900, accuracy: 0.001)
        // Just above the field's Cocoa top edge (900 - 400 = 500) + clearance.
        XCTAssertEqual(chip.minY, 500 + Policy.clearance, accuracy: 0.001)
        XCTAssertEqual(chip.size, Policy.chipSize)
        XCTAssertTrue(primary.visibleFrame.contains(chip))

        // Panel geometry puts the trailing-aligned, vertically centered chip
        // content exactly at chipFrame.
        let panel = try XCTUnwrap(placement).panelFrame
        XCTAssertEqual(panel.maxX, chip.maxX + Policy.chipTrailingInset, accuracy: 0.001)
        XCTAssertEqual(panel.midY, chip.midY, accuracy: 0.001)
        XCTAssertEqual(panel.size, Policy.panelSize)
    }

    func testFieldNearScreenTopFlipsChipBelow() throws {
        // 30pt from the AX top → Cocoa maxY 870, no room above within visible 875.
        let axField = CGRect(x: 400, y: 30, width: 500, height: 40)
        let placement = Policy.placement(axFieldFrame: axField, screens: [primary])

        let unwrapped = try XCTUnwrap(placement)
        XCTAssertTrue(unwrapped.placedBelowField)
        // Field Cocoa bottom edge = 900 - 70 = 830; chip sits clearance below.
        XCTAssertEqual(
            unwrapped.chipFrame.maxY,
            830 - Policy.clearance,
            accuracy: 0.001
        )
        XCTAssertEqual(unwrapped.chipFrame.maxX, 900, accuracy: 0.001)
        XCTAssertTrue(primary.visibleFrame.contains(unwrapped.chipFrame))
    }

    func testFieldPastRightEdgeClampsChipToVisibleFrame() throws {
        // Field extends 110pt beyond the right screen edge.
        let axField = CGRect(x: 1350, y: 400, width: 200, height: 40)
        let placement = Policy.placement(axFieldFrame: axField, screens: [primary])

        let chip = try XCTUnwrap(placement).chipFrame
        XCTAssertEqual(chip.maxX, primary.visibleFrame.maxX, accuracy: 0.001)
        XCTAssertTrue(primary.visibleFrame.contains(chip))
    }

    func testFieldOnSecondaryDisplayConvertsAndAnchorsThere() throws {
        let secondary = Policy.Screen(
            frame: CGRect(x: 1440, y: 100, width: 1512, height: 982),
            visibleFrame: CGRect(x: 1440, y: 100, width: 1512, height: 982)
        )
        // AX y is measured from the primary screen's top edge across displays.
        let axField = CGRect(x: 2000, y: 300, width: 400, height: 44)
        let placement = Policy.placement(
            axFieldFrame: axField,
            screens: [primary, secondary]
        )

        let chip = try XCTUnwrap(placement).chipFrame
        // Cocoa field top edge = 900 - 300 = 600 → chip above it, on the
        // secondary screen, right-aligned to x = 2400.
        XCTAssertEqual(chip.minY, 600 + Policy.clearance, accuracy: 0.001)
        XCTAssertEqual(chip.maxX, 2400, accuracy: 0.001)
        XCTAssertTrue(secondary.visibleFrame.contains(chip))
        XCTAssertFalse(try XCTUnwrap(placement).placedBelowField)
    }

    func testUnusableFieldFramesFallBackToNil() {
        XCTAssertNil(Policy.placement(axFieldFrame: nil, screens: [primary]))
        // Degenerate and non-finite frames.
        XCTAssertNil(Policy.placement(
            axFieldFrame: CGRect(x: 100, y: 100, width: 0, height: 0),
            screens: [primary]
        ))
        XCTAssertNil(Policy.placement(
            axFieldFrame: CGRect(x: CGFloat.nan, y: 100, width: 300, height: 40),
            screens: [primary]
        ))
        // A frame on no connected screen (stale AX read after display unplug).
        XCTAssertNil(Policy.placement(
            axFieldFrame: CGRect(x: 9000, y: 300, width: 300, height: 40),
            screens: [primary]
        ))
        XCTAssertNil(Policy.placement(
            axFieldFrame: CGRect(x: 100, y: 100, width: 300, height: 40),
            screens: []
        ))
    }

    func testCompactVariantRequiresMirroringAndAnchor() {
        XCTAssertTrue(Policy.isCompact(mirroring: true, anchored: true))
        XCTAssertFalse(Policy.isCompact(mirroring: true, anchored: false))
        XCTAssertFalse(Policy.isCompact(mirroring: false, anchored: true))
        XCTAssertFalse(Policy.isCompact(mirroring: false, anchored: false))
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
}
