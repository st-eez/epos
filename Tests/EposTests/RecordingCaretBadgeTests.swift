import XCTest
@testable import Epos

/// Pins the pure placement math for the caret mic badge: Cocoa-coordinate
/// caret rects → a small square panel hanging below the caret line, centered
/// on its x, flipping above near the screen bottom and clamped to the visible
/// frame. Nil means "no usable anchor" and the caller keeps the pill.
final class RecordingCaretBadgeTests: XCTestCase {
    private typealias Policy = RecordingCaretBadgePolicy

    /// 1440x900 primary; menu bar shaves the top of the visible frame.
    private let primary = Policy.Screen(
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: CGRect(x: 0, y: 4, width: 1440, height: 871)
    )

    func testCaretMidScreenHangsBadgeBelowCenteredOnCaretX() throws {
        let caret = CGRect(x: 600, y: 300, width: 1, height: 18)
        let frame = try XCTUnwrap(Policy.panelFrame(caretRect: caret, screens: [primary]))

        XCTAssertEqual(frame.midX, caret.midX, accuracy: 0.001)
        XCTAssertEqual(frame.maxY, caret.minY - Policy.clearance, accuracy: 0.001)
        XCTAssertEqual(frame.size, CGSize(width: Policy.panelEdge, height: Policy.panelEdge))
        XCTAssertFalse(frame.intersects(caret))
        XCTAssertTrue(primary.visibleFrame.contains(frame))
    }

    func testCaretNearScreenBottomFlipsBadgeAboveTheLine() throws {
        let caret = CGRect(x: 600, y: 10, width: 1, height: 18)
        let frame = try XCTUnwrap(Policy.panelFrame(caretRect: caret, screens: [primary]))

        XCTAssertEqual(frame.minY, caret.maxY + Policy.clearance, accuracy: 0.001)
        XCTAssertFalse(frame.intersects(caret))
        XCTAssertTrue(primary.visibleFrame.contains(frame))
    }

    func testCaretNearScreenEdgesClampsBadgeIntoVisibleFrame() throws {
        let atRight = try XCTUnwrap(Policy.panelFrame(
            caretRect: CGRect(x: 1439.5, y: 300, width: 1, height: 18),
            screens: [primary]
        ))
        XCTAssertEqual(atRight.maxX, primary.visibleFrame.maxX, accuracy: 0.001)

        let atLeft = try XCTUnwrap(Policy.panelFrame(
            caretRect: CGRect(x: 0.5, y: 300, width: 1, height: 18),
            screens: [primary]
        ))
        XCTAssertEqual(atLeft.minX, primary.visibleFrame.minX, accuracy: 0.001)
    }

    func testCaretOnSecondaryDisplayAnchorsThere() throws {
        let secondary = Policy.Screen(
            frame: CGRect(x: 1440, y: 100, width: 1512, height: 982),
            visibleFrame: CGRect(x: 1440, y: 100, width: 1512, height: 982)
        )
        let caret = CGRect(x: 2000, y: 400, width: 1, height: 16)
        let frame = try XCTUnwrap(Policy.panelFrame(
            caretRect: caret,
            screens: [primary, secondary]
        ))
        XCTAssertTrue(secondary.visibleFrame.contains(frame))
        XCTAssertEqual(frame.midX, caret.midX, accuracy: 0.001)
    }

    func testUnusableCaretRectsAreUnavailable() {
        XCTAssertNil(Policy.panelFrame(caretRect: nil, screens: [primary]))
        XCTAssertNil(Policy.panelFrame(caretRect: .zero, screens: [primary]))
        // Degenerate height (no real text line is 300pt or 2pt tall).
        XCTAssertNil(Policy.panelFrame(
            caretRect: CGRect(x: 600, y: 300, width: 1, height: 300),
            screens: [primary]
        ))
        XCTAssertNil(Policy.panelFrame(
            caretRect: CGRect(x: 600, y: 300, width: 1, height: 2),
            screens: [primary]
        ))
        XCTAssertNil(Policy.panelFrame(
            caretRect: CGRect(x: CGFloat.nan, y: 300, width: 1, height: 18),
            screens: [primary]
        ))
        // A caret on no connected screen.
        XCTAssertNil(Policy.panelFrame(
            caretRect: CGRect(x: 5000, y: 300, width: 1, height: 18),
            screens: [primary]
        ))
        XCTAssertNil(Policy.panelFrame(
            caretRect: CGRect(x: 600, y: 300, width: 1, height: 18),
            screens: []
        ))
    }
}
