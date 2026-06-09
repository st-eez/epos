import XCTest
@testable import Epos

/// A fn press in the launch window — before `bootstrap()` has cached `captureFormat` —
/// used to be silently dropped (23 real drops in 12 days of dogfood logs, every one a
/// press 2–5s before "bootstrap begin"). These pin the latch contract: the press is
/// latched instead of dropped, and the bootstrap-completion replay consumes the latch
/// exactly once without starting a recording it cannot run.
@MainActor
final class CoordinatorBootstrapLatchTests: XCTestCase {
    func testPressBeforeBootstrapLatchesInsteadOfDropping() {
        let coordinator = AppCoordinator(autoStart: false)

        coordinator.startRecording()

        // No capture format yet: the press must not start a session, but must latch.
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertTrue(coordinator.pendingStartAwaitingBootstrap)
    }

    func testReplayConsumesLatchAndStaysIdleWithoutCaptureFormat() {
        let coordinator = AppCoordinator(autoStart: false)
        coordinator.startRecording()
        XCTAssertTrue(coordinator.pendingStartAwaitingBootstrap)

        coordinator.replayPendingStartAfterBootstrapIfNeeded()

        // Format still unavailable: the latch is consumed (no replay storm on later
        // bootstraps) and no recording starts.
        XCTAssertFalse(coordinator.pendingStartAwaitingBootstrap)
        XCTAssertEqual(coordinator.state, .idle)
    }

    func testReplayWithoutPendingPressIsANoOp() {
        let coordinator = AppCoordinator(autoStart: false)

        coordinator.replayPendingStartAfterBootstrapIfNeeded()

        XCTAssertFalse(coordinator.pendingStartAwaitingBootstrap)
        XCTAssertEqual(coordinator.state, .idle)
    }
}
