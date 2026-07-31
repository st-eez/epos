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

    /// Running display: committed finals + in-progress partial. The partial replaces
    /// only the tail because `SpeechTranscriber` emits volatile partials for the
    /// in-progress segment alongside committed per-segment finals.
    public var displayText: String { finalText + partial }

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

    private let hotkey: FnHotkey
    private let audio: AudioCapture
    private let transcriber: Transcriber
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

    private var transcriptionTask: Task<Void, Never>?
    /// Cached at bootstrap; nil until then. Internal so latch tests can install one.
    var captureFormat: AVAudioFormat?
    private var textInsertionSession: FinalTranscriptInsertionSession?
    private var observedEditCaptureWorkItems: [DispatchWorkItem] = []
    private var currentRecordingID: String?
    private var currentReliabilityRecording: ReliabilityRecording?
    /// Dogfood spike (`EPOS_INLINE_PREVIEW=1`, default off): mirrors the volatile
    /// transcript into the fn-press field as input-method marked text. Preview only —
    /// it is always discarded before the one authoritative write.
    let inlinePreviewEnabled: Bool
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
    private lazy var indicator: RecordingIndicatorController = {
        let controller = RecordingIndicatorController()
        controller.attach(content: RecordingIndicator(coordinator: self))
        return controller
    }()
    private lazy var edgeGlow = RecordingEdgeGlowController()

    public init(
        hotkey: FnHotkey = FnHotkey(),
        audio: AudioCapture = AudioCapture(),
        textInsertion: TextInsertionBackend = KeystrokeTextInjector(),
        insertionTargetObserverFactory: (@MainActor () -> any InsertionTargetObserver)? = nil,
        settings: Settings = Settings.load(),
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
        self.inlinePreviewEnabled = inlinePreviewEnabled ?? InlinePreviewPolicy.load()
        self.correctionEvidence = correctionEvidence
        self.recordingIDGenerator = recordingIDGenerator
        self.reliabilityDiagnostics = diagnostics
        self.isFnKeyHeld = isFnKeyHeld ?? { [hotkey] in hotkey.isFunctionKeyDown }
        self.observedEditCaptureDelays = observedEditCaptureDelays
        self.transcriptTiming = TranscriptTimingDiagnostics(
            includeTranscriptText: includeTranscriptTextInDiagnostics ?? TranscriptDiagnosticTextPolicy.load()
        )
        self.settings = settings
        self.permissions = PermissionsGate()
        self.assets = AssetManager(locale: settings.locale)
        self.transcriber = Transcriber(locale: settings.locale)
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
        settings.save()
        log.info("audio sample capture \(enabled ? "enabled" : "disabled")")
    }

    public var saveCorrectionEvidence: Bool { settings.saveCorrectionEvidence }

    public func setSaveCorrectionEvidence(_ enabled: Bool) {
        guard settings.saveCorrectionEvidence != enabled else { return }
        settings.saveCorrectionEvidence = enabled
        settings.save()
        log.info("correction evidence capture \(enabled ? "enabled" : "disabled")")
    }

    /// The authoritative final-transcript transform, built once per recording so a
    /// mid-session correction-rule edit cannot alter the finalization behavior of an
    /// already-running dictation. It is the same `streamClean(canonicalize(...))` the
    /// live indicator applies to every streamed partial, so the one final write cannot
    /// re-type text the user already saw cleaned on screen.
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
            settings.save()
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
        _ = await permissions.requestAll()
        if case .failed(let message) = await assets.prepare() {
            log.error("bootstrap asset prepare failed: \(message)")
        }
        captureFormat = await transcriber.bestAudioFormat()
        if inlinePreviewEnabled {
            edgeGlow.prewarm()
        }
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
            log.error("pending start dropped: capture format unavailable after bootstrap")
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

    /// Flash the existing recording pill with a "Not ready" notice when a deferred
    /// start had to be dropped because bootstrap finished without a capture format.
    private func flashStartUnavailableNotice() {
        startUnavailable = true
        indicator.show()
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let self, self.startUnavailable else { return }
            self.startUnavailable = false
            if self.state == .idle { self.indicator.hide() }
        }
    }

    private func flashInsertionUnavailableNotice() {
        insertionUnavailable = true
        indicator.show()
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let self, self.insertionUnavailable else { return }
            self.insertionUnavailable = false
            if self.state == .idle { self.indicator.hide() }
        }
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
        // Feedback first, work second: the glow (or pill) and the start cue
        // land before the synchronous AX baseline capture below, which can
        // stall for hundreds of milliseconds on slow accessibility targets.
        presentIndicatorForRecordingStart()
        RecordingStartCue.play()
        let reliability = ReliabilityRecording(
            recordingID: recordingID,
            diagnostics: reliabilityDiagnostics
        )
        currentReliabilityRecording = reliability
        finalizationPhase = .finalizingSpeech
        finalText = ""
        partial = ""
        amplitude = 0
        insertionUnavailable = false
        textInsertionSession = FinalTranscriptInsertionSession(
            insertionSession: textInsertion.startInsertionSession(),
            target: insertionTargetObserverFactory(),
            recordingID: recordingID
        )
        startInlinePreview()
        transcriptTiming.start()
        let cleanFinalTranscript = makeFinalTranscriptCleaner()
        let contextualStrings = speechContextualStrings()

        transcriptionTask = Task { [weak self] in
            await self?.runSession(
                format: format,
                cleanFinalTranscript: cleanFinalTranscript,
                contextualStrings: contextualStrings
            )
        }
    }

    public func finishRecording() {
        guard state == .recording else { return }
        currentReliabilityRecording?.markReleased()
        state = .finalizing
        finalizationPhase = .finalizingSpeech
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
        format: AVAudioFormat,
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
            guard state == .recording else {
                cancelTextInsertionSession()
                reliability?.emit(.cancelledBeforeAudio)
                await resetSessionStateBeforeIdle()
                log.info("recording done (finalChars=0 cancelledBeforeAudioStart=true)")
                returnToIdleAndCompleteRecordingLogScope(finishedRecordingID: sessionRecordingID)
                return
            }
            audio.onBuffer = { buffer in
                reliability?.recordAudioBuffer(frameCount: Int(buffer.frameLength))
                transcriber.accept(buffer)
            }
            audio.onAmplitude = { [weak self] amp in
                Task { @MainActor in
                    guard let self, self.state == .recording else { return }
                    self.amplitude = amp
                    self.edgeGlow.updateAmplitude(amp)
                }
            }
            if shouldSaveAudioSamples {
                audio.onRawBuffer = { buffer in dogfood.write(buffer, recordingID: sessionRecordingID) }
            } else {
                audio.onRawBuffer = nil
            }
            try audio.start(targetFormat: format)
        } catch {
            log.error("recording setup failed: \(String(describing: error))")
            reliability?.emit(.setupFailed)
            dogfood.stop(keeping: shouldSaveAudioSamples)
            cancelTextInsertionSession()
            await resetSessionStateBeforeIdle()
            log.info("recording done (finalChars=0 failed=true)")
            returnToIdleAndCompleteRecordingLogScope(finishedRecordingID: sessionRecordingID)
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

        let hasTranscribedText = !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // Empty and failed sessions are the samples needed to diagnose silence,
        // wrong-input, capture, and recognizer failures.
        dogfood.stop(keeping: shouldSaveAudioSamples)

        if hasTranscribedText {
            // The authoritative final text: the per-recording canonicalize +
            // conservative deterministic clean, matching what the indicator streamed.
            let finalTranscript = cleanFinalTranscript(finalText)
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
                    recognizerFailed ? .recognizerFailed : .writeAcceptedUnverified,
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

        let finalChars = finalText.count
        await resetSessionStateBeforeIdle()
        log.info("recording done (finalChars=\(finalChars))")
        returnToIdleAndCompleteRecordingLogScope(finishedRecordingID: sessionRecordingID)
    }

    func handlePartialTranscript(_ text: String) {
        partial = text
        mirrorInlinePreview()
    }

    func handleFinalTranscriptSegment(_ text: String) {
        finalText += text
        partial = ""
        mirrorInlinePreview()
    }

    /// Mirror exactly what the HUD shows. Off unless the spike is enabled, where it
    /// costs one nil check per recognizer event.
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
                        if active {
                            self.showEdgeGlow()
                            self.indicator.hide()
                        } else {
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

    /// With the preview disabled the pill shows immediately, exactly as it
    /// always has. Enabled, the glow lights instantly at fn press — before
    /// the AX capture and the probe handshake, so the prewarmed panel makes
    /// this a pure fade. If the preview channel never confirms within the
    /// deadline (unidentifiable target, probe dead, begin refused), the glow
    /// retires and the pill takes over, so the user is never left with a glow
    /// advertising a channel that is not streaming. Internal so glow-lifetime
    /// tests can drive the presentation without a live audio pipeline.
    func presentIndicatorForRecordingStart() {
        guard inlinePreviewEnabled else {
            presentBottomCenterPill()
            return
        }
        showEdgeGlow()
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
        if report.marksSent > 0, !report.committed {
            // The probe acknowledges issuing the discard, not the target app having
            // drawn it. A short fixed settle keeps the composition from still being
            // on screen when the keystrokes land. After an acked IME commit no
            // keystrokes follow, so there is nothing to settle for.
            try? await Task.sleep(for: .milliseconds(30))
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

    /// Insert the already-canonicalized final text through the fn-press session.
    @discardableResult
    func insertFinalTranscript(_ text: String) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return textInsertionSession?.insertFinal(text) ?? false
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
            partialText: partial
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
    /// (callbacks set to nil, `finish()` is idempotent). Path-specific work — `audio.stop()`,
    /// `dogfood.stop(keeping:)`, insertion session closeout — stays at the call sites; only
    /// what every path does identically lives here, so the three exits can't drift apart again.
    ///
    /// This deliberately does not set `state = .idle`. The caller logs completion and
    /// clears the finished recording scope first, so a queued fn press cannot start the
    /// next recording in the middle of old-session cleanup.
    private func resetSessionStateBeforeIdle() async {
        // No-op once the pre-write path already finished it; this covers the exits
        // that never reach a final write (setup failure, silence, recognizer error).
        await finishInlinePreview()
        audio.onBuffer = nil
        audio.onAmplitude = nil
        audio.onRawBuffer = nil
        await transcriber.finish()
        hideEdgeGlow()
        if !insertionUnavailable { indicator.hide() }
        amplitude = 0
        partial = ""
        transcriptionTask = nil
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
