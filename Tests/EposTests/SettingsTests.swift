import XCTest
@testable import Epos

/// Settings round-trip through an ephemeral `UserDefaults` suite — never the
/// shared `.standard` domain — so persistence is exercised hermetically.
final class SettingsTests: XCTestCase {
    private let suiteName = "com.steez.Epos.tests.settings"
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

    func testPolishEnabledPersistsThroughSaveAndLoad() {
        // Absent key → opt-in flag defaults off.
        XCTAssertFalse(Settings.load(from: defaults).polishEnabled)

        // Save it on, then a fresh load reads the persisted value back.
        var settings = Settings.load(from: defaults)
        settings.polishEnabled = true
        settings.save(to: defaults)

        XCTAssertTrue(Settings.load(from: defaults).polishEnabled)
    }

    func testCorrectionEvidenceDefaultsOnAndPersistsOff() {
        XCTAssertTrue(Settings.load(from: defaults).saveCorrectionEvidence)

        var settings = Settings.load(from: defaults)
        settings.saveCorrectionEvidence = false
        settings.save(to: defaults)

        XCTAssertFalse(Settings.load(from: defaults).saveCorrectionEvidence)
    }
}
