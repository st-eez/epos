import AVFoundation
import XCTest
@testable import Epos

/// A fn press while `startRecording` cannot run it yet — the launch window before
/// `bootstrap()` has cached `captureFormat` (23 real drops in 12 days of dogfood
/// logs), or the finalize window — used to be silently dropped. These pin
/// the unified deferred-start latch contract: the press is latched instead of
/// dropped, the replay consumes the latch exactly once, replays only while fn is
/// still physically held (including a debounce re-check so an in-progress release
/// does not open a phantom session), and a replay with no capture format flashes
/// the user-visible "Not ready" notice instead of failing silently.
@MainActor
final class CoordinatorDeferredStartLatchTests: XCTestCase {
    /// Mutable stand-in for the live fn hardware read, handed to the coordinator's
    /// injectable `isFnKeyHeld` provider.
    private final class FnKeyState {
        var held = false
    }

    private final class StartCounter: @unchecked Sendable {
        var count = 0
    }

    private let fn = FnKeyState()
    private let started = StartCounter()

    private func makeCoordinator() -> AppCoordinator {
        let started = started
        return AppCoordinator(
            textInsertion: NoOpInsertionBackend(),
            settings: Settings(),
            recordingIDGenerator: {
                started.count += 1
                return "deferred-start-test-\(started.count)"
            },
            isFnKeyHeld: { [fn] in fn.held },
            autoStart: false
        )
    }

    private static func makeFormat() -> AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    }

    func testPressBeforeBootstrapLatchesInsteadOfDropping() {
        let coordinator = makeCoordinator()

        coordinator.startRecording()

        // No capture format yet: the press must not start a session, but must latch.
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertTrue(coordinator.pendingDeferredStart)
        XCTAssertEqual(started.count, 0)
    }

    func testReplayConsumesLatchAndFlashesNoticeWithoutCaptureFormat() {
        let coordinator = makeCoordinator()
        fn.held = true
        coordinator.startRecording()
        XCTAssertTrue(coordinator.pendingDeferredStart)

        coordinator.replayDeferredStartIfNeeded()

        // Format still unavailable: the latch is consumed (no replay storm on later
        // bootstraps), no recording starts, and the drop is no longer silent — the
        // user held fn and spoke, so the indicator flashes "Not ready".
        XCTAssertFalse(coordinator.pendingDeferredStart)
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(started.count, 0)
        XCTAssertTrue(coordinator.startUnavailable)
    }

    /// Bootstrap already finished and produced no capture format (speech denied,
    /// asset install failed). Latching here would be a black hole: the one-shot
    /// replay is spent and the only other drain needs a `.finalizing → .idle`
    /// transition that a never-starting recording cannot produce. Every press
    /// must instead report itself.
    func testPressAfterCompletedBootstrapWithoutCaptureFormatReportsInsteadOfLatching() {
        let coordinator = makeCoordinator()
        coordinator.didCompleteBootstrap = true
        fn.held = true

        coordinator.startRecording()

        XCTAssertFalse(coordinator.pendingDeferredStart)
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(started.count, 0)
        XCTAssertTrue(coordinator.startUnavailable)
    }

    /// The notice is not one-shot: a second press with the pipeline still dead
    /// must report again rather than fall into the silent latch.
    func testRepeatedPressesAfterCompletedNilBootstrapKeepReporting() {
        let coordinator = makeCoordinator()
        coordinator.didCompleteBootstrap = true
        fn.held = true

        coordinator.startRecording()
        coordinator.startRecording()

        XCTAssertFalse(coordinator.pendingDeferredStart)
        XCTAssertTrue(coordinator.startUnavailable)
        XCTAssertEqual(started.count, 0)
    }

    func testReplayWithoutPendingPressIsANoOp() {
        let coordinator = makeCoordinator()

        coordinator.replayDeferredStartIfNeeded()

        XCTAssertFalse(coordinator.pendingDeferredStart)
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertNil(coordinator.deferredStartReplayTask)
    }

    func testBootstrapReplayStartsRecordingWhileFnHeld() async {
        let coordinator = makeCoordinator()
        fn.held = true
        coordinator.startRecording()
        XCTAssertTrue(coordinator.pendingDeferredStart)

        coordinator.captureFormat = Self.makeFormat()
        coordinator.replayDeferredStartIfNeeded()
        await coordinator.deferredStartReplayTask?.value

        XCTAssertEqual(started.count, 1)
        XCTAssertEqual(coordinator.state, .recording)
        XCTAssertFalse(coordinator.pendingDeferredStart)
        coordinator.finishRecording()
    }

    func testBootstrapReplayDropsLatchWhenFnReleased() async {
        let coordinator = makeCoordinator()
        fn.held = true
        coordinator.startRecording()
        fn.held = false

        coordinator.captureFormat = Self.makeFormat()
        coordinator.replayDeferredStartIfNeeded()
        await coordinator.deferredStartReplayTask?.value

        XCTAssertEqual(started.count, 0)
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertFalse(coordinator.pendingDeferredStart)
    }

    func testFinalizeWindowPressLatchesAndReplaysWhileFnHeld() async {
        let coordinator = makeCoordinator()
        coordinator.captureFormat = Self.makeFormat()
        fn.held = true
        coordinator.state = .finalizing

        coordinator.startRecording()
        XCTAssertTrue(coordinator.pendingDeferredStart)
        XCTAssertEqual(started.count, 0)

        // The `.finalizing → .idle` transition replays through the same latch.
        coordinator.state = .idle
        coordinator.replayDeferredStartIfNeeded()
        await coordinator.deferredStartReplayTask?.value

        XCTAssertEqual(started.count, 1)
        XCTAssertEqual(coordinator.state, .recording)
        coordinator.finishRecording()
    }

    func testFinalizeWindowPressDropsWhenFnReleased() async {
        let coordinator = makeCoordinator()
        coordinator.captureFormat = Self.makeFormat()
        fn.held = false
        coordinator.state = .finalizing

        coordinator.startRecording()
        XCTAssertTrue(coordinator.pendingDeferredStart)

        coordinator.state = .idle
        coordinator.replayDeferredStartIfNeeded()
        await coordinator.deferredStartReplayTask?.value

        XCTAssertEqual(started.count, 0)
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertFalse(coordinator.pendingDeferredStart)
    }

    func testReplayDropsWhenFnReleasedDuringDebounce() async {
        let coordinator = makeCoordinator()
        fn.held = true
        coordinator.startRecording()
        coordinator.captureFormat = Self.makeFormat()

        // The immediate held check passes synchronously inside the call; releasing
        // fn before awaiting models a key the user was mid-release on. The debounce
        // re-check must catch it and not open a phantom session.
        coordinator.replayDeferredStartIfNeeded()
        fn.held = false
        await coordinator.deferredStartReplayTask?.value

        XCTAssertEqual(started.count, 0)
        XCTAssertEqual(coordinator.state, .idle)
    }
}

private final class NoOpInsertionBackend: TextInsertionBackend {
    func startInsertionSession() -> any TextInsertionSession {
        NoOpInsertionSession()
    }
}

private final class NoOpInsertionSession: TextInsertionSession {
    func insert(_ text: String) -> Bool { true }
    func finish() {}
    func cancel() {}
}
