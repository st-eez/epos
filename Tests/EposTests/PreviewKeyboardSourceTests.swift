import XCTest
@testable import Epos

@MainActor
final class PreviewKeyboardSourceTests: XCTestCase {
    private static let layout = "com.test.layout"
    private static let method = "com.test.inputmethod"
    private static let otherLayout = "com.test.other-layout"

    func testBorrowedLayoutIsRestoredExactlyOnce() throws {
        let access = FakeKeyboardSourceAccess(current: Self.layout, layout: Self.layout)
        let source = try XCTUnwrap(PreviewKeyboardSource(access: access))

        XCTAssertEqual(access.current, PreviewKeyboardSource.companionIdentifier)
        XCTAssertEqual(source.acquisitionArgument, "acquire-layout \(Self.layout) \(Self.layout)")
        source.release()
        source.release()

        XCTAssertEqual(access.current, Self.layout)
        XCTAssertEqual(access.selections, [PreviewKeyboardSource.companionIdentifier, Self.layout])
    }

    func testBorrowedInputMethodUsesItsUnderlyingLayoutAndRestoresTheMethod() throws {
        let access = FakeKeyboardSourceAccess(current: Self.method, layout: Self.layout, isLayout: false)
        let source = try XCTUnwrap(PreviewKeyboardSource(access: access))

        XCTAssertEqual(source.acquisitionArgument, "acquire-method \(Self.method) \(Self.layout)")
        source.release()

        XCTAssertEqual(access.current, Self.method)
        XCTAssertEqual(access.selections, [PreviewKeyboardSource.companionIdentifier, Self.method])
    }

    func testReleasePreservesAKeyboardSourceTheUserSelectedDuringTheHold() throws {
        let access = FakeKeyboardSourceAccess(current: Self.layout, layout: Self.layout)
        let source = try XCTUnwrap(PreviewKeyboardSource(access: access))
        access.current = Self.otherLayout

        source.release()
        access.current = PreviewKeyboardSource.companionIdentifier
        source.release()

        XCTAssertEqual(access.selections, [PreviewKeyboardSource.companionIdentifier])
        XCTAssertEqual(access.current, PreviewKeyboardSource.companionIdentifier,
                       "a released recording cannot restore over a later source choice")
    }

    func testUnavailableOrDisabledCompanionDoesNotSelectAnySource() {
        for availability in [FakeKeyboardSourceAccess.Availability.missing, .disabled] {
            let access = FakeKeyboardSourceAccess(current: Self.layout, layout: Self.layout)
            access.availability = availability

            XCTAssertNil(PreviewKeyboardSource(access: access))
            XCTAssertEqual(access.current, Self.layout)
            XCTAssertEqual(access.selections, [])
        }
    }

    func testFailedSelectionDoesNotBorrowTheSource() {
        let access = FakeKeyboardSourceAccess(current: Self.layout, layout: Self.layout)
        access.companionSelectionSucceeds = false
        access.sourceAfterCompanionSelection = Self.layout

        XCTAssertNil(PreviewKeyboardSource(access: access))
        XCTAssertEqual(access.current, Self.layout)
        XCTAssertEqual(access.selections, [PreviewKeyboardSource.companionIdentifier])
    }

    func testFailedSelectionThatChangedTheSourceRollsBack() {
        let access = FakeKeyboardSourceAccess(current: Self.layout, layout: Self.layout)
        access.companionSelectionSucceeds = false

        XCTAssertNil(PreviewKeyboardSource(access: access))
        XCTAssertEqual(access.current, Self.layout)
        XCTAssertEqual(access.selections, [PreviewKeyboardSource.companionIdentifier, Self.layout])
    }

    func testSelectionReadbackMismatchPreservesAnInterveningSourceChoice() {
        let access = FakeKeyboardSourceAccess(current: Self.layout, layout: Self.layout)
        access.sourceAfterCompanionSelection = Self.otherLayout

        XCTAssertNil(PreviewKeyboardSource(access: access))
        XCTAssertEqual(access.current, Self.otherLayout)
        XCTAssertEqual(access.selections, [PreviewKeyboardSource.companionIdentifier])
    }

    func testMissingSourceOrLayoutAndAnAlreadySelectedCompanionAreNotBorrowed() {
        let accesses = [
            FakeKeyboardSourceAccess(current: nil, layout: Self.layout),
            FakeKeyboardSourceAccess(current: Self.layout, layout: nil),
            FakeKeyboardSourceAccess(current: PreviewKeyboardSource.companionIdentifier, layout: Self.layout)
        ]
        for access in accesses {
            XCTAssertNil(PreviewKeyboardSource(access: access))
            XCTAssertEqual(access.selections, [])
        }
    }
}

@MainActor
private final class FakeKeyboardSourceAccess: PreviewKeyboardSourceAccess {
    enum Availability { case enabled, missing, disabled }

    var current: String?
    var availability = Availability.enabled
    var companionSelectionSucceeds = true
    var sourceAfterCompanionSelection = PreviewKeyboardSource.companionIdentifier
    private let layout: String?
    private let isLayout: Bool
    private(set) var selections: [String] = []

    init(current: String?, layout: String?, isLayout: Bool = true) {
        self.current = current
        self.layout = layout
        self.isLayout = isLayout
    }

    func currentIdentifier() -> String? { current }
    func currentIsLayout() -> Bool { isLayout }
    func layoutIdentifier() -> String? { layout }
    func companionIsAvailable() -> Bool { availability == .enabled }

    func select(_ identifier: String) -> Bool {
        selections.append(identifier)
        if identifier == PreviewKeyboardSource.companionIdentifier {
            current = sourceAfterCompanionSelection
            return companionSelectionSucceeds
        }
        current = identifier
        return true
    }
}
