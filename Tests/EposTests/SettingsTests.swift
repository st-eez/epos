import AppKit
import XCTest
@testable import Epos

/// Settings round-trip through an ephemeral `UserDefaults` suite — never the
/// shared `.standard` domain — so persistence is exercised hermetically.
final class SettingsTests: XCTestCase {
    private let suiteName = "com.steez.Epos.tests.settings.\(UUID().uuidString)"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testCorrectionEvidenceDefaultsOffAndPersistsOn() {
        XCTAssertFalse(Settings.load(from: defaults).saveCorrectionEvidence)

        var settings = Settings.load(from: defaults)
        settings.saveCorrectionEvidence = true
        settings.save(to: defaults)

        XCTAssertTrue(Settings.load(from: defaults).saveCorrectionEvidence)
    }

    func testInlinePreviewDefaultsOnAndPersistsAStoredOff() {
        // Never-set reads as on; a stored false must be distinct from "never set".
        XCTAssertTrue(Settings.load(from: defaults).inlinePreview)

        var settings = Settings.load(from: defaults)
        settings.inlinePreview = false
        settings.save(to: defaults)

        XCTAssertFalse(Settings.load(from: defaults).inlinePreview)
    }

    func testInputControlsKeepDefaultsAndRoundTripUserChoices() throws {
        let initial = Settings.load(from: defaults)
        XCTAssertEqual(initial.dictationShortcut, .functionKey)
        XCTAssertNil(initial.inputDeviceUID)
        let shortcut = try XCTUnwrap(DictationShortcut(
            modifierFlags: UInt64(NSEvent.ModifierFlags.control.rawValue), keyCode: 49
        ))
        var settings = initial
        settings.dictationShortcut = shortcut
        settings.inputDeviceUID = "test-pinned-input"
        settings.save(to: defaults)
        let restored = Settings.load(from: defaults)
        XCTAssertEqual(restored.dictationShortcut, shortcut)
        XCTAssertEqual(restored.inputDeviceUID, "test-pinned-input")

        settings.dictationShortcut = .functionKey
        settings.inputDeviceUID = nil
        settings.save(to: defaults)
        XCTAssertEqual(Settings.load(from: defaults).dictationShortcut, .functionKey)
        XCTAssertNil(Settings.load(from: defaults).inputDeviceUID)
    }

    func testInvalidStoredShortcutUsesFnAndLeavesOtherPreferencesIntact() {
        defaults.set(Data("{\"modifierFlags\":0,\"keyCode\":49}".utf8), forKey: "settings.dictationShortcut")
        defaults.set("disconnected-test-input", forKey: "settings.inputDeviceUID")
        let restored = Settings.load(from: defaults)
        XCTAssertEqual(restored.dictationShortcut, .functionKey)
        XCTAssertEqual(restored.inputDeviceUID, "disconnected-test-input")
        defaults.set(Data("unreadable".utf8), forKey: "settings.dictationShortcut")
        XCTAssertEqual(Settings.load(from: defaults).dictationShortcut, .functionKey)
    }
}
