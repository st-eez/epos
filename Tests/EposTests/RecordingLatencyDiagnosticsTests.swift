import XCTest
@testable import Epos

final class RecordingLatencyDiagnosticsTests: XCTestCase {
    func testDurationsUseTheInjectedMonotonicClockAndRepeatedEndsDoNotEmit() throws {
        let log = LatencyTestLog()
        log.clock.advance(.milliseconds(90))
        log.timing.begin(.targetAuthorization)
        log.timing.begin(.targetAuthorization)
        log.clock.advance(.microseconds(2_750))
        log.timing.end(.targetAuthorization, outcome: .refused)
        log.clock.advance(.seconds(5))
        log.timing.end(.targetAuthorization)

        let row = try log.row(.targetAuthorization)
        XCTAssertEqual(row["durationMs"], "2.750")
        XCTAssertEqual(row["elapsedMs"], "92.750")
        XCTAssertEqual(row["outcome"], "refused")
        XCTAssertEqual(try log.rows().count, 1)
        XCTAssertNil(row["transcript"])
    }

    func testFallbackAttemptsKeepDistinctDurationsAndOutcomes() throws {
        let log = LatencyTestLog()
        log.timing.begin(.targetAuthorization)
        log.clock.advance(.milliseconds(3))
        log.timing.end(.targetAuthorization)
        log.timing.begin(.targetAuthorization)
        log.clock.advance(.milliseconds(8))
        log.timing.end(.targetAuthorization, outcome: .refused)

        XCTAssertEqual(try log.row(.targetAuthorization)["durationMs"], "3.000")
        XCTAssertEqual(try log.row(.targetAuthorization, attempt: 2)["durationMs"], "8.000")
        XCTAssertEqual(try log.row(.targetAuthorization, attempt: 2)["outcome"], "refused")
    }

    func testAnAbsentFirstResultCannotBecomeAZeroOrHoldDurationSample() throws {
        let log = LatencyTestLog()
        log.timing.begin(.firstDisplayPublication)
        log.clock.advance(.seconds(10))
        log.timing.abandon(.firstDisplayPublication)
        log.timing.end(.firstDisplayPublication)

        XCTAssertEqual(try log.row(.firstDisplayPublication)["durationMs"], "-1.000")
        XCTAssertEqual(try log.row(.firstDisplayPublication)["outcome"], "unavailable")
        XCTAssertEqual(try log.rows().count, 1)
    }
}
