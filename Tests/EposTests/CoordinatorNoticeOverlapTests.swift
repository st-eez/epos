import XCTest
@testable import Epos

/// Runs the coordinator's actual expiry callbacks in an explicit order.
@MainActor
final class ControlledNoticeExpiry {
    private(set) var durations: [Duration] = []
    private var expirations: [@MainActor () -> Void] = []

    func schedule(_ duration: Duration, expire: @escaping @MainActor () -> Void) {
        durations.append(duration)
        expirations.append(expire)
    }

    func expire(_ index: Int) {
        guard expirations.indices.contains(index) else {
            XCTFail("notice expiry \(index) was not scheduled")
            return
        }
        expirations[index]()
    }
}

/// Each notice owns the pill until its own expiry. A superseded timer must not
/// clear a newer notice, and an expired notice must not hide a different one.
@MainActor
final class CoordinatorNoticeOverlapTests: XCTestCase {
    func testAnExpiringNoticeDoesNotHideThePillUnderANewerOne() {
        let expiry = ControlledNoticeExpiry()
        let coordinator = AppCoordinator(noticeExpiryScheduler: expiry.schedule, autoStart: false)

        coordinator.flashInsertionUnavailableNotice("Check the field")
        coordinator.flashStartUnavailableNotice("Not ready")
        XCTAssertEqual(expiry.durations, [.milliseconds(2_500), .milliseconds(2_500)])
        XCTAssertTrue(coordinator.insertionUnavailable)
        XCTAssertTrue(coordinator.startUnavailable)
        XCTAssertTrue(coordinator.pillVisible)

        expiry.expire(0)
        XCTAssertFalse(coordinator.insertionUnavailable)
        XCTAssertTrue(coordinator.startUnavailable)
        XCTAssertTrue(coordinator.pillVisible, "the remaining notice still owns the pill")

        expiry.expire(1)
        XCTAssertFalse(coordinator.startUnavailable)
        XCTAssertFalse(coordinator.pillVisible)
    }

    func testReflashingTheSameNoticeRestartsItsWindow() {
        let expiry = ControlledNoticeExpiry()
        let coordinator = AppCoordinator(noticeExpiryScheduler: expiry.schedule, autoStart: false)

        coordinator.flashInsertionUnavailableNotice("Check the field")
        coordinator.flashInsertionUnavailableNotice("No access")
        expiry.expire(0)
        XCTAssertTrue(coordinator.insertionUnavailable, "the new flash owns a full window")
        XCTAssertEqual(coordinator.insertionNotice, "No access")
        XCTAssertTrue(coordinator.pillVisible)

        expiry.expire(1)
        XCTAssertFalse(coordinator.insertionUnavailable)
        XCTAssertFalse(coordinator.pillVisible)
    }

    func testNoticeExpiryDoesNotHideAnActiveRecording() {
        let expiry = ControlledNoticeExpiry()
        let coordinator = AppCoordinator(noticeExpiryScheduler: expiry.schedule, autoStart: false)
        coordinator.flashInsertionUnavailableNotice("Check the field")
        coordinator.state = .recording

        expiry.expire(0)
        XCTAssertFalse(coordinator.insertionUnavailable)
        XCTAssertTrue(coordinator.pillVisible, "capture still owns the pill")
    }
}
