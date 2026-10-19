import XCTest
import ApplicationServices
@testable import Epos

final class FocusedElementSearchTests: XCTestCase {
    func testApplicationFocusResolvesWhenGlobalFocusIsUnavailable() {
        for error in [AXError.noValue, .cannotComplete, .attributeUnsupported, .notImplemented, .success] {
            let fixture = FocusLookupFixture()
            fixture.globalFocus = (error, nil)
            let found = fixture.search.resolve(in: fixture.system)
            XCTAssertTrue(found.map { CFEqual($0, fixture.editor) } ?? false, "\(error)")
        }
    }

    func testGlobalFocusDoesNotRequireApplicationTraversal() {
        let fixture = FocusLookupFixture()
        fixture.globalFocus = (.success, fixture.editor)
        fixture.frontmost = nil
        XCTAssertTrue(fixture.search.resolve(in: fixture.system).map { CFEqual($0, fixture.editor) } ?? false)
        XCTAssertEqual(fixture.frontmostReads, 0)
    }

    func testGlobalPermissionAndInvalidElementErrorsCannotUseFallback() {
        for error in [AXError.apiDisabled, .invalidUIElement, .illegalArgument, .failure] {
            let fixture = FocusLookupFixture()
            fixture.globalFocus = (error, nil)
            XCTAssertNil(fixture.search.resolve(in: fixture.system))
            XCTAssertEqual(fixture.frontmostReads, 0)
        }
    }

    func testMissingGlobalAndApplicationFocusSearchesOnlyFocusedWindow() {
        let fixture = FocusLookupFixture()
        fixture.applicationFocus = (.noValue, nil)
        XCTAssertTrue(fixture.search.resolve(in: fixture.system).map { CFEqual($0, fixture.editor) } ?? false)
    }

    func testApplicationFocusInAnotherWindowIsRefused() {
        let fixture = FocusLookupFixture()
        fixture.editorWindow = fixture.otherWindow
        XCTAssertNil(fixture.search.resolve(in: fixture.system))
    }

    func testAppWindowOrFieldChangesDuringDirectLookupAreRefused() {
        for changed in ["app", "window", "field"] {
            let fixture = FocusLookupFixture()
            var focusReads = 0
            fixture.beforeRead = { [unowned fixture] element, attribute in
                guard CFEqual(element, fixture.application), attribute == kAXFocusedUIElementAttribute else { return }
                focusReads += 1
                if changed == "app" { fixture.frontmost = fixture.otherApplication }
                if changed == "window" { fixture.focusedWindow = fixture.otherWindow }
                if changed == "field", focusReads == 2 { fixture.applicationFocus = (.success, fixture.otherEditor) }
            }
            XCTAssertNil(fixture.search.resolve(in: fixture.system), changed)
        }
    }

    func testCachedEditorStillRequiresUnchangedAppAndWindow() {
        for changed in ["app", "window"] {
            let fixture = FocusLookupFixture()
            fixture.applicationFocus = (.noValue, nil)
            XCTAssertNotNil(fixture.search.resolve(in: fixture.system))
            fixture.beforeRead = { [unowned fixture] element, attribute in
                guard CFEqual(element, fixture.editor), attribute == kAXFocusedAttribute else { return }
                if changed == "app" { fixture.frontmost = fixture.otherApplication }
                if changed == "window" { fixture.focusedWindow = fixture.otherWindow }
            }
            XCTAssertNil(fixture.search.resolve(in: fixture.system), changed)
        }
    }

    func testApplicationPermissionFailureCannotSearchCachedEditor() {
        let fixture = FocusLookupFixture()
        fixture.applicationFocus = (.noValue, nil)
        XCTAssertNotNil(fixture.search.resolve(in: fixture.system))
        fixture.applicationFocus = (.apiDisabled, nil)
        XCTAssertNil(fixture.search.resolve(in: fixture.system))
    }

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

private final class FocusLookupFixture {
    let system = AXUIElementCreateSystemWide()
    let application = AXUIElementCreateApplication(90_001)
    let window = AXUIElementCreateApplication(90_002)
    let editor = AXUIElementCreateApplication(90_003)
    let otherApplication = AXUIElementCreateApplication(90_004)
    let otherWindow = AXUIElementCreateApplication(90_005)
    let otherEditor = AXUIElementCreateApplication(90_006)
    var globalFocus: (AXError, CFTypeRef?) = (.noValue, nil)
    var applicationFocus: (AXError, CFTypeRef?)
    var frontmost: AXUIElement?
    var focusedWindow: AXUIElement
    var editorWindow: AXUIElement
    var frontmostReads = 0
    var beforeRead: ((AXUIElement, String) -> Void)?

    lazy var search = FocusedElementSearch(
        frontmostApplication: { [unowned self] in
            frontmostReads += 1
            return frontmost
        },
        readAttribute: { [unowned self] element, attribute in read(element, attribute) }
    )

    init() {
        applicationFocus = (.success, editor)
        frontmost = application
        focusedWindow = window
        editorWindow = window
    }

    private func read(_ element: AXUIElement, _ attribute: String) -> (AXError, CFTypeRef?) {
        beforeRead?(element, attribute)
        if CFEqual(element, system), attribute == kAXFocusedUIElementAttribute { return globalFocus }
        if CFEqual(element, application) {
            if attribute == kAXFocusedWindowAttribute { return (.success, focusedWindow) }
            if attribute == kAXFocusedUIElementAttribute { return applicationFocus }
        }
        if CFEqual(element, editor) {
            switch attribute {
            case kAXWindowAttribute: return (.success, editorWindow)
            case kAXFocusedAttribute: return (.success, kCFBooleanTrue)
            case kAXRoleAttribute: return (.success, kAXTextAreaRole as CFString)
            case kAXChildrenAttribute: return (.noValue, nil)
            default: return (.attributeUnsupported, nil)
            }
        }
        if CFEqual(element, window) {
            if attribute == kAXFocusedAttribute { return (.success, kCFBooleanFalse) }
            if attribute == kAXChildrenAttribute { return (.success, [editor] as CFArray) }
        }
        return (.attributeUnsupported, nil)
    }
}
