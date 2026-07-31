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

/// Owns the recording state machine: what a fn press and a fn release do, and one
/// dictation's flow from mic open through recognition and assembly to the single
/// authoritative final write.
///
/// Everything the UI observes lives here as published state; the subsystems it
/// drives — readiness resolution, the on-screen cue, the inline preview, and
/// correction-evidence capture — are collaborators it delegates to.
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
    /// still held: nothing more will be recognized, and what was recognized before
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
    public let corrections = CorrectionStore()
    public let correctionEvidence: CorrectionEvidenceStore
    // Opt-in `.wav` capture for local eval material. Disabled by default.
    private let dogfood = DogfoodTap()
    /// Internal, not private, only so the settings facade in
    /// `AppCoordinatorSettings.swift` can log its own writes.
    let log: EposLogger
    private let injectLog: EposLogger
    private var transcriptTiming: TranscriptTimingDiagnostics

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
    /// One recording's inline-preview session.
    private lazy var preview = InlinePreviewCoordinator(
        isEnabled: { [weak self] in self?.inlinePreviewEnabled ?? false },
        log: injectLog,
        onMarkingActivityChange: { [weak self] active in
            self?.inlinePreviewMirroringDidChange(active)
        },
        onFirstMarkRendered: { [weak self] in
            // The first letter just landed in the field: the fallback pill (if the
            // slow-begin path showed it) yields to the in-field provisional text.
            // The glow stays — it frames the whole dictation.
            guard let self, self.state == .recording, self.inlinePreviewMirroring else { return }
            self.cues.hidePill()
        }
    )
    /// Correction evidence for the dictation just written, and the post-insertion
    /// watch for the user's own edit of it. Internal so evidence tests can drive it
    /// without a live recording.
    lazy var evidenceRecorder = CorrectionEvidenceRecorder(
        corrections: corrections,
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

    // MARK: - Per-recording state

    /// Internal so tests can await one recording's full finalize.
    var transcriptionTask: Task<Void, Never>?
    /// Finalizes parked until the fn release, resumed by `finishRecording`. Only the
    /// recognizer-failed-mid-hold path parks, so this holds at most one waiter.
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    /// The running recording's transform, shared by the streamed display and the
    /// one final write so they cannot diverge. Built once per recording, so a
    /// mid-dictation correction-rule edit cannot change either of them.
    private var activeTranscriptCleaner: (@Sendable (String) -> String)?
    /// Cached at bootstrap; nil until then. Internal so latch tests can install one.
    var captureFormat: AVAudioFormat?
    private var textInsertionSession: FinalTranscriptInsertionSession?
    private var currentRecordingID: String?
    private var currentReliabilityRecording: ReliabilityRecording?
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
        self.injectLog = EposLogger(category: "inject", diagnostics: diagnostics)
        self.inlinePreviewOverride = inlinePreviewEnabled
        self.correctionEvidence = correctionEvidence
        self.recordingIDGenerator = recordingIDGenerator
        self.reliabilityDiagnostics = diagnostics
        self.isFnKeyHeld = isFnKeyHeld ?? { [hotkey] in hotkey.isFunctionKeyDown }
        self.observedEditCaptureDelays = observedEditCaptureDelays
        self.transcriptTiming = TranscriptTimingDiagnostics(
            includeTranscriptText: includeTranscriptTextInDiagnostics ?? TranscriptDiagnosticTextPolicy.load()
        )
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
    /// already-running dictation. The same closure is held as `activeTranscriptCleaner`
    /// and applied to every streamed partial (`displayText`), so the one final write
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

    /// Flash the recording pill with one of its red notices, then clear it and put
    /// the pill away if the coordinator is back at rest. Every notice behaves
    /// identically; only which flag the indicator reads differs.
    private func flashNotice(_ notice: ReferenceWritableKeyPath<AppCoordinator, Bool>) {
        self[keyPath: notice] = true
        cues.showPill()
        Task { [weak self] in
            try? await Task.sleep(for: Self.noticeFlashDuration)
            guard let self, self[keyPath: notice] else { return }
            self[keyPath: notice] = false
            if self.state == .idle { self.cues.hidePill() }
        }
    }

    /// A held-fn dictation was dropped because there is no capture format —
    /// bootstrap finished without one, it is still resolving one, or the mic
    /// refused to open. The label names the blocker; the default reads it off the
    /// current readiness, which is right for every caller that did not resolve a
    /// more specific one.
    private func flashStartUnavailableNotice(_ label: String? = nil) {
        startNotice = label ?? startReadiness.noticeLabel
        flashNotice(\.startUnavailable)
    }

    static let defaultInsertionNotice = "Not inserted"

    private func flashInsertionUnavailableNotice(_ label: String = defaultInsertionNotice) {
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
        let recordingID = recordingIDGenerator()
        currentRecordingID = recordingID
        RecordingLogContext.activate(recordingID)
        log.info("recording start")
        // Feedback first, work second: the glow (or pill) lands before the
        // synchronous AX baseline capture below, which can stall for hundreds of
        // milliseconds on slow accessibility targets.
        presentIndicatorForRecordingStart()
        let reliability = ReliabilityRecording(
            recordingID: recordingID,
            diagnostics: reliabilityDiagnostics
        )
        currentReliabilityRecording = reliability
        finalizationPhase = .finalizingSpeech
        finalText = ""
        partial = ""
        displayText = ""
        amplitude = 0
        startUnavailable = false
        insertionUnavailable = false
        microphoneUnavailable = false
        recognitionUnavailable = false

        let preRoll = CapturePreRoll()
        do {
            try openMicrophone(
                format: format,
                reliability: reliability,
                recordingID: recordingID,
                preRoll: preRoll
            )
        } catch {
            abortRecordingStart(reliability: reliability, recordingID: recordingID, error: error)
            return
        }
        // After the open, so the bell means the mic is actually hot.
        RecordingCue.playStart()

        textInsertionSession = FinalTranscriptInsertionSession(
            insertionSession: textInsertion.startInsertionSession(),
            target: insertionTargetObserverFactory(),
            recordingID: recordingID
        )
        startInlinePreview()
        transcriptTiming.start()
        let cleanFinalTranscript = makeFinalTranscriptCleaner()
        activeTranscriptCleaner = cleanFinalTranscript
        let contextualStrings = speechContextualStrings()

        transcriptionTask = Task { [weak self] in
            await self?.runSession(
                preRoll: preRoll,
                cleanFinalTranscript: cleanFinalTranscript,
                contextualStrings: contextualStrings
            )
        }
    }

    /// Open the mic and point the tap at this recording.
    ///
    /// This runs BEFORE the AX baseline capture and before the analyzer start; both
    /// of those used to come first, and every word spoken in that window was gone
    /// (dogfood logs: press → capture-started median 111ms, p90 272ms, worst case
    /// 2.6s, the tail of which produced whole recordings with no input at all).
    /// Nothing forced that order — `captureFormat` is cached at bootstrap precisely
    /// so opening the mic needs no await. Buffers captured before the analyzer
    /// exists queue in `preRoll` instead of being dropped.
    private func openMicrophone(
        format: AVAudioFormat,
        reliability: ReliabilityRecording,
        recordingID: String,
        preRoll: CapturePreRoll
    ) throws {
        audio.onBuffer = { [preRoll] buffer in
            reliability.recordAudioBuffer(frameCount: Int(buffer.frameLength))
            preRoll.accept(buffer)
        }
        audio.onAmplitude = { [weak self] amp in
            Task { @MainActor in
                guard let self, self.state == .recording else { return }
                self.amplitude = amp
                self.cues.updateEdgeGlowAmplitude(amp)
            }
        }
        audio.onRawBuffer = settings.saveAudioSamples
            ? { [dogfood] buffer in dogfood.write(buffer, recordingID: recordingID) }
            : nil
        audio.onCaptureFailure = { [weak self] error in
            self?.endRecordingAfterCaptureFailure(error)
        }
        try audio.start(targetFormat: format)
    }

    /// The mic never opened, so the recording that was just announced has to be
    /// taken back: the glow is up but no start cue played and nothing downstream
    /// exists yet (no insertion session, no preview, no transcription task).
    private func abortRecordingStart(
        reliability: ReliabilityRecording,
        recordingID: String,
        error: Error
    ) {
        log.error("recording setup failed: capture start (\(String(describing: error)))")
        reliability.emit(.setupFailed)
        currentReliabilityRecording = nil
        clearAudioCallbacks()
        cues.hideEdgeGlow()
        amplitude = 0
        log.info("recording done (finalChars=0 failed=true)")
        returnToIdleAndCompleteRecordingLogScope(finishedRecordingID: recordingID)
        flashStartUnavailableNotice()
    }

    /// The microphone died mid-hold and could not be recovered (an input-device
    /// change the engine could not be restarted through). The glow and the start
    /// cue have been advertising a live mic, so end the recording exactly as a
    /// release does — whatever was recognized before the mic went away is still
    /// written — and flash the notice so the truncation is not silent.
    ///
    /// The interruption is the recording's terminal reliability outcome: it is the
    /// dominant operational fact, and the final write's own decision is logged in
    /// the `inject` category either way.
    private func endRecordingAfterCaptureFailure(_ error: Error) {
        guard state == .recording else { return }
        log.error("recording cut short: microphone capture failed (\(String(describing: error)))")
        currentReliabilityRecording?.emit(.captureInterrupted)
        finishRecording()
        flashMicrophoneUnavailableNotice()
    }

    private func clearAudioCallbacks() {
        audio.onBuffer = nil
        audio.onAmplitude = nil
        audio.onRawBuffer = nil
        audio.onCaptureFailure = nil
    }

    public func finishRecording() {
        guard state == .recording else { return }
        currentReliabilityRecording?.markReleased()
        state = .finalizing
        // Before anything else in the release: a finalize parked on the hold (the
        // recognizer died mid-dictation) resumes here, and it must never observe
        // `.recording` again.
        resumeReleaseWaiters()
        finalizationPhase = .finalizingSpeech
        // Symmetric with the start bell and immediate: it confirms the
        // release REGISTERED (the fn monitor is global and edge-triggered,
        // so "did it stop?" is a real question). Delivery outcome stays
        // visual — the red notice on a refused write.
        RecordingCue.playEnd()
        // The glow frames the held dictation only: it fades at release while
        // the committed text becomes the feedback. The non-mirroring pill
        // stays, showing "Finishing"/"Updating" as it always has.
        cues.hideEdgeGlow()
        // A preview that is actively marking at release stays alive through
        // recognizer finalization: the provisional text remains visible (no blank
        // gap) and the final-commit router owns the lifecycle from here (acked
        // cancel → settle → guard → commit). Discarding at release would leave
        // the router a dead session and silently force keystrokes every time.
        // Everything else — disabled, skipped, degraded, begin-refused — starts
        // the discard at release as before, overlapping the recognizer's own
        // finalization. If the preview degrades after this check, the router
        // finds it ineligible and its fallback discards before any keystroke.
        if !inlinePreviewMirroring {
            preview.startDiscard()
        }
        log.info("recording finalize")
        audio.stop()
        let transcriber = transcriber
        Task { await transcriber.finish() }
    }

    private func runSession(
        preRoll: CapturePreRoll,
        cleanFinalTranscript: @Sendable (String) -> String,
        contextualStrings: [String]
    ) async {
        let transcriber = self.transcriber
        let audio = self.audio
        let dogfood = self.dogfood
        let shouldSaveAudioSamples = settings.saveAudioSamples
        let shouldSaveCorrectionEvidence = settings.saveCorrectionEvidence
        let sessionRecordingID = currentRecordingID
        let reliability = currentReliabilityRecording
        var recognizerFailed = false
        var microphoneDenied = false

        let events: AsyncStream<TranscriptEvent>
        do {
            events = try await transcriber.start(contextualStrings: contextualStrings)
            // Released before the analyzer was ready: the mic did run and the
            // pre-roll holds whatever was said, but the release is already tearing
            // the analyzer down, so that audio has nowhere to go.
            guard state == .recording else {
                await finishCancelledBeforeAnalyzerReady(
                    reliability: reliability,
                    keepingAudioSamples: shouldSaveAudioSamples,
                    recordingID: sessionRecordingID
                )
                return
            }
            // The analyzer exists now: hand it everything the mic captured while it
            // was starting, then let the tap feed it directly.
            let preRollBuffers = preRoll.attach { buffer in transcriber.accept(buffer) }
            log.info("capture pre-roll handed to the analyzer (buffers=\(preRollBuffers))")
        } catch TranscriberError.tornDownDuringStart {
            // The release beat the analyzer's start, so `finish()` tore the session
            // down mid-`start`. Identical user action to the state guard above — a
            // rapid fn tap — and which of the two a given tap lands on is a race. It
            // must therefore report the same outcome, not an error-level setup
            // failure and a "Not ready" notice for something the user did on purpose.
            await finishCancelledBeforeAnalyzerReady(
                reliability: reliability,
                keepingAudioSamples: shouldSaveAudioSamples,
                recordingID: sessionRecordingID
            )
            return
        } catch {
            log.error("recording setup failed: \(String(describing: error))")
            reliability?.emit(.setupFailed)
            dogfood.stop(keeping: shouldSaveAudioSamples)
            cancelTextInsertionSession()
            await resetSessionStateBeforeIdle()
            log.info("recording done (finalChars=0 failed=true)")
            returnToIdleAndCompleteRecordingLogScope(finishedRecordingID: sessionRecordingID)
            // The user held fn, saw the indicator, and spoke into a session that never
            // started; a log line is no feedback at all. Last, so the indicator
            // teardown inside the reset above cannot swallow the notice.
            flashStartUnavailableNotice()
            return
        }

        for await event in events {
            switch event {
            case .partial(let text):
                handlePartialTranscript(text)
                logTranscriptTiming(kind: .partial, eventText: text)
            case .final(let text):
                handleFinalTranscriptSegment(text)
                logTranscriptTiming(kind: .final, eventText: text)
            case .failed(let message):
                recognizerFailed = true
                log.error("transcription failed: \(message)")
            }
        }

        audio.stop()
        // Preserve a trailing recognizer partial when no later final arrives.
        promotePartialTranscriptAsFallbackFinalIfNeeded()
        if recognizerFailed {
            await parkFailedRecognitionUntilRelease()
        }

        // The authoritative final text: the per-recording canonicalize +
        // conservative deterministic clean, matching what the indicator streamed.
        let finalTranscript = cleanFinalTranscript(finalText)
        // Emptiness is decided on the text that will actually be written, not on the
        // raw accumulation. An "um"-only recording cleans away to nothing; running it
        // through the insertion path buys a backend refusal, a red "Not inserted" pill
        // inviting the user to retype what they never said, and an insertion-failure
        // row in the audit for a recording that had nothing to insert.
        let hasTranscribedText = !finalTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // Empty and failed sessions are the samples needed to diagnose silence,
        // wrong-input, capture, and recognizer failures.
        dogfood.stop(keeping: shouldSaveAudioSamples)

        if hasTranscribedText {
            finalizationPhase = .inserting
            await deliverFinalTranscript(
                finalTranscript,
                reliability: reliability,
                recognizerFailed: recognizerFailed,
                savingCorrectionEvidence: shouldSaveCorrectionEvidence,
                recordingID: sessionRecordingID
            )
        } else {
            cancelTextInsertionSession()
            microphoneDenied = !recognizerFailed && isMicrophoneAccessMissing()
            if microphoneDenied {
                log.error("recording produced no transcript: microphone access is not granted")
            }
            reliability?.emit(
                recognizerFailed ? .recognizerFailed :
                    microphoneDenied ? .microphoneDenied :
                    (reliability?.hasAudioInput == true ? .emptyTranscript : .noInput)
            )
        }

        // The finalized transcript's length, not the raw accumulation's: the raw count
        // is what a recording that cleaned away to nothing would report here, which
        // reads during triage as a transcript that existed and failed to land.
        let finalChars = finalTranscript.count
        await resetSessionStateBeforeIdle()
        log.info("recording done (finalChars=\(finalChars))")
        returnToIdleAndCompleteRecordingLogScope(finishedRecordingID: sessionRecordingID)
        // Last, so the indicator teardown in the reset above cannot swallow it.
        if microphoneDenied {
            flashStartUnavailableNotice(StartBlocker.microphoneDenied.noticeLabel)
        }
    }

    /// Whether the microphone grant is missing, asked ONLY of a recording that
    /// produced nothing. macOS feeds a TCC-denied process a stream of silent
    /// buffers, so such a recording is indistinguishable at the audio layer from a
    /// user who said nothing: buffers and frames both arrive, `hasAudioInput`
    /// passes, and the outcome has been auditing as `empty-transcript` ever since.
    /// The grant read is one TCC lookup on a path that runs once per recording,
    /// never per buffer.
    private func isMicrophoneAccessMissing() -> Bool {
        snapshotPermissions().microphone != .granted
    }

    /// The release arrived before the analyzer was ready for audio: either the state
    /// guard saw the recording already finalizing, or `start` threw
    /// `tornDownDuringStart` because the concurrent `finish()` won. The mic did run
    /// and the pre-roll holds whatever was said, but the release is already tearing
    /// the analyzer down, so that audio has nowhere to go. A user action, not a
    /// failure — both races report it identically.
    private func finishCancelledBeforeAnalyzerReady(
        reliability: ReliabilityRecording?,
        keepingAudioSamples: Bool,
        recordingID: String?
    ) async {
        cancelTextInsertionSession()
        reliability?.emit(.cancelledBeforeAudio)
        dogfood.stop(keeping: keepingAudioSamples)
        await resetSessionStateBeforeIdle()
        log.info("recording done (finalChars=0 cancelledBeforeAnalyzerReady=true)")
        returnToIdleAndCompleteRecordingLogScope(finishedRecordingID: recordingID)
    }

    /// The recognizer's result stream failed. If fn is still down, committing here
    /// would type into a field the user is still dictating into, and the release that
    /// follows would then be dropped by the state guard — so everything said after the
    /// failure would vanish with no explanation at all. Instead the assembled text
    /// waits: the user is told recognition died, and the ordinary release commits what
    /// was recognized before it did.
    ///
    /// The wait is bounded by the hotkey itself, which reconciles a missed release
    /// against the hardware within `FnHotkey.stuckKeyReconcileInterval`.
    private func parkFailedRecognitionUntilRelease() async {
        guard state == .recording else { return }
        guard isFnKeyHeld() else {
            // The key is already up with no release event on the way (a trigger that
            // does not run through the hotkey, or a release still in flight): commit
            // now rather than park on a release that may never arrive.
            log.info("recognizer failed with fn already released; committing what was recognized")
            return
        }
        log.error("recognizer failed while fn was held; holding the transcript until release")
        // The glow says "the mic is hot and this is being transcribed"; only the first
        // half is still true, so hand the cue to the pill carrying the notice.
        cues.hideEdgeGlow()
        flashRecognitionUnavailableNotice()
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    /// Wakes a finalize parked on the hold. Called from the one place `.recording`
    /// ends, so a park can never outlive the recording it belongs to.
    private func resumeReleaseWaiters() {
        let waiters = releaseWaiters
        releaseWaiters = []
        waiters.forEach { $0.resume() }
    }

    // MARK: - Transcript accumulation

    func handlePartialTranscript(_ text: String) {
        partial = text
        refreshDisplayText()
        preview.mirror(displayText)
    }

    func handleFinalTranscriptSegment(_ text: String) {
        finalText += text
        partial = ""
        refreshDisplayText()
        preview.mirror(displayText)
    }

    /// Re-runs the recording's transform over the accumulated raw text. Outside a
    /// recording (test staging, a stray late event) the current correction rules
    /// stand in, which is what the next recording would use anyway.
    private func refreshDisplayText() {
        let clean = activeTranscriptCleaner ?? makeFinalTranscriptCleaner()
        activeTranscriptCleaner = clean
        displayText = clean(finalText + partial)
    }

    func promotePartialTranscriptAsFallbackFinalIfNeeded() {
        guard !partial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        let fallbackFinalText = finalText + partial
        partial = ""
        finalText = fallbackFinalText
        log.info("recording promoted partial fallback finalChars=\(self.finalText.count)")
    }

    func logTranscriptTiming(kind: TranscriptTimingEventKind, eventText: String) {
        log.info(transcriptTiming.eventMessage(
            kind: kind,
            eventText: eventText,
            finalText: finalText,
            partialText: partial,
            displayText: displayText
        ))
    }

    // MARK: - Indicator presentation

    /// Internal so glow-lifetime tests can drive the presentation without a live
    /// audio pipeline.
    func presentIndicatorForRecordingStart() {
        // Keyed to the recording, not the preview generation: this runs before
        // `startInlinePreview` bumps it.
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

    private func startInlinePreview() {
        inlinePreviewMirroring = false
        preview.start(bundleIdentifier: textInsertionSession?.targetApplicationBundleIdentifier())
    }

    /// Internal so preview tests can build a session over a fake transport.
    func makeInlinePreviewSession(
        bundleIdentifier: String?,
        transport: (any InlinePreviewTransport)? = nil
    ) -> InlinePreviewSession? {
        preview.makeSession(bundleIdentifier: bundleIdentifier, transport: transport)
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

    private func finishInlinePreview() async {
        guard preview.isActive else { return }
        await preview.finish()
        inlinePreviewMirroring = false
    }

    // MARK: - Final write

    /// Test staging: installs the per-recording sessions `startRecording` would
    /// have created, so release/commit ordering can be pinned without a live
    /// speech pipeline. Production code never calls this.
    func stageFinalizationSessions(
        inlinePreview: InlinePreviewSession?,
        insertion: FinalTranscriptInsertionSession?
    ) {
        preview.stage(inlinePreview)
        textInsertionSession = insertion
    }

    /// The one authoritative write for a recording that produced text, plus the
    /// evidence and reliability records that describe how it went.
    private func deliverFinalTranscript(
        _ finalTranscript: String,
        reliability: ReliabilityRecording?,
        recognizerFailed: Bool,
        savingCorrectionEvidence: Bool,
        recordingID: String?
    ) async {
        switch await commitFinalTranscript(finalTranscript) {
        case .completed(let insertionResult, let viaIME):
            let applied = insertionResult == .accepted
            if !applied {
                // A refusal caused by revoked Accessibility is not the user
                // having clicked away, and "Not inserted" would send them
                // looking for the wrong thing.
                flashInsertionUnavailableNotice(
                    insertionResult == .accessibilityUntrusted
                        ? "No access"
                        : Self.defaultInsertionNotice
                )
            }
            let insertedTranscript = textInsertionSession?.insertedTranscript
            if let evidenceID = evidenceRecorder.recordIfEnabled(
                enabled: savingCorrectionEvidence,
                // The recognizer's own text, read here rather than at the call
                // site: evidence describes the raw transcript as it stands after
                // the write, exactly as it did before this was its own method.
                rawTranscript: finalText,
                finalTranscript: finalTranscript,
                applied: applied,
                finalInsertedTranscript: insertedTranscript == finalTranscript ? insertedTranscript : nil,
                recordingID: recordingID,
                session: textInsertionSession
            ) {
                if let finalInsertedTranscript = correctionEvidence.evidence.last(
                    where: { $0.id == evidenceID }
                )?.finalInsertedTranscript {
                    evidenceRecorder.scheduleObservedUserEditCapture(
                        evidenceID: evidenceID,
                        finalInsertedTranscript: finalInsertedTranscript,
                        session: textInsertionSession
                    )
                }
            }
            emitFinalReliabilityOutcome(
                reliability: reliability,
                recognizerFailed: recognizerFailed,
                insertionResult: insertionResult,
                transcript: finalTranscript,
                session: textInsertionSession,
                viaIMECommit: viaIME
            )
            finishTextInsertionSession()
        case .imeAmbiguous:
            // The commit was fully sent over a healthy channel and the ack
            // never arrived: it may have landed. A keystroke fallback could
            // insert the transcript twice, and flashing "Not inserted" would
            // invite a manual retype with the same double-text risk — so
            // write nothing, flash nothing, and report the recording as an
            // unacknowledged IME commit.
            reliability?.emit(
                recognizerFailed ? .recognizerFailed : .imeCommitUnacknowledged,
                transcriptUTF16: finalTranscript.utf16.count,
                writeAttempted: true,
                writeAccepted: false,
                imeCommit: true,
                imeCommitAcknowledged: false
            )
            injectLog.info(
                "final insertion ime commit unacknowledged; keystroke fallback suppressed"
            )
            cancelTextInsertionSession()
        }
    }

    /// Routes the one authoritative final write. The IME commit is attempted only
    /// over a channel that stayed healthy all recording; every other case is
    /// today's path unchanged. Internal so ordering tests can drive the full
    /// release → route chain.
    func commitFinalTranscript(_ transcript: String) async -> FinalTranscriptCommitRouter.Route {
        if let session = preview.session,
           let route = await FinalTranscriptCommitRouter.attemptIMECommit(
               transcript: transcript,
               preview: session,
               insertion: textInsertionSession
           ) {
            await finishInlinePreview()
            return route
        }
        // Ordering is load-bearing: the marked text must be gone before the one
        // guarded write, or the field shows the utterance twice.
        await finishInlinePreview()
        return .completed(insertFinalTranscriptResult(transcript), viaIME: false)
    }

    func insertFinalTranscriptResult(_ text: String) -> FinalInsertionResult {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .backendRefused
        }
        return textInsertionSession?.insertFinalResult(text) ?? .backendRefused
    }

    private func emitFinalReliabilityOutcome(
        reliability: ReliabilityRecording?,
        recognizerFailed: Bool,
        insertionResult: FinalInsertionResult,
        transcript: String,
        session: FinalTranscriptInsertionSession?,
        viaIMECommit: Bool = false
    ) {
        guard let reliability else { return }
        guard insertionResult == .accepted, let session else {
            reliability.emitFinal(
                recognizerFailed: recognizerFailed,
                insertionResult: insertionResult,
                delivery: .unavailable,
                transcriptUTF16: transcript.utf16.count,
                imeCommit: viaIMECommit
            )
            return
        }
        Task {
            let delivery = await session.verifyDelivery(expected: transcript)
            reliability.emitFinal(
                recognizerFailed: recognizerFailed,
                insertionResult: insertionResult,
                delivery: delivery,
                transcriptUTF16: transcript.utf16.count,
                imeCommit: viaIMECommit
            )
        }
    }

    private func finishTextInsertionSession() {
        textInsertionSession?.finish()
        textInsertionSession = nil
    }

    private func cancelTextInsertionSession() {
        textInsertionSession?.cancel()
        textInsertionSession = nil
    }

    // MARK: - Teardown

    /// Common teardown shared by every exit from `runSession`. Each piece is idempotent
    /// (`stop()` and `finish()` are no-ops when already done, callbacks set to nil).
    /// Path-specific work — `dogfood.stop(keeping:)`, insertion session closeout —
    /// stays at the call sites; only what every path does identically lives here, so
    /// the three exits can't drift apart again.
    ///
    /// This deliberately does not set `state = .idle`. The caller logs completion and
    /// clears the finished recording scope first, so a queued fn press cannot start the
    /// next recording in the middle of old-session cleanup.
    private func resetSessionStateBeforeIdle() async {
        // First, and before the preview teardown's socket round-trips: the mic is
        // open from fn press on every path now, so every exit has one to close.
        audio.stop()
        // No-op once the pre-write path already finished it; this covers the exits
        // that never reach a final write (setup failure, silence, recognizer error).
        await finishInlinePreview()
        clearAudioCallbacks()
        await transcriber.finish()
        cues.hideEdgeGlow()
        // Any notice still up owns the pill until its own flash expires; the reset
        // must not put the indicator away underneath one.
        if !startUnavailable, !insertionUnavailable, !microphoneUnavailable, !recognitionUnavailable {
            cues.hidePill()
        }
        amplitude = 0
        partial = ""
        transcriptionTask = nil
        activeTranscriptCleaner = nil
        currentReliabilityRecording = nil
        transcriptTiming.finish()
        finalizationPhase = .finalizingSpeech
    }

    private func returnToIdleAndCompleteRecordingLogScope(finishedRecordingID: String?) {
        if currentRecordingID == finishedRecordingID {
            currentRecordingID = nil
        }
        if let finishedRecordingID {
            RecordingLogContext.clear(finishedRecordingID)
        } else if currentRecordingID == nil {
            RecordingLogContext.clear()
        }
        state = .idle
        replayDeferredStartIfNeeded()
    }
}
