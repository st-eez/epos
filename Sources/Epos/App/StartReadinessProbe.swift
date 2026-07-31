import AVFoundation
import Foundation

/// One resolution of whether the speech pipeline can open a dictation. The
/// coordinator publishes both halves together: a format means ready, and its
/// absence always comes with the named reason.
struct StartReadinessResolution {
    let captureFormat: AVAudioFormat?
    let blocker: StartBlocker?
}

/// Resolves whether the speech pipeline can open a dictation right now: the TCC
/// grants, the on-device speech model, and the analyzer's preferred capture format.
///
/// The launch resolution prompts and installs; every later one only reads, because
/// a fn press must never block on a multi-minute model download. That split is the
/// whole reason this is re-runnable — a launch that found the model still
/// installing, or a grant made afterwards in System Settings, used to leave the
/// pipeline dead until the next relaunch.
@MainActor
final class StartReadinessProbe {
    private let permissions: PermissionsGate
    private let assets: AssetManager
    private let transcriber: any SpeechTranscribing
    /// Bounded re-read of the speech asset for the re-check; injectable so the
    /// recovery path is testable without the Speech framework's inventory.
    private let refreshSpeechAsset: @Sendable () async -> AssetStatus
    private let log: EposLogger
    /// Every permission read in the app funnels through this probe, so a grant that
    /// arrives after launch is noticed exactly once, at no extra cost and with no
    /// polling of its own.
    private let onGrantsObserved: @MainActor (PermissionsSnapshot) -> Void

    init(
        permissions: PermissionsGate,
        assets: AssetManager,
        transcriber: any SpeechTranscribing,
        refreshSpeechAsset: @escaping @Sendable () async -> AssetStatus,
        log: EposLogger,
        onGrantsObserved: @escaping @MainActor (PermissionsSnapshot) -> Void
    ) {
        self.permissions = permissions
        self.assets = assets
        self.transcriber = transcriber
        self.refreshSpeechAsset = refreshSpeechAsset
        self.log = log
        self.onGrantsObserved = onGrantsObserved
    }

    /// Synchronous read of current permission grants (no prompts).
    func snapshotPermissions() -> PermissionsSnapshot {
        let snapshot = permissions.snapshot()
        onGrantsObserved(snapshot)
        return snapshot
    }

    /// The same read WITHOUT the observation hook, for the caller that is itself
    /// establishing the trust baseline the hook compares against: routing the fn
    /// monitor's own install-time read through the hook would have it tear out and
    /// reinstall the monitor it just put in.
    func currentGrants() -> PermissionsSnapshot {
        permissions.snapshot()
    }

    /// The launch resolution: prompt for permissions, install the locale asset, and
    /// resolve the analyzer's preferred audio format. One-shot because its TCC
    /// prompts are.
    func resolveAtLaunch() async -> StartReadinessResolution {
        let grants = await permissions.requestAll()
        onGrantsObserved(grants)
        // Anything short of an installed, reserved model is a reason the pipeline may
        // have no capture format. Naming it here is what keeps a dropped press from
        // blaming permissions for a model that is merely still downloading.
        let assetStatus = await assets.prepare()
        switch assetStatus {
        case .ready, .reserved:
            break
        case .failed(let message):
            log.error("bootstrap asset prepare failed: \(message)")
        case .downloading:
            log.info("bootstrap: speech model still downloading")
        case .missing:
            log.error("bootstrap: speech model not installed")
        }
        return await resolve(assetStatus: assetStatus, grants: grants)
    }

    /// Re-run the part of the launch resolution that can succeed later: the speech
    /// asset probe, a fresh (never prompting) grant read, and the format.
    func resolveAgain() async -> StartReadinessResolution {
        let assetStatus = await refreshSpeechAsset()
        return await resolve(assetStatus: assetStatus, grants: snapshotPermissions())
    }

    private func resolve(
        assetStatus: AssetStatus,
        grants: PermissionsSnapshot
    ) async -> StartReadinessResolution {
        let captureFormat = await transcriber.bestAudioFormat()
        return StartReadinessResolution(
            captureFormat: captureFormat,
            blocker: captureFormat == nil
                ? StartBlocker.resolve(assetStatus: assetStatus, grants: grants)
                : nil
        )
    }
}
