import XCTest
@testable import Epos

/// Overlapping pill notices: each flash owns the pill until its own expiry, so
/// an earlier notice's timer must never put the panel away underneath a newer
/// one still showing. Uses the real 2.5s flash duration, so this test trades
/// ~3s of wall clock for driving the exact production timers.
final class CoordinatorNoticeOverlapTests: XCTestCase {
    @MainActor
    func testAnExpiringNoticeDoesNotHideThePillUnderANewerOne() async throws {
        let coordinator = AppCoordinator(autoStart: false)

        coordinator.flashInsertionUnavailableNotice()
        XCTAssertTrue(coordinator.pillVisible)

        // Second notice flashes while the first is still up.
        try await Task.sleep(for: .seconds(1))
        coordinator.flashStartUnavailableNotice("Not ready")

        // Wait out the FIRST notice's expiry (2.5s after its flash).
        let deadline = Date().addingTimeInterval(3)
        while coordinator.insertionUnavailable, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(coordinator.insertionUnavailable, "first notice should have expired")
        XCTAssertTrue(coordinator.startUnavailable, "second notice is still inside its flash window")
        XCTAssertTrue(coordinator.pillVisible, "the pill must stay up for the notice still showing")

        // And the second notice's own expiry puts the pill away.
        let finalDeadline = Date().addingTimeInterval(3)
        while coordinator.pillVisible, Date() < finalDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(coordinator.startUnavailable)
        XCTAssertFalse(coordinator.pillVisible, "no notice left; the pill should be away")
    }

    @MainActor
    func testReflashingTheSameNoticeRestartsItsWindow() async throws {
        let coordinator = AppCoordinator(autoStart: false)

        coordinator.flashStartUnavailableNotice("Preparing")
        try await Task.sleep(for: .seconds(1))
        // The readiness re-check re-reports through the same notice with an
        // updated label; the first flash's timer must not truncate it.
        coordinator.flashStartUnavailableNotice("Mic blocked")

        // Past the FIRST flash's expiry, inside the second's window.
        try await Task.sleep(for: .seconds(1.8))
        XCTAssertTrue(coordinator.startUnavailable, "the re-flash owns a full window")
        XCTAssertTrue(coordinator.pillVisible)

        // The second flash's own expiry still clears it.
        let deadline = Date().addingTimeInterval(3)
        while coordinator.startUnavailable, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(coordinator.startUnavailable)
        XCTAssertFalse(coordinator.pillVisible)
    }
}
