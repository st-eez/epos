import CoreGraphics
import XCTest
@testable import Epos

final class DictationShortcutTests: XCTestCase {
    func testShortcutRoundTripAndDefault() throws {
        let shortcut = try XCTUnwrap(DictationShortcut(
            modifierFlags: CGEventFlags([.maskControl, .maskCommand]).rawValue, keyCode: 49
        ))
        let data = try JSONEncoder().encode(shortcut)
        XCTAssertEqual(try JSONDecoder().decode(DictationShortcut.self, from: data), shortcut)
        XCTAssertEqual(shortcut.displayName, "⌃⌘Space")
        XCTAssertEqual(DictationShortcut.functionKey.displayName, "fn")
    }

    func testPlainKeysUnsupportedModifiersAndModifierKeycodesAreInvalid() {
        XCTAssertNil(DictationShortcut(modifierFlags: 0, keyCode: 0))
        XCTAssertNil(DictationShortcut(modifierFlags: CGEventFlags.maskAlphaShift.rawValue))
        XCTAssertNil(DictationShortcut(modifierFlags: CGEventFlags.maskControl.rawValue, keyCode: 63))
        XCTAssertNil(DictationShortcut(modifierFlags: CGEventFlags.maskControl.rawValue, keyCode: 57))
        XCTAssertNil(DictationShortcut(modifierFlags: CGEventFlags.maskControl.rawValue, keyCode: 128))
    }

    func testDecodingRejectsInvalidBindingsAtThePersistenceBoundary() {
        for json in [
            "{\"modifierFlags\":0,\"keyCode\":0}",
            "{\"modifierFlags\":18446744073709551615}",
            "{\"modifierFlags\":262144,\"keyCode\":63}",
            "{\"modifierFlags\":262144,\"keyCode\":65536}"
        ] {
            XCTAssertThrowsError(try JSONDecoder().decode(DictationShortcut.self, from: Data(json.utf8)))
        }
    }
}
