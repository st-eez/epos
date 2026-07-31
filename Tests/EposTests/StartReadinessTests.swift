import AVFoundation
import XCTest
@testable import Epos

/// What the app tells the user about a pipeline that cannot dictate: which
/// blocker gets named, what the menu banner says, and the fn monitor's recovery
/// when Accessibility trust arrives after launch.
///
/// The grants themselves are not settable from a test process, so the gate's
/// three reads are injected. Whether macOS actually withholds global key events
/// from an untrusted process is an external contract, verifiable only on a
/// machine that has never granted Epos Accessibility.
@MainActor
final class StartReadinessTests: XCTestCase {
    private let allGranted = PermissionsSnapshot(
        microphone: .granted,
        speech: .granted,
        accessibility: .granted
    )

    /// A model that is merely still installing must never be reported as a
    /// permission problem: that misblame is what sent dogfood triage after TCC for
    /// a download that simply had not finished.
    func testAnInstallingModelOutranksTheGrants() {
        let blocker = StartBlocker.resolve(
            assetStatus: .downloading(progress: 0.4),
            grants: PermissionsSnapshot(microphone: .denied, speech: .denied, accessibility: .denied)
        )

        XCTAssertEqual(blocker, .speechModelInstalling)
        XCTAssertEqual(blocker.noticeLabel, "Preparing")
    }

    func testMissingAndFailedModelsBothReportTheModel() {
        XCTAssertEqual(
            StartBlocker.resolve(assetStatus: .missing, grants: allGranted),
            .speechModelUnavailable("not installed")
        )
        XCTAssertEqual(
            StartBlocker.resolve(assetStatus: .failed(message: "disk full"), grants: allGranted),
            .speechModelUnavailable("disk full")
        )
    }

    func testGrantsAreNamedOnceTheModelIsInPlace() {
        XCTAssertEqual(
            StartBlocker.resolve(
                assetStatus: .reserved,
                grants: PermissionsSnapshot(microphone: .granted, speech: .denied, accessibility: .granted)
            ),
            .speechDenied
        )
        XCTAssertEqual(
            StartBlocker.resolve(
                assetStatus: .reserved,
                grants: PermissionsSnapshot(
                    microphone: .notDetermined,
                    speech: .granted,
                    accessibility: .granted
                )
            ),
            .microphoneDenied
        )
    }

    /// Everything in place and still no format: say that, rather than picking a
    /// grant at random to blame.
    func testAModelAndGrantsInPlaceReportTheEngine() {
        XCTAssertEqual(
            StartBlocker.resolve(assetStatus: .ready, grants: allGranted),
            .speechEngineUnavailable
        )
    }

    /// The menu banner used to derive readiness from grants alone, so it read
    /// "Ready to dictate" while every press flashed "Not ready".
    func testEveryBlockerHasSomethingActionableToShow() {
        let blockers: [StartBlocker] = [
            .speechModelInstalling,
            .speechModelUnavailable("not installed"),
            .microphoneDenied,
            .speechDenied,
            .speechEngineUnavailable,
        ]
        for blocker in blockers {
            XCTAssertFalse(blocker.noticeLabel.isEmpty, "\(blocker) has no pill label")
            XCTAssertFalse(blocker.bannerSubtitle.isEmpty, "\(blocker) has no banner line")
            XCTAssertFalse(blocker.logDescription.isEmpty, "\(blocker) has no log detail")
        }
    }

    func testTheBannerNamesTheGrantsThatAreActuallyMissing() {
        XCTAssertEqual(
            MenuBarView.missingPermissionNames(
                PermissionsSnapshot(microphone: .granted, speech: .granted, accessibility: .denied)
            ),
            ["Accessibility"]
        )
        XCTAssertEqual(
            MenuBarView.missingPermissionNames(
                PermissionsSnapshot(microphone: .denied, speech: .notDetermined, accessibility: .granted)
            ),
            ["Microphone", "Speech Recognition"]
        )
        XCTAssertEqual(MenuBarView.missingPermissionNames(allGranted), [])
    }

    /// `NSEvent` global keyboard monitors deliver only to an Accessibility-trusted
    /// process and do not retro-activate when the grant lands, so the monitor a
    /// fresh install starts with is inert — historically until an unannounced
    /// relaunch. Any permission read the app already makes is enough to notice.
    func testTheFnMonitorIsReinstalledWhenAccessibilityTrustArrives() {
        let monitors = MonitorInstallLog()
        let grants = MutablePermissionGrants(accessibility: .denied)
        let coordinator = makeCoordinator(monitors: monitors, grants: grants)

        coordinator.bindHotkey()
        XCTAssertEqual(monitors.installs, 1)
        XCTAssertEqual(monitors.removals, 0)

        grants.accessibility = .granted
        _ = coordinator.snapshotPermissions()

        XCTAssertEqual(monitors.removals, 1)
        XCTAssertEqual(monitors.installs, 2, "the inert monitor has to be replaced")
    }

    /// Idempotent: the grant is noticed once, not on every permission read.
    func testTheMonitorIsNotReinstalledOnEveryPermissionRead() {
        let monitors = MonitorInstallLog()
        let grants = MutablePermissionGrants(accessibility: .denied)
        let coordinator = makeCoordinator(monitors: monitors, grants: grants)
        coordinator.bindHotkey()

        grants.accessibility = .granted
        _ = coordinator.snapshotPermissions()
        _ = coordinator.snapshotPermissions()
        _ = coordinator.snapshotPermissions()

        XCTAssertEqual(monitors.installs, 2)
    }

    /// A process that was already trusted when the monitor went in has a working
    /// monitor; tearing it out would only risk dropping a press.
    func testAnAlreadyTrustedProcessKeepsItsMonitor() {
        let monitors = MonitorInstallLog()
        let grants = MutablePermissionGrants(accessibility: .granted)
        let coordinator = makeCoordinator(monitors: monitors, grants: grants)
        coordinator.bindHotkey()

        _ = coordinator.snapshotPermissions()

        XCTAssertEqual(monitors.installs, 1)
        XCTAssertEqual(monitors.removals, 0)
    }

    /// The reinstall must never run mid-hold: `stop()` drops the tracked key state,
    /// so the release that ends the recording would be swallowed by the edge guard
    /// and the mic would stay hot.
    func testTheMonitorIsNotReinstalledDuringARecording() async {
        let monitors = MonitorInstallLog()
        let grants = MutablePermissionGrants(accessibility: .denied)
        let coordinator = makeCoordinator(monitors: monitors, grants: grants)
        coordinator.bindHotkey()
        coordinator.captureFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)
        coordinator.startRecording()

        grants.accessibility = .granted
        _ = coordinator.snapshotPermissions()
        XCTAssertEqual(monitors.installs, 1, "not while the key is down")

        coordinator.finishRecording()
        await coordinator.transcriptionTask?.value

        // Still pending, so the first read after the recording picks it up.
        _ = coordinator.snapshotPermissions()
        XCTAssertEqual(monitors.installs, 2)
    }

    private func makeCoordinator(
        monitors: MonitorInstallLog,
        grants: MutablePermissionGrants
    ) -> AppCoordinator {
        AppCoordinator(
            hotkey: FnHotkey(
                hardwareStateReader: { false },
                installMonitor: { _ in monitors.install() },
                removeMonitor: { _ in monitors.remove() }
            ),
            audio: FakeMicrophoneCapture(),
            transcriber: FakeTranscriber(),
            textInsertion: NoOpInsertionBackend(),
            settings: Settings(),
            permissions: grants.gate,
            inlinePreviewEnabled: false,
            autoStart: false
        )
    }
}

/// Counts monitor installs and removals in place of a real global event monitor.
@MainActor
private final class MonitorInstallLog {
    private(set) var installs = 0
    private(set) var removals = 0

    func install() -> Any? {
        installs += 1
        return installs as NSNumber
    }

    func remove() {
        removals += 1
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
