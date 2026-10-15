import XCTest
@testable import Epos

final class FocusedElementSearchTests: XCTestCase {
    func testFindsFocusedEditorInsideWindow() {
        let tree = [0: [1, 2], 1: [3], 2: [4, 5]]
        XCTAssertEqual(FocusedElementSearch.find(
            root: 0, isFocused: { $0 == 5 }, children: { tree[$0] ?? [] }
        ), 5)
    }

    func testMissingOrAmbiguousFocusCannotChooseAnEditor() {
        for focused in [Set<Int>(), Set([1, 2])] {
            XCTAssertNil(FocusedElementSearch.find(
                root: 0, isFocused: { focused.contains($0) }, children: { $0 == 0 ? [1, 2] : [] }
            ))
        }
    }

    func testIncompleteSearchDoesNotTrustAnEarlierFocusedNode() {
        XCTAssertNil(FocusedElementSearch.find(
            root: 0, maximumNodes: 2, isFocused: { $0 == 1 }, children: { $0 == 0 ? [1, 2] : [] }
        ))
        var remaining = 2
        XCTAssertNil(FocusedElementSearch.find(
            root: 0, isFocused: { $0 == 1 }, children: { $0 == 0 ? [1, 2] : [] },
            withinBudget: { remaining -= 1; return remaining >= 0 }
        ))
    }

    func testUnreadableSubtreeOrFocusStateCannotConfirmUniqueFocus() {
        for failedRead in ["children", "focus"] {
            XCTAssertNil(FocusedElementSearch.find(
                root: 0,
                isFocused: { $0 == 2 && failedRead == "focus" ? nil : $0 == 1 },
                children: { node in
                    if node == 2 && failedRead == "children" { return nil }
                    return node == 0 ? [1, 2] : []
                }
            ), failedRead)
        }
    }
}
