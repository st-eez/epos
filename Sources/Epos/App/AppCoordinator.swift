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
    @Published public private(set) var state: CoordinatorState = .idle
    @Published public private(set) var finalizationPhase: FinalizationPhase = .finalizingSpeech
    @Published public private(set) var finalText: String = ""
    @Published public private(set) var partial: String = ""
    @Published public private(set) var amplitude: Float = 0
    @Published public private(set) var settings: Settings

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
    private var transcriptTiming = TranscriptTimingDiagnostics()

    private var transcriptionTask: Task<Void, Never>?
    private var captureFormat: AVAudioFormat?
    private var textInsertionSession: ProgressiveTranscriptInsertionSession?
    private var observedEditCaptureWorkItems: [DispatchWorkItem] = []
    private var currentRecordingID: String?
    /// Set when a press arrives during the finalize/polish window (state != .idle),
    /// where `startRecording` would otherwise silently drop it. The press also abandons
    /// the in-flight polish (via `activePolisher`) to collapse the window, then is
    /// replayed at the `.finalizing → .idle` transition if fn is still physically held —
    /// so a back-to-back utterance isn't lost to the polish-widened window.
    private var pendingStartWhileFinalizing = false
    /// The current recording's polisher, held so a re-press during finalize can abandon
    /// its in-flight polish. Set at `startRecording`, cleared in `resetToIdle`. (Distinct
    /// from threading it into `runSession`, which is what actually runs the polish.)
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
        observedEditCaptureDelays: [TimeInterval] = AppCoordinator.defaultObservedEditCaptureDelays,
        autoStart: Bool = true
    ) {
        self.hotkey = hotkey
        self.audio = audio
        self.textInsertion = textInsertion
        self.polishEngine = polishEngine ?? PolishEngineFactory.makeDefault()
        self.log = EposLogger(category: "coordinator", diagnostics: diagnostics)
        self.correctionEvidence = correctionEvidence
        self.recordingIDGenerator = recordingIDGenerator
        self.observedEditCaptureDelays = observedEditCaptureDelays
        self.settings = settings
        self.permissions = PermissionsGate()
        self.assets = AssetManager(locale: settings.locale)
        self.transcriber = Transcriber(locale: settings.locale)
        if autoStart {
            bindHotkey()
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

    public var polishEnabled: Bool { settings.polishEnabled }

    public func setPolishEnabled(_ enabled: Bool) {
        guard settings.polishEnabled != enabled else { return }
        settings.polishEnabled = enabled
        settings.save()
        log.info("dictation polish \(enabled ? "enabled" : "disabled")")
    }

    /// Built once per recording so a mid-session settings change cannot alter the
    /// finalization behavior of an already-running dictation.
    private func makePolisher() -> TranscriptPolisher {
        // Snapshot the value-type canonicalizer so the guard validates — and the
        // polisher returns — `canonicalize(polished)`, the exact string that meets
        // the on-screen `canonicalize(rawStream)`. The snapshot also freezes the
        // rules for this recording, matching the build-once-per-recording intent.
        let canonicalizer = corrections.canonicalizer
        // Only walk the correction rules for known terms when polish is on; when it's
        // off (the default) the polisher short-circuits at its `enabled` gate and never
        // reads `knownTerms`, so computing them on the fn-press hot path is wasted work.
        return TranscriptPolisher(
            enabled: settings.polishEnabled,
            engine: polishEngine,
            knownTerms: settings.polishEnabled ? polishKnownTerms() : [],
            canonicalize: { canonicalizer.canonicalize($0) }
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
        _ = await assets.prepare()
        captureFormat = await transcriber.bestAudioFormat()
        log.info("bootstrap done format=\(String(describing: self.captureFormat))")
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
            // (utterance 1 keeps its already-typed raw text), and latch the press so it's
            // replayed at `.finalizing → .idle` if fn is still down (the edge-triggered
            // hotkey emits no new press for a key that's already held).
            if state == .finalizing {
                pendingStartWhileFinalizing = true
                activePolisher?.abandonInFlightPolish()
                log.info("start requested during finalize; abandoning polish, will retry at idle if fn held")
            }
            return
        }
        guard let format = captureFormat else {
            log.error("cannot start: capture format unavailable (bootstrap incomplete?)")
            return
        }
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
            canonicalize: { [corrections] text in corrections.canonicalize(text) },
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

        let events: AsyncStream<TranscriptEvent>
        do {
            events = try await transcriber.start(contextualStrings: contextualStrings)
            guard state == .recording else {
                cancelTextInsertionSession()
                await resetToIdle()
                log.info("recording done (finalChars=0 cancelledBeforeAudioStart=true)")
                completeRecordingLogScope()
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
                let recordingID = currentRecordingID
                audio.onRawBuffer = { buffer in dogfood.write(buffer, recordingID: recordingID) }
            } else {
                audio.onRawBuffer = nil
            }
            try audio.start(targetFormat: format)
        } catch {
            log.error("recording setup failed: \(String(describing: error))")
            dogfood.stop(keeping: false)
            cancelTextInsertionSession()
            await resetToIdle()
            log.info("recording done (finalChars=0 failed=true)")
            completeRecordingLogScope()
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
            let evidenceID = recordCorrectionEvidence(
                rawTranscript: finalText,
                polishResult: result,
                effectiveOutcome: effectiveOutcome,
                applied: applied,
                session: textInsertionSession
            )
            if let finalInsertedTranscript = correctionEvidence.evidence.last(where: { $0.id == evidenceID })?.finalInsertedTranscript {
                scheduleObservedUserEditCapture(
                    evidenceID: evidenceID,
                    finalInsertedTranscript: finalInsertedTranscript,
                    session: textInsertionSession
                )
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
            cancelTextInsertionSession()
        }

        let finalChars = finalText.count
        await resetToIdle()
        log.info("recording done (finalChars=\(finalChars))")
        completeRecordingLogScope()
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
    func recordCorrectionEvidence(
        rawTranscript: String,
        polishResult: PolishResult,
        effectiveOutcome: PolishOutcome,
        applied: Bool,
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
            finalInsertedTranscript: applied ? polishResult.text : canonicalizedRaw,
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
            let detail = guardRejection?.logDescription ?? "reason=unknown"
            log.info(
                "polish rejected: retention guard " +
                    "(rawText=\(String(reflecting: rawText)) \(detail) rawChars=\(rawCount) elapsedMs=\(elapsedMs))" +
                    engineDetail
            )
        case .deterministicCleanup:
            let rejectionDetail = guardRejection.map { " guardRejected=\($0.logDescription)" } ?? ""
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

    private func cancelTextInsertionSession() {
        textInsertionSession?.cancel()
        textInsertionSession = nil
    }

    /// Common teardown shared by every exit from `runSession`. Each piece is idempotent
    /// (callbacks set to nil, `finish()` is idempotent). Path-specific work — `audio.stop()`,
    /// `dogfood.stop(keeping:)`, insertion session closeout — stays at the call sites; only
    /// what every path does identically lives here, so the three exits can't drift apart again.
    private func resetToIdle() async {
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
        state = .idle
    }

    private func completeRecordingLogScope() {
        let finishedRecordingID = currentRecordingID
        currentRecordingID = nil
        replayPendingStartIfNeeded()
        RecordingLogContext.clear(finishedRecordingID)
    }

    /// Retry, at the `.finalizing → .idle` transition, a start that arrived during the
    /// finalize/polish window. The edge-triggered hotkey produces no new `onPress` for
    /// an already-held key, so a press latched there would otherwise be lost; replay it
    /// only while fn is still physically held — a key released during the window is
    /// dropped (the user no longer wants to record).
    private func replayPendingStartIfNeeded() {
        guard pendingStartWhileFinalizing else { return }
        pendingStartWhileFinalizing = false
        guard hotkey.isFunctionKeyDown else {
            log.info("pending start dropped: fn released during finalize")
            return
        }
        log.info("replaying start: fn still held after finalize")
        startRecording()
    }
}
