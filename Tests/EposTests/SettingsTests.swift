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

    func testCorrectionEvidenceDefaultsOffAndPersistsOn() {
        XCTAssertFalse(Settings.load(from: defaults).saveCorrectionEvidence)

        var settings = Settings.load(from: defaults)
        settings.saveCorrectionEvidence = true
        settings.save(to: defaults)

        XCTAssertTrue(Settings.load(from: defaults).saveCorrectionEvidence)
    }
}
