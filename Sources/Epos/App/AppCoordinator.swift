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
    case polishing
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

    /// Running display: committed finals + in-progress partial. The partial replaces
    /// only the tail because `SpeechTranscriber` emits volatile partials for the
    /// in-progress segment alongside committed per-segment finals.
    public var displayText: String { finalText + partial }

    private let hotkey: FnHotkey
    private let audio: AudioCapture
    private let transcriber: Transcriber
    private let textInsertion: TextInsertionBackend
    private let polishEngine: any PolishEngine
    private let permissions: PermissionsGate
    private let assets: AssetManager
    private let recordingIDGenerator: @Sendable () -> String
    public static let defaultObservedEditCaptureDelays: [TimeInterval] = [2, 6, 12, 15]
    private let observedEditCaptureDelays: [TimeInterval]
    /// Shared correction rules: this coordinator canonicalizes against it; the Corrections
    /// editor mutates the same instance (the app hands the editor `coordinator.corrections`).
    public let corrections = CorrectionStore()
    public let correctionEvidence: CorrectionEvidenceStore
    // Opt-in `.wav` capture for local eval material. Disabled by default.
    private let dogfood = DogfoodTap()
    private let log: EposLogger
    private var transcriptTiming: TranscriptTimingDiagnostics

    private var transcriptionTask: Task<Void, Never>?
    /// Cached at bootstrap; nil until then. Internal so latch tests can install one.
    var captureFormat: AVAudioFormat?
    private var textInsertionSession: ProgressiveTranscriptInsertionSession?
    private var observedEditCaptureWorkItems: [DispatchWorkItem] = []
    private var currentRecordingID: String?
    private let includeTranscriptTextInDiagnostics: Bool
    /// Single deferred-start latch, set when a press arrives while `startRecording`
    /// cannot run it yet: the finalize/polish window (state != .idle) or the launch
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
    /// The current recording's polisher, held so a re-press during finalize can abandon
    /// its in-flight polish. Set at `startRecording`, cleared before returning to idle.
    /// (Distinct from threading it into `runSession`, which is what actually runs the polish.)
    private var activePolisher: TranscriptPolisher?
    private var didBootstrap = false
    private lazy var indicator: RecordingIndicatorController = {
        let controller = RecordingIndicatorController()
        controller.attach(content: RecordingIndicator(coordinator: self))
        return controller
    }()

    public init(
        hotkey: FnHotkey = FnHotkey(),
        audio: AudioCapture = AudioCapture(),
        textInsertion: TextInsertionBackend = KeystrokeTextInjector(),
        settings: Settings = Settings.load(),
        polishEngine: (any PolishEngine)? = nil,
        diagnostics: DiagnosticLogSink = .shared,
        correctionEvidence: CorrectionEvidenceStore = CorrectionEvidenceStore(),
        recordingIDGenerator: @escaping @Sendable () -> String = RecordingID.make,
        isFnKeyHeld: (@MainActor () -> Bool)? = nil,
        observedEditCaptureDelays: [TimeInterval] = AppCoordinator.defaultObservedEditCaptureDelays,
        includeTranscriptTextInDiagnostics: Bool? = nil,
        autoStart: Bool = true
    ) {
        self.hotkey = hotkey
        self.audio = audio
        self.textInsertion = textInsertion
        self.polishEngine = polishEngine ?? PolishEngineFactory.makeDefault()
        self.log = EposLogger(category: "coordinator", diagnostics: diagnostics)
        self.correctionEvidence = correctionEvidence
        self.recordingIDGenerator = recordingIDGenerator
        self.isFnKeyHeld = isFnKeyHeld ?? { [hotkey] in hotkey.isFunctionKeyDown }
        self.observedEditCaptureDelays = observedEditCaptureDelays
        let includeTranscriptText = includeTranscriptTextInDiagnostics ?? TranscriptDiagnosticTextPolicy.load()
        self.includeTranscriptTextInDiagnostics = includeTranscriptText
        self.transcriptTiming = TranscriptTimingDiagnostics(
            includeTranscriptText: includeTranscriptText
        )
        self.settings = settings
        self.permissions = PermissionsGate()
        self.assets = AssetManager(locale: settings.locale)
        self.transcriber = Transcriber(locale: settings.locale)
        if autoStart {
            bindHotkey()
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

    public var polishEnabled: Bool { settings.polishEnabled }

    public func setPolishEnabled(_ enabled: Bool) {
        guard settings.polishEnabled != enabled else { return }
        settings.polishEnabled = enabled
        settings.save()
        log.info("dictation polish \(enabled ? "enabled" : "disabled")")
    }

    /// Built once per recording so a mid-session settings change cannot alter the
    /// finalization behavior of an already-running dictation. Internal so a test can
    /// assert the final polish baseline applies the same `streamClean` the live closure
    /// does — the seam where a polish-off final used to revert the on-screen cleaning.
    func makePolisher() -> TranscriptPolisher {
        // Snapshot the value-type canonicalizer so the guard validates — and the
        // polisher returns — the exact string the live closure streamed on screen. That
        // closure is `streamClean(canonicalize(rawStream))`, and `acceptFinalPolishedTranscript`
        // types the polisher output verbatim (no second canonicalize), so the polisher
        // MUST apply the same `streamClean`. Without it the polish-off default re-typed the
        // raw, filler/stutter-laden tail at finalization and reverted the on-screen cleaning
        // on every deletable target. The snapshot also freezes the rules for this recording,
        // matching the build-once-per-recording intent.
        let canonicalizer = corrections.canonicalizer
        // Only walk the correction rules for known terms when polish is on; when it's
        // off (the default) the polisher short-circuits at its `enabled` gate and never
        // reads `knownTerms`, so computing them on the fn-press hot path is wasted work.
        return TranscriptPolisher(
            enabled: settings.polishEnabled,
            engine: polishEngine,
            knownTerms: settings.polishEnabled ? polishKnownTerms() : [],
            canonicalize: { TranscriptDeterministicCleaner.streamClean(canonicalizer.canonicalize($0)) }
        )
    }

    private func polishKnownTerms() -> [String] {
        ["Epos"] + corrections.canonicalizer.canonicalVocabularyStrings
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

    private func bindHotkey() {
        hotkey.onPress = { [weak self] in self?.startRecording() }
        hotkey.onRelease = { [weak self] in self?.finishRecording() }
        hotkey.start()
    }

    public func startRecording() {
        guard state == .idle else {
            // A press during the finalize/polish window — the `await polisher.polish`
            // widens `.finalizing` by up to the generation time, and the user is starting
            // their next utterance. Abandon the in-flight polish so the window collapses
            // (utterance 1 keeps its already-typed raw text), and latch the press for
            // replay at `.finalizing → .idle`.
            if state == .finalizing {
                pendingDeferredStart = true
                activePolisher?.abandonInFlightPolish()
                log.info("start requested during finalize; abandoning polish, will retry at idle if fn held")
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
        finalizationPhase = .finalizingSpeech
        finalText = ""
        partial = ""
        amplitude = 0
        textInsertionSession = ProgressiveTranscriptInsertionSession(
            insertionSession: textInsertion.startInsertionSession(),
            // Strip hard fillers AND collapse stuttered function-word repeats ("the the")
            // from every partial BEFORE it is typed. The recognizer floats "uh"/"um" and
            // stutters in volatile partials; cleaning them here keeps them from flickering
            // on screen during streaming. `makePolisher` applies the SAME `streamClean` to
            // the final baseline so the cleaned text also survives finalization — without
            // that the final reconcile would re-type the raw tail and undo this. Both passes
            // are conservative (hard fillers only; a closed allow-list of always-stutter
            // words) so they never touch meaning.
            canonicalize: { [corrections] text in
                TranscriptDeterministicCleaner.streamClean(corrections.canonicalize(text))
            },
            target: AXInsertionTargetObserver()
        )
        transcriptTiming.start()
        indicator.show()
        let sessionPolisher = makePolisher()
        let contextualStrings = speechContextualStrings()
        activePolisher = sessionPolisher
        sessionPolisher.prewarm()
        log.info("recording start")

        transcriptionTask = Task { [weak self] in
            await self?.runSession(
                format: format,
                polisher: sessionPolisher,
                contextualStrings: contextualStrings
            )
        }
    }

    public func finishRecording() {
        guard state == .recording else { return }
        state = .finalizing
        finalizationPhase = .finalizingSpeech
        log.info("recording finalize")
        audio.stop()
        let transcriber = transcriber
        Task { await transcriber.finish() }
    }

    private func runSession(
        format: AVAudioFormat,
        polisher: TranscriptPolisher,
        contextualStrings: [String]
    ) async {
        let transcriber = self.transcriber
        let audio = self.audio
        let dogfood = self.dogfood
        let shouldSaveAudioSamples = settings.saveAudioSamples
        let shouldSaveCorrectionEvidence = settings.saveCorrectionEvidence
        let sessionRecordingID = currentRecordingID

        let events: AsyncStream<TranscriptEvent>
        do {
            events = try await transcriber.start(contextualStrings: contextualStrings)
            guard state == .recording else {
                cancelTextInsertionSession()
                await resetSessionStateBeforeIdle()
                log.info("recording done (finalChars=0 cancelledBeforeAudioStart=true)")
                returnToIdleAndCompleteRecordingLogScope(finishedRecordingID: sessionRecordingID)
                return
            }
            audio.onBuffer = { buffer in transcriber.accept(buffer) }
            audio.onAmplitude = { [weak self] amp in
                Task { @MainActor in
                    guard let self, self.state == .recording else { return }
                    self.amplitude = amp
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
            dogfood.stop(keeping: false)
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
                log.error("transcription failed: \(message)")
            }
        }

        audio.stop()
        // Promote unconditionally — including after a `.failed` event. The trailing
        // partial is already typed on screen; on the success path finals clear
        // `partial`, so this only fires when no `.final` settled it. Gating it on
        // failure made the empty-`finalText` branch below RETRACT (backspace) the
        // words the user just watched land, which is worse than committing the
        // best-effort partial.
        promotePartialTranscriptAsFallbackFinalIfNeeded()

        let hasTranscribedText = !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        dogfood.stop(keeping: shouldSaveAudioSamples && hasTranscribedText)

        if hasTranscribedText {
            // Opt-in LLM polish runs once on the final transcript while the
            // indicator is still up (state == .finalizing) on the per-recording
            // polisher prewarmed at start. It never throws and falls back to the raw
            // text, so the reconcile below is unchanged when polish is off,
            // unavailable, or rejected by the guard.
            finalizationPhase = polisher.willAttemptPolish ? .polishing : .inserting
            let polishStartedAt = Date()
            let result = await polisher.polish(finalText)
            finalizationPhase = .inserting
            // Insert reports whether keystrokes actually landed; if the append-only
            // latch suppressed the polish retype, downgrade `.applied` so the log
            // can't claim a polish the user never received.
            let applied = insertFinalTranscript(result.text)
            let effectiveOutcome = TranscriptPolisher.effectivePolishOutcome(result, applied: applied)
            let insertedTranscript = textInsertionSession?.insertedTranscript
            if let evidenceID = recordCorrectionEvidenceIfEnabled(
                enabled: shouldSaveCorrectionEvidence,
                rawTranscript: finalText,
                polishResult: result,
                effectiveOutcome: effectiveOutcome,
                applied: applied,
                finalInsertedTranscript: insertedTranscript == result.text ? insertedTranscript : nil,
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
            // Count raw and polished on the SAME normalization: both come from the
            // polisher's own canonicalizer — `result.text` for `.applied` is
            // canonicalize(polished), and `result.rawCharacterCount` is the matching
            // canonicalize(raw) baseline `polish` already computed. Reusing it here
            // avoids a third canonicalizer pass over the transcript in the finalize window.
            logPolishOutcome(
                outcome: effectiveOutcome,
                rawText: result.text,
                polishedCount: result.text.count,
                rawCount: result.rawCharacterCount,
                engineOutcome: result.engineOutcome,
                guardRejection: result.guardRejection,
                elapsedMs: millisecondsElapsed(since: polishStartedAt)
            )
            finishTextInsertionSession()
        } else {
            cancelTextInsertionSession(retractInsertedText: true)
        }

        let finalChars = finalText.count
        await resetSessionStateBeforeIdle()
        log.info("recording done (finalChars=\(finalChars))")
        returnToIdleAndCompleteRecordingLogScope(finishedRecordingID: sessionRecordingID)
    }

    func handlePartialTranscript(_ text: String) {
        partial = text
        textInsertionSession?.acceptPartialTranscript(displayText)
    }

    func handleFinalTranscriptSegment(_ text: String) {
        finalText += text
        partial = ""
        textInsertionSession?.acceptFinalTranscript(finalText)
    }

    func promotePartialTranscriptAsFallbackFinalIfNeeded() {
        guard !partial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        let fallbackFinalText = finalText + partial
        partial = ""
        _ = textInsertionSession?.acceptFallbackFinalTranscript(fallbackFinalText)
        finalText = fallbackFinalText
        log.info("recording promoted partial fallback finalChars=\(self.finalText.count)")
    }

    /// Insert the final (already-canonicalized, already-guard-validated) text and
    /// report whether keystrokes landed. Routes through the polished-final path so
    /// the validated string is typed verbatim (no second canonicalize pass).
    @discardableResult
    func insertFinalTranscript(_ text: String) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if let textInsertionSession {
            return textInsertionSession.acceptFinalPolishedTranscript(text)
        }

        let oneShotSession = ProgressiveTranscriptInsertionSession(
            insertionSession: textInsertion.startInsertionSession(),
            canonicalize: { [corrections] text in corrections.canonicalize(text) },
            target: AXInsertionTargetObserver()
        )
        let applied = oneShotSession.acceptFinalPolishedTranscript(text)
        oneShotSession.finish()
        return applied
    }

    @discardableResult
    func recordCorrectionEvidenceIfEnabled(
        enabled: Bool,
        rawTranscript: String,
        polishResult: PolishResult,
        effectiveOutcome: PolishOutcome,
        applied: Bool,
        finalInsertedTranscript: String? = nil,
        recordingID: String? = nil,
        session: ProgressiveTranscriptInsertionSession? = nil
    ) -> String? {
        guard enabled, finalInsertedTranscript != nil else { return nil }
        return recordCorrectionEvidence(
            rawTranscript: rawTranscript,
            polishResult: polishResult,
            effectiveOutcome: effectiveOutcome,
            applied: applied,
            finalInsertedTranscript: finalInsertedTranscript,
            recordingID: recordingID,
            session: session
        )
    }

    @discardableResult
    func recordCorrectionEvidence(
        rawTranscript: String,
        polishResult: PolishResult,
        effectiveOutcome: PolishOutcome,
        applied: Bool,
        finalInsertedTranscript: String? = nil,
        recordingID: String? = nil,
        session: ProgressiveTranscriptInsertionSession? = nil
    ) -> String {
        let canonicalizedRaw = corrections.canonicalize(rawTranscript)
        return correctionEvidence.record(CorrectionEvidence(
            id: UUID().uuidString,
            observedAt: Date(),
            recordingID: recordingID ?? currentRecordingID,
            rawTranscript: rawTranscript,
            canonicalizedTranscript: canonicalizedRaw,
            finalInsertedTranscript: finalInsertedTranscript ?? (applied ? polishResult.text : canonicalizedRaw),
            userEditedTranscript: nil,
            applicationBundleIdentifier: session?.targetApplicationBundleIdentifier(),
            windowTitle: session?.targetWindowTitle(),
            appliedRuleIDs: corrections.dictionary.appliedRecordIDs(in: rawTranscript),
            polishOutcome: effectiveOutcome.evidenceName,
            engineOutcome: polishResult.engineOutcome?.rawValue,
            guardRejectionReason: polishResult.guardRejection?.reason.rawValue
        ))
    }

    func scheduleObservedUserEditCapture(
        evidenceID: String,
        finalInsertedTranscript: String,
        session: ProgressiveTranscriptInsertionSession?
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
        session: ProgressiveTranscriptInsertionSession
    ) -> Bool {
        guard let observedInsertedText = session.observedInsertedText(),
              observedInsertedText != finalInsertedTranscript else {
            return false
        }

        return correctionEvidence.recordUserEdit(
            evidenceID: evidenceID,
            userEditedTranscript: observedInsertedText
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

    /// Local dogfood observability for the polish stage. Reads the policy's own
    /// `PolishOutcome` so the log can't drift from the decision the polisher
    /// actually made.
    func logPolishOutcome(
        outcome: PolishOutcome,
        rawText: String,
        polishedCount: Int,
        rawCount: Int,
        engineOutcome: PolishEngineOutcome? = nil,
        guardRejection: PolishGuardRejection? = nil,
        elapsedMs: Int
    ) {
        let engineDetail = engineOutcome.map { " engineOutcome=\($0.rawValue)" } ?? ""
        switch outcome {
        case .disabled:
            log.info("polish off (elapsedMs=\(elapsedMs))")
        case .unavailable:
            log.info("polish skipped: model unavailable (elapsedMs=\(elapsedMs))")
        case .timedOut:
            log.info("polish timed out (rawChars=\(rawCount) elapsedMs=\(elapsedMs))\(engineDetail)")
        case .tooLong:
            log.info("polish skipped: input too long (rawChars=\(rawCount) elapsedMs=\(elapsedMs))\(engineDetail)")
        case .sameText:
            log.info("polish skipped: model returned same text (rawChars=\(rawCount) elapsedMs=\(elapsedMs))\(engineDetail)")
        case .guardRejected:
            let rawDetail = includeTranscriptTextInDiagnostics
                ? "rawText=\(String(reflecting: rawText))"
                : "rawText=<redacted>"
            let detail = guardRejection?.logDescription(
                includeTranscriptText: includeTranscriptTextInDiagnostics
            ) ?? "reason=unknown"
            log.info(
                "polish rejected: retention guard " +
                    "(\(rawDetail) \(detail) rawChars=\(rawCount) elapsedMs=\(elapsedMs))" +
                    engineDetail
            )
        case .deterministicCleanup:
            let rejectionDetail = guardRejection.map {
                " guardRejected=\($0.logDescription(includeTranscriptText: includeTranscriptTextInDiagnostics))"
            } ?? ""
            log.info(
                "polish deterministic cleanup applied " +
                    "(rawChars=\(rawCount) polishedChars=\(polishedCount) elapsedMs=\(elapsedMs))" +
                    rejectionDetail +
                    engineDetail
            )
        case .engineFailed:
            log.info("polish fallback: engine failed (rawChars=\(rawCount) elapsedMs=\(elapsedMs))\(engineDetail)")
        case .abandoned:
            log.info("polish abandoned: new recording requested (rawChars=\(rawCount) elapsedMs=\(elapsedMs))\(engineDetail)")
        case .suppressedByInsertion:
            log.info(
                "polish suppressed: insertion append-only " +
                    "(rawChars=\(rawCount) polishedChars=\(polishedCount) elapsedMs=\(elapsedMs))" +
                    engineDetail
            )
        case .applied:
            log.info(
                "polish applied (rawChars=\(rawCount) polishedChars=\(polishedCount) elapsedMs=\(elapsedMs))" +
                    engineDetail
            )
        }
    }

    private func millisecondsElapsed(since start: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(start) * 1000))
    }

    private func finishTextInsertionSession() {
        textInsertionSession?.finish()
        textInsertionSession = nil
    }

    private func cancelTextInsertionSession(retractInsertedText: Bool = false) {
        if retractInsertedText {
            textInsertionSession?.cancelAndRetractInsertedText()
        } else {
            textInsertionSession?.cancel()
        }
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
        audio.onBuffer = nil
        audio.onAmplitude = nil
        audio.onRawBuffer = nil
        await transcriber.finish()
        indicator.hide()
        amplitude = 0
        partial = ""
        transcriptionTask = nil
        activePolisher = nil
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
