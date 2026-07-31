import XCTest
@testable import Epos

/// Pins that user-audible/visible side effects stay suppressed in test
/// processes. This regressed silently once: the policy keyed only on
/// `XCTestConfigurationFilePath`, which `swift test`'s runner stopped setting,
/// and every pipeline-driving test flashed real pills and pinged real bells.
final class IndicatorSuppressionTests: XCTestCase {
    func testThisTestProcessCannotPresentWindowsOrPlayCues() {
        XCTAssertFalse(
            IndicatorWindowPolicy.canPresentWindows,
            "the test runner is not detected as a test process; pills and bells will fire on the developer's screen"
        )
    }
}
