import AVFoundation
import Foundation
import SwiftUI

public enum CoordinatorState: Equatable {
    case idle
    case recording
    case finalizing
}

public enum FinalizationPhase: Equatable {
    /// Resting value and the first finalize stage (waiting for the final
    /// transcript). Idle reads of this are never shown; the UI only consults it
    /// while `state == .finalizing`.
    case finalizingSpeech
    case inserting
}

/// Coordinates readiness, fn presses and UI presentation.
/// Each RecordingSession owns one hold through recognition, final delivery and
/// cleanup. Its events update the published values the UI observes here.
@MainActor
public final class AppCoordinator: ObservableObject {
    /// `internal(set)` (not `private(set)`) only so latch tests can stage the
    /// finalize-window trigger; production code mutates it solely in this file.
    @Published public internal(set) var state: CoordinatorState = .idle
    @Published public private(set) var finalizationPhase: FinalizationPhase = .finalizingSpeech
    @Published public private(set) var finalText: String = ""
    @Published public private(set) var partial: String = ""
    @Published public private(set) var amplitude: Float = 0
    @Published public private(set) var settings: Settings
    /// True while the indicator pill flashes the dropped-start notice; read by `RecordingIndicator`.
    @Published public private(set) var startUnavailable = false
    /// What that notice says. It names the actual blocker — "Preparing" while the
    /// speech model installs, "Mic blocked" for a revoked grant — because a bare
    /// "Not ready" leaves the user with nothing to act on.
    @Published public private(set) var startNotice = StartReadiness.ready.noticeLabel
    /// True while the indicator reports that the guarded final write was refused.
    @Published public private(set) var insertionUnavailable = false
    /// What that notice says: "Not inserted" for a refused write, "No access" when
    /// the refusal was Accessibility being untrusted rather than a moved target.
    @Published public private(set) var insertionNotice = AppCoordinator.defaultInsertionNotice
    /// True while the indicator reports that the microphone died mid-recording and
    /// the dictation was cut short at that point.
    @Published public private(set) var microphoneUnavailable = false
    /// True while the indicator reports that speech recognition died while fn was
    /// still held: capture stops, and what was recognized before
    /// the failure is written at release.
    @Published public private(set) var recognitionUnavailable = false

    /// Running display: committed finals + in-progress partial, put through the
    /// recording's `streamClean(canonicalize(...))` — the SAME transform the one
    /// final write applies — so what the user watches is what gets written. The
    /// partial replaces only the tail because `SpeechTranscriber` emits volatile
    /// partials for the in-progress segment alongside committed per-segment finals.
    /// Stored, not computed: the transform runs once per recognizer event rather
    /// than once per SwiftUI read.
    @Published public private(set) var displayText: String = ""

    /// True while the inline preview is actively mirroring the volatile transcript
    /// into the fn-press field (begin acked, channel healthy this whole recording).
    @Published public private(set) var inlinePreviewMirroring = false

    /// What the HUD's transcript line shows: empty while the inline preview is
    /// mirroring the same text into the field, so the utterance appears once.
    /// Disabled, skipped, begin-refused, and degraded previews (including
    /// mid-recording degradation) all leave `inlinePreviewMirroring` false, which
    /// restores today's HUD line exactly.
    public var hudTranscriptPreview: String { inlinePreviewMirroring ? "" : displayText }

    /// True while the screen-edge glow is on. Internal so tests can pin it.
    var edgeGlowVisible: Bool { cues.edgeGlowVisible }
    var pillVisible: Bool { cues.pillVisible }

    /// Where setting mutations persist; injectable so tests never write the
    /// user's real defaults.
    private let settingsDefaults: UserDefaults
    private let hotkey: FnHotkey
    private let audio: any MicrophoneCapture
    private let transcriber: any SpeechTranscribing
    private let textInsertion: TextInsertionBackend
    private let insertionTargetObserverFactory: @MainActor () -> any InsertionTargetObserver
    private let recordingIDGenerator: @Sendable () -> String
    private let reliabilityDiagnostics: DiagnosticLogSink
    public static let defaultObservedEditCaptureDelays: [TimeInterval] = [2, 6, 12, 15]
    /// Shared correction rules: this coordinator canonicalizes against it; the Corrections
    /// editor mutates the same instance (the app hands the editor `coordinator.corrections`).
    public let corrections: CorrectionStore
    public let correctionEvidence: CorrectionEvidenceStore
    /// Internal, not private, only so the settings facade in
    /// `AppCoordinatorSettings.swift` can log its own writes.
    let log: EposLogger
    private let includeTranscriptTextInDiagnostics: Bool

    // MARK: - Collaborators
    //
    // All lazy because each is handed a callback into this coordinator, which
    // cannot be captured until `init` has finished.

    /// Resolves — and re-resolves after launch — whether the speech pipeline can
    /// open a dictation at all.
    private lazy var readinessProbe = StartReadinessProbe(
        permissions: permissions,
        assets: assets,
        transcriber: transcriber,
        refreshSpeechAsset: refreshSpeechAsset,
        log: log,
        onGrantsObserved: { [weak self] grants in
            self?.reinstallHotkeyMonitorIfAccessibilityTrustArrived(grants.accessibility)
        }
    )
    /// The on-screen cue for a dictation: glow, pill, or neither.
    private lazy var cues = RecordingCuePresenter { [unowned self] in
        RecordingIndicator(coordinator: self)
    }
    /// Keeps Electron apps' accessibility trees awake so the fn-press capture can
    /// see their focused element.
    private let electronAccessibilityWaker = ElectronAccessibilityWaker()
    /// Correction evidence for the dictation just written, and the post-insertion
    /// watch for the user's own edit of it. Internal so evidence tests can drive it
    /// without a live recording.
    lazy var evidenceRecorder = CorrectionEvidenceRecorder(
        evidence: correctionEvidence,
        captureDelays: observedEditCaptureDelays,
        currentRecordingID: { [weak self] in self?.currentRecordingID }
    )

    // Held only to build `readinessProbe`, which owns them from then on.
    private let permissions: PermissionsGate
    private let assets: AssetManager
    private let refreshSpeechAsset: @Sendable () async -> AssetStatus
    private let observedEditCaptureDelays: [TimeInterval]

    /// Distributed-notification tokens for the debug dictation trigger.
    private var debugTriggerObservers: [NSObjectProtocol] = []

    // MARK: - Recording ownership

    private var recordingSession: RecordingSession?
    /// Tests await the session's actual lifetime, including teardown and final delivery.
    var transcriptionTask: Task<Void, Never>? { recordingSession?.task }
    private var currentRecordingID: String? { recordingSession?.recordingID }
    /// Cached at bootstrap; nil until then. Internal so latch tests can install one.
    var captureFormat: AVAudioFormat?
    /// Mirrors the volatile transcript into the fn-press field as input-method
    /// marked text (`Settings.inlinePreview`, default on). Preview only — it is
    /// always discarded before the one authoritative write. Tests inject a fixed
    /// value; the app follows the live setting per recording.
    var inlinePreviewEnabled: Bool { inlinePreviewOverride ?? settings.inlinePreview }
    private let inlinePreviewOverride: Bool?

    // MARK: - Start readiness

    /// Single deferred-start latch, set when a press arrives while `startRecording`
    /// cannot run it yet: the finalize window (state != .idle) or the launch
    /// window before `bootstrap()` cached `captureFormat`. The key stays down, so the
    /// edge-triggered hotkey emits no new press — an unlatched press is silently
    /// dropped (23 real launch-window drops in 12 days of dogfood logs).
    /// `replayDeferredStartIfNeeded()` consumes it at whichever transition unblocks
    /// the start. Latch + replay task are internal so tests can pin the behavior.
    var pendingDeferredStart = false
    var deferredStartReplayTask: Task<Void, Never>?
    /// Live fn-key state consulted before replaying a latched press. Injectable so
    /// tests can pin both replay outcomes; defaults to the hotkey's hardware read.
    private let isFnKeyHeld: @MainActor () -> Bool
    private var didBootstrap = false
    /// `didBootstrap` only means bootstrap STARTED. This is set when it has run
    /// to completion, which is what tells a press with no capture format apart:
    /// mid-bootstrap it is a legitimate deferred start, after completion nothing
    /// will ever replay it. Internal so latch tests can stage the completed state
    /// without running the real permission prompts.
    var didCompleteBootstrap = false
    /// Why the last readiness resolution produced no capture format; nil when it
    /// produced one. Published so the menu banner can never claim "Ready to
    /// dictate" over a dead pipeline. `internal(set)` (not `private(set)`) only so
    /// recovery tests can stage a blocked launch; production code assigns it in
    /// this file alone.
    @Published public internal(set) var startBlocker: StartBlocker?
    /// In-flight readiness re-check, so a press and a menu open share one probe.
    private var readinessRefreshTask: Task<Void, Never>?
    /// The re-check-then-replay a post-bootstrap press kicks off. Internal so
    /// tests can await the whole recovery.
    var readinessRecoveryTask: Task<Void, Never>?
    /// Accessibility trust as it stood when the fn monitor was installed. `NSEvent`
    /// global keyboard monitors deliver only to a trusted process and do not
    /// retro-activate when the grant arrives, so a monitor installed before the
    /// first AX prompt is inert until it is reinstalled.
    private var monitorInstalledUnderTrust: PermissionStatus?
    private var didBindHotkey = false

    public init(
        hotkey: FnHotkey = FnHotkey(),
        audio: any MicrophoneCapture = AudioCapture(),
        transcriber: (any SpeechTranscribing)? = nil,
        textInsertion: TextInsertionBackend = KeystrokeTextInjector(),
        insertionTargetObserverFactory: (@MainActor () -> any InsertionTargetObserver)? = nil,
        settings: Settings = Settings.load(),
        settingsDefaults: UserDefaults = .standard,
        permissions: PermissionsGate = PermissionsGate(),
        refreshSpeechAsset: (@Sendable () async -> AssetStatus)? = nil,
        diagnostics: DiagnosticLogSink = .shared,
        corrections: CorrectionStore = CorrectionStore(),
        correctionEvidence: CorrectionEvidenceStore = CorrectionEvidenceStore(),
        recordingIDGenerator: @escaping @Sendable () -> String = RecordingID.make,
        isFnKeyHeld: (@MainActor () -> Bool)? = nil,
        observedEditCaptureDelays: [TimeInterval] = AppCoordinator.defaultObservedEditCaptureDelays,
        includeTranscriptTextInDiagnostics: Bool? = nil,
        inlinePreviewEnabled: Bool? = nil,
        autoStart: Bool = true
    ) {
        self.hotkey = hotkey
        self.audio = audio
        self.textInsertion = textInsertion
        self.insertionTargetObserverFactory = insertionTargetObserverFactory ?? {
            AXInsertionTargetObserver()
        }
        self.log = EposLogger(category: "coordinator", diagnostics: diagnostics)
        self.inlinePreviewOverride = inlinePreviewEnabled
        self.correctionEvidence = correctionEvidence
        self.corrections = corrections
        self.recordingIDGenerator = recordingIDGenerator
        self.reliabilityDiagnostics = diagnostics
        self.isFnKeyHeld = isFnKeyHeld ?? { [hotkey] in hotkey.isFunctionKeyDown }
        self.observedEditCaptureDelays = observedEditCaptureDelays
        self.includeTranscriptTextInDiagnostics =
            includeTranscriptTextInDiagnostics ?? TranscriptDiagnosticTextPolicy.load()
        self.settings = settings
        self.settingsDefaults = settingsDefaults
        self.permissions = permissions
        let assets = AssetManager(locale: settings.locale)
        self.assets = assets
        self.refreshSpeechAsset = refreshSpeechAsset ?? {
            // The re-check probe, deliberately not `prepare()`: a press must not
            // block on a multi-minute download. Read the status, and claim the
            // process-scoped reservation only when the model is already installed
            // — which is exactly the state a launch that gave up mid-download
            // wakes into.
            let status = await assets.currentStatus()
            guard case .ready = status else { return status }
            return await assets.prepare()
        }
        self.transcriber = transcriber ?? Transcriber(locale: settings.locale)
        if autoStart {
            bindHotkey()
            bindDebugDictationTriggerIfEnabled()
            // Bootstrap at launch, not on first menu-icon click. This used to hang
            // off `.task` on the MenuBarExtra content view, which SwiftUI builds
            // only when the popover first opens — so `captureFormat` stayed nil and
            // every fn press was dropped until the user happened to open the menu.
            Task { await self.bootstrap() }
        }
    }

    /// The authoritative final-transcript transform, built once per recording so a
    /// mid-session correction-rule edit cannot alter the finalization behavior of an
    /// already-running dictation. RecordingSession freezes the same canonicalizer
    /// for every streamed partial (`displayText`), so the one final write
    /// cannot re-type text differently from what the user watched on screen.
    func makeFinalTranscriptCleaner() -> @Sendable (String) -> String {
        let canonicalizer = corrections.canonicalizer
        return { TranscriptDeterministicCleaner.streamClean(canonicalizer.canonicalize($0)) }
    }

    func speechContextualStrings() -> [String] {
        ["Epos"] + corrections.canonicalizer.speechContextualStrings
    }

    // MARK: - Start readiness

    /// Synchronous read of current permission grants (no prompts).
    /// Used by MenuBarView to surface a warning row when something isn't granted.
    public func snapshotPermissions() -> PermissionsSnapshot {
        readinessProbe.snapshotPermissions()
    }

    /// Whether a fn press can open a dictation right now, and if not, why.
    public var startReadiness: StartReadiness {
        if captureFormat != nil { return .ready }
        if let startBlocker { return .blocked(startBlocker) }
        return .preparing
    }

    /// One-time launch wiring: prompt for permissions, install the locale asset,
    /// and cache the analyzer's preferred audio format. Safe to call repeatedly;
    /// downstream calls are idempotent.
    ///
    /// One-shot because its TCC prompts are. Everything after them — the readiness
    /// resolution itself — is re-checkable, and has to be: a launch that finds the
    /// model still installing (or a grant that arrives afterwards in System
    /// Settings) used to leave `captureFormat` nil until the next relaunch.
    public func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        log.info("bootstrap begin")
        if IndicatorWindowPolicy.canPresentWindows {
            // Same suppression as the cue windows: under the test runner the
            // waker must not write AX attributes into whatever app is frontmost
            // on the developer's machine.
            electronAccessibilityWaker.start()
        }
        apply(await readinessProbe.resolveAtLaunch())
        if settings.edgeGlow.enabled {
            cues.applyEdgeGlowStyle(settings.edgeGlow)
            cues.prewarmEdgeGlow()
        }
        didCompleteBootstrap = true
        log.info("bootstrap done format=\(String(describing: self.captureFormat))")
        replayDeferredStartIfNeeded()
    }

    /// Re-run the part of bootstrap that can succeed later: the speech asset probe,
    /// the analyzer's format resolution, and a fresh (never prompting) grant read.
    /// A no-op unless bootstrap finished without a capture format, and single-flight
    /// so a press and a menu open share one probe. Internal so recovery tests can
    /// await it.
    @discardableResult
    func refreshStartReadinessIfNeeded() -> Task<Void, Never>? {
        guard didCompleteBootstrap, captureFormat == nil else { return nil }
        if let readinessRefreshTask { return readinessRefreshTask }
        let task = Task { [weak self] in
            guard let self else { return }
            self.apply(await self.readinessProbe.resolveAgain())
            self.readinessRefreshTask = nil
            self.log.info(
                "readiness re-check: \(self.startBlocker?.logDescription ?? "capture format available")"
            )
        }
        readinessRefreshTask = task
        return task
    }

    private func apply(_ resolution: StartReadinessResolution) {
        captureFormat = resolution.captureFormat
        startBlocker = resolution.blocker
    }

    /// Reinstall the fn monitor the first time a grant is observed to have arrived
    /// after the monitor went in. Idempotent — the recorded trust advances with the
    /// reinstall — and never fires mid-recording, where tearing the monitor out
    /// would swallow the release that ends the hold.
    private func reinstallHotkeyMonitorIfAccessibilityTrustArrived(_ trust: PermissionStatus) {
        guard didBindHotkey else { return }
        guard trust == .granted else {
            monitorInstalledUnderTrust = trust
            return
        }
        guard monitorInstalledUnderTrust != .granted, state == .idle else { return }
        log.info("accessibility trust arrived after launch; reinstalling the fn monitor")
        hotkey.stop()
        hotkey.start()
        monitorInstalledUnderTrust = .granted
    }

    // MARK: - Deferred-start latch

    /// Replay a latched press at the transition that unblocked it (bootstrap
    /// completion or `.finalizing → .idle`), consuming the latch exactly once.
    /// Replays only while fn is still physically held — a key released while
    /// blocked is dropped — re-checked once after a short debounce so a key the
    /// user is mid-release on does not open a phantom session (observed live:
    /// a 161ms, zero-result recording). Internal so tests can pin both outcomes.
    func replayDeferredStartIfNeeded() {
        guard pendingDeferredStart else { return }
        pendingDeferredStart = false
        guard captureFormat != nil else {
            // The user held fn and spoke into a dead pipeline (permission denied or
            // asset download failed); an error log alone gives them zero feedback.
            log.error(
                "pending start dropped: capture format unavailable after bootstrap "
                    + "(\(self.startBlocker?.logDescription ?? "unknown"))"
            )
            flashStartUnavailableNotice()
            return
        }
        guard isFnKeyHeld() else {
            log.info("pending start dropped: fn released while start was blocked")
            return
        }
        deferredStartReplayTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 75_000_000)
            guard let self, self.state == .idle else { return }
            guard self.isFnKeyHeld() else {
                self.log.info("pending start dropped: fn released during replay debounce")
                return
            }
            self.log.info("replaying start: fn still held")
            self.startRecording()
        }
    }

    /// A press arriving after bootstrap finished without a capture format. That
    /// verdict goes stale: the model may have finished installing since, or a grant
    /// may have been made in System Settings. Report the press immediately — the
    /// user is holding fn right now and has to know it did not take — then re-check
    /// the re-checkable tail of bootstrap and replay the press through the ordinary
    /// latch. A recovery that lands while fn is still held starts the recording,
    /// which clears the notice; one that does not re-reports with the updated
    /// reason. Internal, with its task exposed, so recovery tests can await it.
    func startAfterReadinessRefresh() {
        log.error(
            "start dropped: no capture format after bootstrap "
                + "(\(self.startBlocker?.logDescription ?? "unknown")); re-checking readiness"
        )
        flashStartUnavailableNotice()
        pendingDeferredStart = true
        readinessRecoveryTask = Task { [weak self] in
            await self?.refreshStartReadinessIfNeeded()?.value
            // Drains the latch on both outcomes: a recovery replays the press
            // while fn is held, a persistent blocker re-reports it by name.
            self?.replayDeferredStartIfNeeded()
        }
    }

    // MARK: - Pill notices

    /// How long one of the pill's red notices stays up. Long enough to read a
    /// two-word label after the user's attention has returned to their own text.
    static let noticeFlashDuration: Duration = .milliseconds(2_500)

    /// Whether any red notice currently owns the pill. Every hide of the pill at
    /// rest must consult this: putting the panel away under a still-set flag
    /// leaves the indicator rendering a notice inside a hidden window.
    var anyNoticeVisible: Bool {
        startUnavailable || insertionUnavailable || microphoneUnavailable || recognitionUnavailable
    }

    /// Re-flashing the SAME notice restarts its window: the generation stamps
    /// each flash so a superseded timer no-ops instead of clearing the flag and
    /// hiding the pill out from under the newer flash (which may carry an
    /// updated label — the readiness re-check re-reports through this).
    private var noticeFlashGenerations: [ReferenceWritableKeyPath<AppCoordinator, Bool>: Int] = [:]

    /// Flash the recording pill with one of its red notices, then clear it and put
    /// the pill away if the coordinator is back at rest. Every notice behaves
    /// identically; only which flag the indicator reads differs.
    private func flashNotice(_ notice: ReferenceWritableKeyPath<AppCoordinator, Bool>) {
        let generation = (noticeFlashGenerations[notice] ?? 0) + 1
        noticeFlashGenerations[notice] = generation
        self[keyPath: notice] = true
        cues.showPill()
        Task { [weak self] in
            try? await Task.sleep(for: Self.noticeFlashDuration)
            guard let self, self.noticeFlashGenerations[notice] == generation,
                  self[keyPath: notice] else { return }
            self[keyPath: notice] = false
            // A newer notice may have flashed while this one was up; it owns the
            // pill until its own expiry.
            if self.state == .idle, !self.anyNoticeVisible { self.cues.hidePill() }
        }
    }

    /// A held-fn dictation was dropped because there is no capture format —
    /// bootstrap finished without one, it is still resolving one, or the mic
    /// refused to open. The label names the blocker; the default reads it off the
    /// current readiness, which is right for every caller that did not resolve a
    /// more specific one.
    func flashStartUnavailableNotice(_ label: String? = nil) {
        startNotice = label ?? startReadiness.noticeLabel
        flashNotice(\.startUnavailable)
    }

    static let defaultInsertionNotice = "Not inserted"

    /// Internal so the overlapping-notices regression test can flash two notices
    /// directly; production callers are all in this file.
    func flashInsertionUnavailableNotice(_ label: String = defaultInsertionNotice) {
        insertionNotice = label
        flashNotice(\.insertionUnavailable)
    }

    /// "Mic lost": distinct from "Not ready" because the dictation did start and the
    /// text captured before the mic died is still on its way to the field.
    private func flashMicrophoneUnavailableNotice() {
        flashNotice(\.microphoneUnavailable)
    }

    /// "Recognition lost": the recognizer's result stream failed mid-hold. The mic is
    /// still open and the key is still down, but no further words will be recognized —
    /// without this the user keeps talking into a session that stopped listening.
    private func flashRecognitionUnavailableNotice() {
        flashNotice(\.recognitionUnavailable)
    }

    // MARK: - Input wiring

    /// Internal so the monitor-reinstall behavior can be driven without the
    /// autoStart path, which also runs the real permission prompts.
    func bindHotkey() {
        hotkey.onPress = { [weak self] in self?.startRecording() }
        hotkey.onRelease = { [weak self] in self?.finishRecording() }
        hotkey.start()
        didBindHotkey = true
        // The trust the monitor just went in under. On a fresh install this is
        // `.denied` — the AX prompt has not been answered yet — and the monitor
        // macOS hands back is inert until the grant arrives and it is reinstalled.
        monitorInstalledUnderTrust = readinessProbe.currentGrants().accessibility
    }

    private func bindDebugDictationTriggerIfEnabled() {
        debugTriggerObservers = armDebugDictationTrigger(
            log: log,
            onStart: { [weak self] in self?.startRecording() },
            onFinish: { [weak self] in self?.finishRecording() }
        )
    }

    // MARK: - Recording lifecycle

    public func startRecording() {
        guard state == .idle else {
            // A press during the finalize window starts the user's next utterance:
            // latch it and replay when the coordinator returns to idle.
            if state == .finalizing {
                pendingDeferredStart = true
                log.info("start requested during finalize; will retry at idle if fn held")
            }
            return
        }
        guard let format = captureFormat else {
            guard !didCompleteBootstrap else {
                startAfterReadinessRefresh()
                return
            }
            // The launch window: fn pressed before bootstrap cached the format.
            // Latch the press instead of dropping it; `bootstrap()` replays it.
            // The latch is silent by itself, and on a first launch it can hold for
            // the whole model download — so say so, without disturbing the replay.
            pendingDeferredStart = true
            log.info("start requested before bootstrap completed; will replay when capture format is ready")
            flashStartUnavailableNotice()
            return
        }
        // Drop the prior recording's pending edit-capture polls: once new dictation
        // types into the field, a span read can no longer be attributed to the prior
        // transcript as a user edit. Burst dictation therefore under-collects
        // correction evidence by design — precision over recall; extending capture
        // past this point would record unrelated typing as an "edit".
        evidenceRecorder.cancelObservedEditCaptureChecks()
        state = .recording
        let session = makeRecordingSession(recordingID: recordingIDGenerator())
        recordingSession = session
        if let recordingID = session.recordingID { RecordingLogContext.activate(recordingID) }
        log.info("recording start")
        electronAccessibilityWaker.wakeFrontmostApplication()
        presentIndicatorForRecordingStart()
        finalizationPhase = .finalizingSpeech
        finalText = ""
        partial = ""
        displayText = ""
        amplitude = 0
        inlinePreviewMirroring = false
        startUnavailable = false
        insertionUnavailable = false
        microphoneUnavailable = false
        recognitionUnavailable = false
        session.start(format: format)
    }

    public func finishRecording() {
        guard state == .recording else { return }
        state = .finalizing
        finalizationPhase = .finalizingSpeech
        RecordingCue.playEnd()
        cues.hideEdgeGlow()
        recordingSession?.release()
    }

    private func makeRecordingSession(recordingID: String?) -> RecordingSession {
        var sessionSettings = settings
        sessionSettings.inlinePreview = inlinePreviewEnabled
        let canonicalizer = corrections.canonicalizer
        return RecordingSession(
            recordingID: recordingID,
            audio: audio,
            transcriber: transcriber,
            textInsertion: textInsertion,
            targetObserverFactory: insertionTargetObserverFactory,
            settings: sessionSettings,
            canonicalizer: canonicalizer,
            diagnostics: reliabilityDiagnostics,
            evidenceRecorder: evidenceRecorder,
            correctionEvidence: correctionEvidence,
            isFnKeyHeld: isFnKeyHeld,
            isMicrophoneAccessMissing: { [weak self] in self?.snapshotPermissions().microphone != .granted },
            includeTranscriptText: includeTranscriptTextInDiagnostics,
            onEvent: { [weak self] session, event in self?.handleSessionEvent(event, from: session) }
        )
    }

    /// Ignore callbacks belonging to a hold whose resources have already closed.
    private func handleSessionEvent(_ event: RecordingSession.Event, from session: RecordingSession) {
        guard recordingSession === session else { return }
        switch event {
        case .amplitude(let value):
            guard state == .recording else { return }
            amplitude = value
            cues.updateEdgeGlowAmplitude(value)
        case .transcript(let rawFinal, let rawPartial, let display):
            finalText = rawFinal
            partial = rawPartial
            displayText = display
        case .previewActivity(let active):
            inlinePreviewMirroringDidChange(active)
        case .firstMarkRendered:
            if state == .recording, inlinePreviewMirroring { cues.hidePill() }
        case .captureFailed:
            finishRecording()
            flashMicrophoneUnavailableNotice()
        case .recognitionFailedWhileHeld:
            cues.hideEdgeGlow()
            flashRecognitionUnavailableNotice()
        case .inserting:
            finalizationPhase = .inserting
        case .insertionUnavailable(let label):
            flashInsertionUnavailableNotice(label)
        case .completed(let startNotice):
            recordingSession = nil
            cues.hideEdgeGlow()
            if !anyNoticeVisible { cues.hidePill() }
            amplitude = 0
            partial = ""
            inlinePreviewMirroring = false
            finalizationPhase = .finalizingSpeech
            state = .idle
            replayDeferredStartIfNeeded()
            if let startNotice { flashStartUnavailableNotice(startNotice) }
        }
    }

    // MARK: - Test staging

    /// Tests can exercise assembly and routing without opening the microphone.
    private func stagedSession() -> RecordingSession {
        if let recordingSession { return recordingSession }
        let session = makeRecordingSession(recordingID: nil)
        recordingSession = session
        return session
    }

    func handlePartialTranscript(_ text: String) { stagedSession().handlePartialTranscript(text) }
    func handleFinalTranscriptSegment(_ text: String) { stagedSession().handleFinalTranscriptSegment(text) }
    func promotePartialTranscriptAsFallbackFinalIfNeeded() {
        stagedSession().promotePartialTranscriptAsFallbackFinalIfNeeded()
    }
    func logTranscriptTiming(kind: TranscriptTimingEventKind, eventText: String) {
        stagedSession().logTranscriptTiming(kind: kind, eventText: eventText)
    }

    // MARK: - Indicator presentation

    /// Internal so glow-lifetime tests can drive the presentation without a live
    /// audio pipeline.
    func presentIndicatorForRecordingStart() {
        // Delayed cue checks belong to the hold that requested them.
        let recordingID = currentRecordingID
        cues.presentForRecordingStart(
            glowEnabled: settings.edgeGlow.enabled,
            previewEnabled: inlinePreviewEnabled,
            previewStillUnconfirmed: { [weak self] in
                guard let self else { return false }
                return self.currentRecordingID == recordingID
                    && self.state == .recording
                    && !self.inlinePreviewMirroring
            }
        )
    }

    /// Whether the glow — rather than the pill — is the right indicator for the
    /// recording in progress. With the preview on the glow tracks the channel
    /// it advertises; with it off the glow owns every recording.
    private var glowOwnsCurrentRecording: Bool {
        state == .recording && (!inlinePreviewEnabled || inlinePreviewMirroring)
    }

    /// A glow style change has to reach the recording already in progress; the cue
    /// can never be left advertising something that is no longer true. Internal so
    /// the settings facade can call it.
    func applyEdgeGlowStyleToCurrentRecording(_ style: EdgeGlowSettings) {
        cues.applyEdgeGlowStyle(style)
        if style.enabled {
            cues.prewarmEdgeGlow()
            // Enabled mid-recording: light it now, and the pill (if it was the
            // indicator) yields as usual.
            if glowOwnsCurrentRecording {
                cues.showEdgeGlow()
                // The pill yields only while the preview mirrors the same text
                // into the field; otherwise it is the only view of the volatile
                // transcript and has to stay.
                if inlinePreviewMirroring { cues.hidePill() }
            }
        } else {
            // Disabled mid-recording: the pill must take over — hiding the
            // glow alone would leave a hot mic with no cue at all until
            // release (codex review, blocking).
            let handOffToPill = cues.edgeGlowVisible && state == .recording
            cues.hideEdgeGlow()
            if handOffToPill {
                cues.showPill()
            }
        }
    }

    /// The one place a setting is changed and persisted. Internal (not private) so
    /// the settings facade can reach it; `settings` itself stays `private(set)`, so
    /// this stays the only writer.
    func updateSettings(_ mutate: (inout Settings) -> Void) {
        mutate(&settings)
        settings.save(to: settingsDefaults)
    }

    // MARK: - Inline preview

    func makeInlinePreviewSession(
        bundleIdentifier: String?,
        transport: (any InlinePreviewTransport)? = nil
    ) -> InlinePreviewSession? {
        stagedSession().makeInlinePreviewSession(bundleIdentifier: bundleIdentifier, transport: transport)
    }

    /// The preview's channel became (or stopped being) healthy enough to mirror.
    ///
    /// A mid-recording degrade makes the HUD the only feedback again, so the pill
    /// comes back (with its transcript line, in the same update) and the glow
    /// retires with the channel it advertises. Activation is the mirror image: a
    /// begin ack slower than the fallback deadline arrives AFTER the pill took over
    /// — the glow reclaims the recording and the pill yields, otherwise the first
    /// mark would hide the pill and leave NO mic-hot cue at all (review finding,
    /// e90dcae..). On the fast path both calls are no-ops. At finalize
    /// `finishInlinePreview` clears the flag with state != .recording, skipping this.
    private func inlinePreviewMirroringDidChange(_ active: Bool) {
        inlinePreviewMirroring = active
        guard state == .recording else { return }
        if active, settings.edgeGlow.enabled {
            // With the glow disabled the pill stays the pre-text indicator; the
            // first mark hides it.
            cues.showEdgeGlow()
            cues.hidePill()
        } else if !active {
            cues.hideEdgeGlow()
            cues.showPill()
        }
    }

    func stageFinalizationSessions(
        inlinePreview: InlinePreviewSession?,
        insertion: FinalTranscriptInsertionSession?
    ) {
        stagedSession().stageFinalizationSessions(inlinePreview: inlinePreview, insertion: insertion)
    }

    func commitFinalTranscript(_ transcript: String) async -> FinalTranscriptCommitRouter.Route {
        await stagedSession().commitFinalTranscript(transcript)
    }

    func insertFinalTranscriptResult(_ text: String) -> FinalInsertionResult {
        stagedSession().insertFinalTranscriptResult(text)
    }
}
