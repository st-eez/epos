import AVFoundation
import Foundation
import ServiceManagement
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
    /// True while the indicator reports that the guarded final write was refused.
    @Published public private(set) var insertionUnavailable = false
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

    /// True while the screen-edge glow is on. The glow frames the WHOLE
    /// dictation — lit at fn press, brightening with the voice, out at
    /// release — unlike the pill it never hides while text streams (it is
    /// peripheral and occludes nothing). Internal so tests can pin it.
    private(set) var edgeGlowVisible = false
    /// How long the preview channel may go unconfirmed before the pill
    /// presents and the glow retires (probe dead, connect failure, begin
    /// refused — paths that never activate mirroring). The healthy path
    /// activates within the begin round-trip, a few milliseconds.
    static let indicatorFallbackDelay: Duration = .milliseconds(200)
    /// Distributed-notification tokens for the debug dictation trigger.
    private var debugTriggerObservers: [NSObjectProtocol] = []

    /// Where setting mutations persist; injectable so tests never write the
    /// user's real defaults.
    private let settingsDefaults: UserDefaults
    private let hotkey: FnHotkey
    private let audio: any MicrophoneCapture
    private let transcriber: any SpeechTranscribing
    private let textInsertion: TextInsertionBackend
    private let insertionTargetObserverFactory: @MainActor () -> any InsertionTargetObserver
    private let permissions: PermissionsGate
    private let assets: AssetManager
    private let recordingIDGenerator: @Sendable () -> String
    private let reliabilityDiagnostics: DiagnosticLogSink
    public static let defaultObservedEditCaptureDelays: [TimeInterval] = [2, 6, 12, 15]
    private let observedEditCaptureDelays: [TimeInterval]
    /// Shared correction rules: this coordinator canonicalizes against it; the Corrections
    /// editor mutates the same instance (the app hands the editor `coordinator.corrections`).
    public let corrections = CorrectionStore()
    public let correctionEvidence: CorrectionEvidenceStore
    // Opt-in `.wav` capture for local eval material. Disabled by default.
    private let dogfood = DogfoodTap()
    private let log: EposLogger
    private let injectLog: EposLogger
    private var transcriptTiming: TranscriptTimingDiagnostics

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
    private var observedEditCaptureWorkItems: [DispatchWorkItem] = []
    private var currentRecordingID: String?
    private var currentReliabilityRecording: ReliabilityRecording?
    /// Mirrors the volatile transcript into the fn-press field as input-method
    /// marked text (`Settings.inlinePreview`, default on). Preview only — it is
    /// always discarded before the one authoritative write. Tests inject a fixed
    /// value; the app follows the live setting per recording.
    var inlinePreviewEnabled: Bool { inlinePreviewOverride ?? settings.inlinePreview }
    private let inlinePreviewOverride: Bool?
    private var inlinePreview: InlinePreviewSession?
    private var inlinePreviewDiscard: Task<Void, Never>?
    /// Monotonic token so a stale session's marking-activity callback can never
    /// flip the HUD suppression of a later recording.
    private var inlinePreviewGeneration = 0
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
    /// Why bootstrap finished without a capture format; nil unless that happened.
    private var startUnavailableReason: String?
    private lazy var indicator: RecordingIndicatorController = {
        let controller = RecordingIndicatorController()
        controller.attach(content: RecordingIndicator(coordinator: self))
        return controller
    }()
    private lazy var edgeGlow = RecordingEdgeGlowController()

    public init(
        hotkey: FnHotkey = FnHotkey(),
        audio: any MicrophoneCapture = AudioCapture(),
        transcriber: (any SpeechTranscribing)? = nil,
        textInsertion: TextInsertionBackend = KeystrokeTextInjector(),
        insertionTargetObserverFactory: (@MainActor () -> any InsertionTargetObserver)? = nil,
        settings: Settings = Settings.load(),
        settingsDefaults: UserDefaults = .standard,
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
        self.permissions = PermissionsGate()
        self.assets = AssetManager(locale: settings.locale)
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

    /// Identifier of the locale this coordinator was configured with. Read-only —
    /// changing locales mid-session is post-baseline.
    public var localeIdentifier: String { settings.localeIdentifier }

    public var saveAudioSamples: Bool { settings.saveAudioSamples }

    public func setSaveAudioSamples(_ enabled: Bool) {
        guard settings.saveAudioSamples != enabled else { return }
        settings.saveAudioSamples = enabled
        settings.save(to: settingsDefaults)
        log.info("audio sample capture \(enabled ? "enabled" : "disabled")")
    }

    public var saveCorrectionEvidence: Bool { settings.saveCorrectionEvidence }

    public var inlinePreviewSetting: Bool { settings.inlinePreview }

    public func setInlinePreview(_ enabled: Bool) {
        guard settings.inlinePreview != enabled else { return }
        settings.inlinePreview = enabled
        settings.save(to: settingsDefaults)
    }

    public func setSaveCorrectionEvidence(_ enabled: Bool) {
        guard settings.saveCorrectionEvidence != enabled else { return }
        settings.saveCorrectionEvidence = enabled
        settings.save(to: settingsDefaults)
        log.info("correction evidence capture \(enabled ? "enabled" : "disabled")")
    }

    public var edgeGlowStyle: EdgeGlowSettings { settings.edgeGlow }

    public func setEdgeGlowStyle(_ style: EdgeGlowSettings) {
        guard settings.edgeGlow != style else { return }
        settings.edgeGlow = style
        settings.save(to: settingsDefaults)
        edgeGlow.apply(style)
        if style.enabled {
            edgeGlow.prewarm()
            // Enabled mid-recording: light it now, and the pill (if it was the
            // indicator) yields as usual.
            if glowOwnsCurrentRecording {
                showEdgeGlow()
                // The pill yields only while the preview mirrors the same text
                // into the field; otherwise it is the only view of the volatile
                // transcript and has to stay.
                if inlinePreviewMirroring { indicator.hide() }
            }
        } else {
            // Disabled mid-recording: the pill must take over — hiding the
            // glow alone would leave a hot mic with no cue at all until
            // release (codex review, blocking).
            let handOffToPill = edgeGlowVisible && state == .recording
            hideEdgeGlow()
            if handOffToPill {
                presentBottomCenterPill()
            }
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

    /// Live launch-at-login state from the system — the source of truth, which the user
    /// can also change in System Settings — not the cached `settings` copy.
    public var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    public func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            settings.launchAtLogin = enabled
            settings.save(to: settingsDefaults)
            log.info("launch-at-login \(enabled ? "enabled" : "disabled")")
        } catch {
            log.error("launch-at-login toggle failed: \(String(describing: error))")
        }
    }

    /// Synchronous read of current permission grants (no prompts).
    /// Used by MenuBarView to surface a warning row when something isn't granted.
    public func snapshotPermissions() -> PermissionsSnapshot {
        permissions.snapshot()
    }

    /// One-time launch wiring: prompt for permissions, install the locale asset,
    /// and cache the analyzer's preferred audio format. Safe to call repeatedly;
    /// downstream calls are idempotent.
    public func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        log.info("bootstrap begin")
        let grants = await permissions.requestAll()
        // Anything short of an installed, reserved model is a reason the pipeline may
        // have no capture format. Naming it here is what keeps a dropped press from
        // blaming permissions for a model that is merely still downloading.
        var assetFailure: String?
        switch await assets.prepare() {
        case .ready, .reserved:
            break
        case .failed(let message):
            assetFailure = "asset prepare failed: \(message)"
            log.error("bootstrap asset prepare failed: \(message)")
        case .downloading:
            assetFailure = "speech model still downloading"
            log.info("bootstrap: speech model still downloading")
        case .missing:
            assetFailure = "speech model not installed"
            log.error("bootstrap: speech model not installed")
        }
        captureFormat = await transcriber.bestAudioFormat()
        if captureFormat == nil {
            startUnavailableReason = assetFailure
                ?? "speech \(grants.speech), microphone \(grants.microphone)"
        }
        if settings.edgeGlow.enabled {
            edgeGlow.apply(settings.edgeGlow)
            edgeGlow.prewarm()
        }
        didCompleteBootstrap = true
        log.info("bootstrap done format=\(String(describing: self.captureFormat))")
        replayDeferredStartIfNeeded()
    }

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
                    + "(\(self.startUnavailableReason ?? "unknown"))"
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

    /// How long one of the pill's red notices stays up. Long enough to read a
    /// two-word label after the user's attention has returned to their own text.
    static let noticeFlashDuration: Duration = .milliseconds(2_500)

    /// Flash the recording pill with one of its red notices, then clear it and put
    /// the pill away if the coordinator is back at rest. Every notice behaves
    /// identically; only which flag the indicator reads differs.
    private func flashNotice(_ notice: ReferenceWritableKeyPath<AppCoordinator, Bool>) {
        self[keyPath: notice] = true
        indicator.show()
        Task { [weak self] in
            try? await Task.sleep(for: Self.noticeFlashDuration)
            guard let self, self[keyPath: notice] else { return }
            self[keyPath: notice] = false
            if self.state == .idle { self.indicator.hide() }
        }
    }

    /// "Not ready": a held-fn dictation was dropped because there is no capture
    /// format — bootstrap finished without one, or the mic refused to open.
    private func flashStartUnavailableNotice() {
        flashNotice(\.startUnavailable)
    }

    private func flashInsertionUnavailableNotice() {
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

    private func bindHotkey() {
        hotkey.onPress = { [weak self] in self?.startRecording() }
        hotkey.onRelease = { [weak self] in self?.finishRecording() }
        hotkey.start()
    }

    /// Dogfood remote control: distributed notifications drive the REAL
    /// `startRecording`/`finishRecording`, exactly as the fn key would. Armed
    /// only under `EPOS_DEBUG_DICTATION_TRIGGER=1`; tokens are retained for the
    /// coordinator's (= the app's) lifetime.
    private func bindDebugDictationTriggerIfEnabled() {
        guard DebugDictationTriggerPolicy.load() else { return }
        let center = DistributedNotificationCenter.default()
        debugTriggerObservers = [
            center.addObserver(
                forName: DebugDictationTriggerPolicy.startNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.startRecording() }
            },
            center.addObserver(
                forName: DebugDictationTriggerPolicy.finishNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.finishRecording() }
            },
        ]
        log.info("debug dictation trigger armed")
    }

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
                // Bootstrap already finished without a capture format, so no later
                // transition can produce one. Latching here would swallow this press
                // and every press after it in silence: the one-shot replay already
                // consumed the latch, and the only other drain needs a finalize.
                log.error(
                    "start dropped: no capture format after bootstrap "
                        + "(\(self.startUnavailableReason ?? "unknown"))"
                )
                flashStartUnavailableNotice()
                return
            }
            // The launch window: fn pressed before bootstrap cached the format.
            // Latch the press instead of dropping it; `bootstrap()` replays it.
            pendingDeferredStart = true
            log.info("start requested before bootstrap completed; will replay when capture format is ready")
            return
        }
        // Drop the prior recording's pending edit-capture polls: once new dictation
        // types into the field, a span read can no longer be attributed to the prior
        // transcript as a user edit. Burst dictation therefore under-collects
        // correction evidence by design — precision over recall; extending capture
        // past this point would record unrelated typing as an "edit".
        cancelObservedEditCaptureChecks()
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
                // Only while the glow is actually up: a retired glow's
                // hidden view has no business animating per buffer.
                if self.edgeGlowVisible {
                    self.edgeGlow.updateAmplitude(amp)
                }
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
        hideEdgeGlow()
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
        hideEdgeGlow()
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
            startInlinePreviewDiscard()
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
            switch await commitFinalTranscript(finalTranscript) {
            case .completed(let insertionResult, let viaIME):
                let applied = insertionResult == .accepted
                if !applied { flashInsertionUnavailableNotice() }
                let insertedTranscript = textInsertionSession?.insertedTranscript
                if let evidenceID = recordCorrectionEvidenceIfEnabled(
                    enabled: shouldSaveCorrectionEvidence,
                    rawTranscript: finalText,
                    finalTranscript: finalTranscript,
                    applied: applied,
                    finalInsertedTranscript: insertedTranscript == finalTranscript ? insertedTranscript : nil,
                    recordingID: sessionRecordingID,
                    session: textInsertionSession
                ) {
                    if let finalInsertedTranscript = correctionEvidence.evidence.last(
                        where: { $0.id == evidenceID }
                    )?.finalInsertedTranscript {
                        scheduleObservedUserEditCapture(
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
        } else {
            cancelTextInsertionSession()
            reliability?.emit(
                recognizerFailed ? .recognizerFailed :
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
        hideEdgeGlow()
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

    func handlePartialTranscript(_ text: String) {
        partial = text
        refreshDisplayText()
        mirrorInlinePreview()
    }

    func handleFinalTranscriptSegment(_ text: String) {
        finalText += text
        partial = ""
        refreshDisplayText()
        mirrorInlinePreview()
    }

    /// Re-runs the recording's transform over the accumulated raw text. Outside a
    /// recording (test staging, a stray late event) the current correction rules
    /// stand in, which is what the next recording would use anyway.
    private func refreshDisplayText() {
        let clean = activeTranscriptCleaner ?? makeFinalTranscriptCleaner()
        activeTranscriptCleaner = clean
        displayText = clean(finalText + partial)
    }

    /// Mirror exactly what the HUD shows. Off unless the preview is enabled, where
    /// it costs one nil check per recognizer event.
    private func mirrorInlinePreview() {
        guard let inlinePreview else { return }
        let text = displayText
        Task { await inlinePreview.mark(text) }
    }

    private func startInlinePreview() {
        inlinePreview = nil
        inlinePreviewDiscard = nil
        inlinePreviewMirroring = false
        let bundleIdentifier = textInsertionSession?.targetApplicationBundleIdentifier()
        guard let inlinePreview = makeInlinePreviewSession(bundleIdentifier: bundleIdentifier) else {
            if inlinePreviewEnabled {
                // Correlates a "saw nothing in app X" report with an unidentifiable
                // fn-press target rather than a rendering failure.
                injectLog.info("inline preview skipped: no target bundle id")
            }
            return
        }
        self.inlinePreview = inlinePreview
        Task { await inlinePreview.begin() }
    }

    /// Preview needs the fn-press application up front, because the probe pins its
    /// focus lock by bundle id. An unidentifiable target means no preview this
    /// recording — never a delayed or retried one.
    func makeInlinePreviewSession(
        bundleIdentifier: String?,
        transport: (any InlinePreviewTransport)? = nil
    ) -> InlinePreviewSession? {
        guard inlinePreviewEnabled, let bundleIdentifier, !bundleIdentifier.isEmpty else {
            return nil
        }
        inlinePreviewGeneration += 1
        let generation = inlinePreviewGeneration
        return InlinePreviewSession(
            transport: transport ?? UnixSocketInlinePreviewTransport(),
            bundleIdentifier: bundleIdentifier,
            onMarkingActivityChange: { [weak self] active in
                Task { @MainActor in
                    guard let self, self.inlinePreviewGeneration == generation else { return }
                    self.inlinePreviewMirroring = active
                    // A mid-recording degrade makes the HUD the only feedback
                    // again, so the pill comes back (with its transcript line,
                    // in the same update) and the glow retires with the
                    // channel it advertises. Activation is the mirror image:
                    // a begin ack slower than the fallback deadline arrives
                    // AFTER the pill took over — the glow reclaims the
                    // recording and the pill yields, otherwise the first mark
                    // would hide the pill and leave NO mic-hot cue at all
                    // (review finding, e90dcae..). On the fast path both
                    // calls are no-ops. At finalize `finishInlinePreview`
                    // clears the flag with state != .recording, skipping this.
                    if self.state == .recording {
                        if active, self.settings.edgeGlow.enabled {
                            // With the glow disabled the pill stays the
                            // pre-text indicator; the first mark hides it.
                            self.showEdgeGlow()
                            self.indicator.hide()
                        } else if !active {
                            self.hideEdgeGlow()
                            self.presentBottomCenterPill()
                        }
                    }
                }
            },
            onFirstMarkRendered: { [weak self] in
                Task { @MainActor in
                    guard let self, self.inlinePreviewGeneration == generation else { return }
                    // The first letter just landed in the field: the fallback
                    // pill (if the slow-begin path showed it) yields to the
                    // in-field provisional text. The glow stays — it frames
                    // the whole dictation.
                    guard self.state == .recording, self.inlinePreviewMirroring else { return }
                    self.indicator.hide()
                }
            }
        )
    }

    /// The glow lights instantly at fn press — before the AX capture and (with
    /// the preview on) the probe handshake, so the prewarmed panel makes this
    /// a pure fade. With the glow turned off in settings the pill shows instead,
    /// exactly as it always has. Internal so glow-lifetime tests can drive the
    /// presentation without a live audio pipeline.
    func presentIndicatorForRecordingStart() {
        guard settings.edgeGlow.enabled else {
            presentBottomCenterPill()
            return
        }
        showEdgeGlow()
        guard inlinePreviewEnabled else {
            // No preview: the glow frames the recording, and the pill presents
            // alongside it because it is the only view of the volatile transcript.
            presentBottomCenterPill()
            return
        }
        // With the preview on the glow doubles as the channel's cue: if the preview
        // never confirms within the deadline (unidentifiable target, probe dead,
        // begin refused), the glow retires and the pill takes over, so the user is
        // never left with a glow advertising a channel that is not streaming.
        // Keyed to the recording, not the preview generation: this runs
        // before `startInlinePreview` bumps it.
        let recordingID = currentRecordingID
        Task { [weak self] in
            try? await Task.sleep(for: Self.indicatorFallbackDelay)
            guard let self, self.currentRecordingID == recordingID,
                  self.state == .recording, !self.inlinePreviewMirroring else { return }
            self.hideEdgeGlow()
            self.presentBottomCenterPill()
        }
    }

    /// Whether the glow — rather than the pill — is the right indicator for the
    /// recording in progress. With the preview on the glow tracks the channel
    /// it advertises; with it off the glow owns every recording.
    private var glowOwnsCurrentRecording: Bool {
        state == .recording && (!inlinePreviewEnabled || inlinePreviewMirroring)
    }

    private func presentBottomCenterPill() {
        indicator.show()
    }

    private func showEdgeGlow() {
        guard !edgeGlowVisible else { return }
        edgeGlowVisible = true
        edgeGlow.show()
    }

    private func hideEdgeGlow() {
        guard edgeGlowVisible else { return }
        edgeGlowVisible = false
        edgeGlow.hide()
    }

    /// Test staging: installs the per-recording sessions `startRecording` would
    /// have created, so release/commit ordering can be pinned without a live
    /// speech pipeline. Production code never calls this.
    func stageFinalizationSessions(
        inlinePreview: InlinePreviewSession?,
        insertion: FinalTranscriptInsertionSession?
    ) {
        self.inlinePreview = inlinePreview
        textInsertionSession = insertion
    }

    /// Routes the one authoritative final write. The IME commit is attempted only
    /// over a channel that stayed healthy all recording; every other case is
    /// today's path unchanged. Internal so ordering tests can drive the full
    /// release → route chain.
    func commitFinalTranscript(_ transcript: String) async -> FinalTranscriptCommitRouter.Route {
        if let inlinePreview,
           let route = await FinalTranscriptCommitRouter.attemptIMECommit(
               transcript: transcript,
               preview: inlinePreview,
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

    private func startInlinePreviewDiscard() {
        guard let inlinePreview, inlinePreviewDiscard == nil else { return }
        inlinePreviewDiscard = Task { await inlinePreview.discard() }
    }

    /// Waits out the discard and emits the one per-recording diagnostic line. The
    /// wait is bounded by the transport's per-operation socket timeouts, and is
    /// normally already satisfied because the discard started at fn release.
    private func finishInlinePreview() async {
        guard let inlinePreview else { return }
        startInlinePreviewDiscard()
        await inlinePreviewDiscard?.value
        let report = await inlinePreview.report()
        if report.didAttemptMark, !report.committed {
            // Keyed to the attempt, not the ack: a mark whose reply timed out
            // leaves marksSent at zero and may still be drawn in the field, and
            // that is exactly the case keystrokes must not land on top of.
            // After an acked IME commit no keystrokes follow, so there is nothing
            // to settle for.
            try? await Task.sleep(for: InlinePreviewSession.compositionSettleDelay)
        }
        injectLog.info(report.logLine)
        self.inlinePreview = nil
        inlinePreviewDiscard = nil
        inlinePreviewMirroring = false
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

    @discardableResult
    func recordCorrectionEvidenceIfEnabled(
        enabled: Bool,
        rawTranscript: String,
        finalTranscript: String,
        applied: Bool,
        finalInsertedTranscript: String? = nil,
        recordingID: String? = nil,
        session: FinalTranscriptInsertionSession? = nil
    ) -> String? {
        guard enabled,
              applied,
              finalInsertedTranscript == finalTranscript else {
            return nil
        }
        return recordCorrectionEvidence(
            rawTranscript: rawTranscript,
            finalTranscript: finalTranscript,
            applied: applied,
            finalInsertedTranscript: finalInsertedTranscript,
            recordingID: recordingID,
            session: session
        )
    }

    @discardableResult
    func recordCorrectionEvidence(
        rawTranscript: String,
        finalTranscript: String,
        applied: Bool,
        finalInsertedTranscript: String? = nil,
        recordingID: String? = nil,
        session: FinalTranscriptInsertionSession? = nil
    ) -> String {
        let canonicalizedRaw = corrections.canonicalize(rawTranscript)
        return correctionEvidence.record(CorrectionEvidence(
            id: UUID().uuidString,
            observedAt: Date(),
            recordingID: recordingID ?? currentRecordingID,
            rawTranscript: rawTranscript,
            canonicalizedTranscript: canonicalizedRaw,
            finalInsertedTranscript: finalInsertedTranscript ?? (applied ? finalTranscript : canonicalizedRaw),
            userEditedTranscript: nil,
            applicationBundleIdentifier: session?.targetApplicationBundleIdentifier(),
            windowTitle: session?.targetWindowTitle(),
            appliedRuleIDs: corrections.dictionary.appliedRecordIDs(in: rawTranscript)
        ))
    }

    func scheduleObservedUserEditCapture(
        evidenceID: String,
        finalInsertedTranscript: String,
        session: FinalTranscriptInsertionSession?
    ) {
        cancelObservedEditCaptureChecks()
        guard let session else { return }

        let delays = observedEditCaptureDelays.isEmpty ? [0] : observedEditCaptureDelays

        for delay in delays {
            guard delay > 0 else {
                if captureObservedUserEdit(
                    evidenceID: evidenceID,
                    finalInsertedTranscript: finalInsertedTranscript,
                    session: session
                ) {
                    cancelObservedEditCaptureChecks()
                    return
                }
                continue
            }

            let workItem = DispatchWorkItem { [weak self, session, evidenceID, finalInsertedTranscript] in
                guard let self else { return }
                MainActor.assumeIsolated {
                    if self.captureObservedUserEdit(
                        evidenceID: evidenceID,
                        finalInsertedTranscript: finalInsertedTranscript,
                        session: session
                    ) {
                        self.cancelObservedEditCaptureChecks()
                    }
                }
            }
            observedEditCaptureWorkItems.append(workItem)
            DispatchQueue.main.asyncAfter(
                deadline: .now() + delay,
                execute: workItem
            )
        }
    }

    @discardableResult
    func captureObservedUserEdit(
        evidenceID: String,
        finalInsertedTranscript: String,
        session: FinalTranscriptInsertionSession
    ) -> Bool {
        guard let observedInsertedText = session.observedInsertedText(),
              observedInsertedText != finalInsertedTranscript,
              let validatedEdit = ObservedUserEditFilter.validatedEdit(
                observed: observedInsertedText,
                final: finalInsertedTranscript
              ) else {
            return false
        }

        return correctionEvidence.recordUserEdit(
            evidenceID: evidenceID,
            userEditedTranscript: validatedEdit
        )
    }

    private func cancelObservedEditCaptureChecks() {
        observedEditCaptureWorkItems.forEach { $0.cancel() }
        observedEditCaptureWorkItems = []
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

    private func finishTextInsertionSession() {
        textInsertionSession?.finish()
        textInsertionSession = nil
    }

    private func cancelTextInsertionSession() {
        textInsertionSession?.cancel()
        textInsertionSession = nil
    }

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
        hideEdgeGlow()
        // Any notice still up owns the pill until its own flash expires; the reset
        // must not put the indicator away underneath one.
        if !startUnavailable, !insertionUnavailable, !microphoneUnavailable, !recognitionUnavailable {
            indicator.hide()
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
