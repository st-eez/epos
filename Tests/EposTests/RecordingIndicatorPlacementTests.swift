import XCTest
@testable import Epos

final class RecordingIndicatorPlacementTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let size = CGSize(width: 34, height: 34)

    @MainActor
    func testNewRecordingRetargetsAfterPreviousNotice() {
        var pid: pid_t = 101
        let controller = RecordingIndicatorController(frontmostProcessIdentifier: { pid })
        controller.show(newRecording: true)
        controller.show(notice: true)
        XCTAssertEqual(controller.targetPID, 101)
        pid = 202
        controller.show(notice: true)
        XCTAssertEqual(controller.targetPID, 101)
        controller.show(newRecording: true)
        XCTAssertEqual(controller.targetPID, 202)
        controller.hide()
    }

    func testCaretCueClearsTextLineAndMovesAboveBottomInput() {
        for caret in [CGRect(x: 700, y: 450, width: 0, height: 18),
                      CGRect(x: 1400, y: 12, width: 2, height: 22)] {
            let cue = RecordingIndicatorPlacementPolicy.frame(caret: caret, in: screen, indicatorSize: size)
            XCTAssertTrue(screen.contains(cue))
            XCTAssertFalse(cue.intersects(CGRect(x: 0, y: caret.minY, width: screen.width, height: caret.height)))
            XCTAssertLessThan(abs(cue.midX - caret.midX), 40)
        }
    }

    func testMissingInvalidAndOffscreenCaretUseSmallRightEdgeCue() {
        for caret: CGRect? in [nil, .zero, CGRect(x: 20, y: 20, width: 800, height: 600),
                              CGRect(x: 2000, y: 2000, width: 1, height: 18),
                              CGRect(x: CGFloat.nan, y: 10, width: 1, height: 18)] {
            let cue = RecordingIndicatorPlacementPolicy.frame(caret: caret, in: screen, indicatorSize: size)
            XCTAssertEqual(cue.maxX, screen.maxX - 8)
            XCTAssertEqual(cue.midY, screen.midY)
            XCTAssertEqual(cue.size, size)
        }
    }

    func testCaretConversionOnDisplayAboveAndLeftOfPrimary() {
        let upperDisplay = CGRect(x: -1200, y: 900, width: 1200, height: 800)
        let caret = RecordingIndicatorPlacementPolicy.appKitRect(
            fromAX: CGRect(x: -600, y: -400, width: 0, height: 20), primaryScreenHeight: 900
        )
        XCTAssertEqual(caret, CGRect(x: -600, y: 1280, width: 0, height: 20))
        let cue = RecordingIndicatorPlacementPolicy.frame(caret: caret, in: upperDisplay, indicatorSize: size)
        XCTAssertTrue(upperDisplay.contains(cue))
        XCTAssertLessThan(cue.maxY, caret.minY)
    }

    func testNoticeFitsAtEdgeOfSecondaryDisplay() {
        let display = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
        let cue = RecordingIndicatorPlacementPolicy.frame(
            caret: nil, in: display, indicatorSize: CGSize(width: 224, height: 40)
        )
        XCTAssertTrue(display.contains(cue))
        XCTAssertEqual(cue.maxX, -8)
    }
}
