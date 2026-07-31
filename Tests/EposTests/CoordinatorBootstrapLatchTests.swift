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

    /// The speech asset the readiness re-check sees, mutable between reads so a
    /// model that finishes installing after launch can be staged.
    private final class AssetState: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: AssetStatus = .downloading(progress: 0.5)
        var status: AssetStatus {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    private let fn = FnKeyState()
    private let started = StartCounter()
    /// `startRecording` opens the mic synchronously, so these tests have to hand it
    /// one that is not the machine's real input device.
    private let audio = FakeMicrophoneCapture()
    /// The re-check resolves the capture format through the transcriber, so the
    /// recovery paths need one that is not the live `SpeechAnalyzer`.
    private let transcriber = FakeTranscriber()
    private let assets = AssetState()

    private func makeCoordinator() -> AppCoordinator {
        let started = started
        // These tests own `captureFormat` directly; the transcriber only matters
        // once a re-check re-resolves it.
        transcriber.audioFormat = nil
        return AppCoordinator(
            audio: audio,
            transcriber: transcriber,
            textInsertion: NoOpInsertionBackend(),
            settings: Settings(),
            permissions: .stub(),
            refreshSpeechAsset: { [assets] in assets.status },
            recordingIDGenerator: {
                started.count += 1
                return "deferred-start-test-\(started.count)"
            },
            isFnKeyHeld: { [fn] in fn.held },
            autoStart: false
        )
    }

    /// Runs the re-check-and-replay a post-bootstrap press starts, plus the replay's
    /// own debounce, so the test observes the settled outcome.
    private func settleRecovery(_ coordinator: AppCoordinator) async {
        await coordinator.readinessRecoveryTask?.value
        await coordinator.deferredStartReplayTask?.value
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

    /// The latch alone is silent, and on a first launch it can hold for a whole
    /// model download — minutes of holding fn and speaking with no glow, no pill
    /// and no bell. The press has to say what it is waiting for.
    func testPressBeforeBootstrapSaysWhatItIsWaitingFor() {
        let coordinator = makeCoordinator()

        coordinator.startRecording()

        XCTAssertTrue(coordinator.startUnavailable)
        XCTAssertEqual(coordinator.startNotice, "Preparing")
        XCTAssertEqual(coordinator.startReadiness, .preparing)
        XCTAssertTrue(coordinator.pendingDeferredStart, "the notice must not cost the replay")
    }

    /// ...and the replay that succeeds must not leave that notice on screen behind
    /// a recording that is now running.
    func testReplayThatStartsRecordingClearsTheWaitingNotice() async {
        let coordinator = makeCoordinator()
        fn.held = true
        coordinator.startRecording()
        XCTAssertTrue(coordinator.startUnavailable)

        coordinator.captureFormat = Self.makeFormat()
        coordinator.replayDeferredStartIfNeeded()
        await coordinator.deferredStartReplayTask?.value

        XCTAssertEqual(coordinator.state, .recording)
        XCTAssertFalse(coordinator.startUnavailable)
        coordinator.finishRecording()
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

    /// Bootstrap already finished and produced no capture format (the model was
    /// still installing, speech was denied). The press reports itself immediately —
    /// the user is holding fn right now — and the latch it sets is always drained by
    /// the re-check that follows, so it can never become the black hole a bare latch
    /// here would be: the one-shot bootstrap replay is spent, and the only other
    /// drain needs a `.finalizing → .idle` transition a never-starting recording
    /// cannot produce.
    func testPressAfterCompletedBootstrapReportsImmediatelyAndKeepsTheBlockerNamed() async {
        let coordinator = makeCoordinator()
        coordinator.didCompleteBootstrap = true
        assets.status = .downloading(progress: 0.5)
        fn.held = true

        coordinator.startRecording()
        XCTAssertTrue(coordinator.startUnavailable, "feedback cannot wait on the re-check")

        await settleRecovery(coordinator)

        XCTAssertFalse(coordinator.pendingDeferredStart, "the latch is always drained")
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(started.count, 0)
        XCTAssertTrue(coordinator.startUnavailable)
        XCTAssertEqual(coordinator.startBlocker, .speechModelInstalling)
        XCTAssertEqual(coordinator.startNotice, "Preparing")
    }

    /// The one-shot bootstrap left a launch that found the model still installing
    /// dead until the next relaunch: `captureFormat` was assigned exactly once, so
    /// every later press flashed "Not ready" no matter how long ago the install
    /// finished. A press now re-checks, and a recovery that lands while fn is still
    /// held goes straight into the recording the user is holding for.
    func testPressAfterCompletedBootstrapRecoversWhenTheModelLands() async {
        let coordinator = makeCoordinator()
        coordinator.didCompleteBootstrap = true
        coordinator.startBlocker = .speechModelInstalling
        fn.held = true
        // The install finished between launch and this press.
        assets.status = .reserved
        transcriber.audioFormat = Self.makeFormat()

        coordinator.startRecording()
        await settleRecovery(coordinator)

        XCTAssertEqual(coordinator.state, .recording)
        XCTAssertEqual(started.count, 1)
        XCTAssertNil(coordinator.startBlocker)
        XCTAssertEqual(coordinator.startReadiness, .ready)
        XCTAssertFalse(coordinator.startUnavailable, "the recovered start clears its own notice")
        coordinator.finishRecording()
    }

    /// A grant made in System Settings after launch is the other way the same
    /// pipeline comes back to life.
    func testReadinessRecheckClearsAResolvedBlocker() async {
        let coordinator = makeCoordinator()
        coordinator.didCompleteBootstrap = true
        coordinator.startBlocker = .speechDenied
        assets.status = .reserved
        transcriber.audioFormat = Self.makeFormat()

        await coordinator.refreshStartReadinessIfNeeded()?.value

        XCTAssertNotNil(coordinator.captureFormat)
        XCTAssertNil(coordinator.startBlocker)
    }

    /// The re-check is a no-op on a live pipeline: it must not re-probe the asset
    /// inventory on every press once a format exists.
    func testReadinessRecheckIsSkippedWhenTheFormatAlreadyExists() {
        let coordinator = makeCoordinator()
        coordinator.didCompleteBootstrap = true
        coordinator.captureFormat = Self.makeFormat()

        XCTAssertNil(coordinator.refreshStartReadinessIfNeeded())
    }

    /// The notice is not one-shot: a second press with the pipeline still dead
    /// must report again rather than fall into a silent latch.
    func testRepeatedPressesAfterCompletedNilBootstrapKeepReporting() async {
        let coordinator = makeCoordinator()
        coordinator.didCompleteBootstrap = true
        assets.status = .missing
        fn.held = true

        coordinator.startRecording()
        await settleRecovery(coordinator)
        coordinator.startRecording()
        await settleRecovery(coordinator)

        XCTAssertFalse(coordinator.pendingDeferredStart)
        XCTAssertTrue(coordinator.startUnavailable)
        XCTAssertEqual(coordinator.startNotice, "No model")
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
