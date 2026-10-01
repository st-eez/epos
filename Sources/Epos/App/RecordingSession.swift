import AVFoundation
import Foundation

/// Owns one fn hold from microphone open through one guarded final write.
/// The coordinator presents these events and accepts another hold only after cleanup.
@MainActor
final class RecordingSession {
    enum Event {
        case amplitude(Float)
        case transcript(final: String, partial: String, display: String)
        case previewActivity(Bool)
        case firstMarkRendered
        case captureFailed
        case recognitionFailedWhileHeld
        case inserting
        case insertionUnavailable(String)
        case completed(startNotice: String?)
    }

    private enum Phase { case held, released, finished }
    let recordingID: String?
    private(set) var task: Task<Void, Never>?
    private let audio: any MicrophoneCapture
    private let transcriber: any SpeechTranscribing
    private let textInsertion: TextInsertionBackend
    private let targetObserverFactory: @MainActor () -> any InsertionTargetObserver
    private let settings: Settings
    private let cleanTranscript: @Sendable (String) -> String
    private let contextualStrings: [String]
    private let reliability: ReliabilityRecording?
    private let evidenceRecorder: CorrectionEvidenceRecorder
    private let correctionEvidence: CorrectionEvidenceStore
    private let isFnKeyHeld: @MainActor () -> Bool
    private let isMicrophoneAccessMissing: @MainActor () -> Bool
    private let onEvent: @MainActor (RecordingSession, Event) -> Void
    private let log: EposLogger
    private let injectLog: EposLogger
    private let dogfood = DogfoodTap()
    private let preRoll = CapturePreRoll()
    private var phase = Phase.held
    private var microphoneOpen = false
    private var analyzerReadyForAudio = false
    private var analyzerFinishTask: Task<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var textInsertionSession: FinalTranscriptInsertionSession?
    private var finalText = ""
    private var partial = ""
    private var displayText = ""
    private var transcriptTiming: TranscriptTimingDiagnostics
    private var previewMirroring = false
    private lazy var preview = InlinePreviewCoordinator(
        isEnabled: { [weak self] in self?.settings.inlinePreview ?? false },
        log: injectLog,
        onMarkingActivityChange: { [weak self] active in
            guard let self, self.phase != .finished else { return }
            self.previewMirroring = active
            self.onEvent(self, .previewActivity(active))
        },
        onFirstMarkRendered: { [weak self] in
            guard let self, self.phase == .held else { return }
            self.onEvent(self, .firstMarkRendered)
        }
    )

    init(
        recordingID: String?,
        audio: any MicrophoneCapture,
        transcriber: any SpeechTranscribing,
        textInsertion: TextInsertionBackend,
        targetObserverFactory: @escaping @MainActor () -> any InsertionTargetObserver,
        settings: Settings,
        cleanTranscript: @escaping @Sendable (String) -> String,
        contextualStrings: [String],
        diagnostics: DiagnosticLogSink,
        evidenceRecorder: CorrectionEvidenceRecorder,
        correctionEvidence: CorrectionEvidenceStore,
        isFnKeyHeld: @escaping @MainActor () -> Bool,
        isMicrophoneAccessMissing: @escaping @MainActor () -> Bool,
        includeTranscriptText: Bool,
        onEvent: @escaping @MainActor (RecordingSession, Event) -> Void
    ) {
        self.recordingID = recordingID
        self.audio = audio
        self.transcriber = transcriber
        self.textInsertion = textInsertion
        self.targetObserverFactory = targetObserverFactory
        self.settings = settings
        self.cleanTranscript = cleanTranscript
        self.contextualStrings = contextualStrings
        self.reliability = recordingID.map { ReliabilityRecording(recordingID: $0, diagnostics: diagnostics) }
        self.evidenceRecorder = evidenceRecorder
        self.correctionEvidence = correctionEvidence
        self.isFnKeyHeld = isFnKeyHeld
        self.isMicrophoneAccessMissing = isMicrophoneAccessMissing
        self.onEvent = onEvent
        self.log = EposLogger(category: "coordinator", diagnostics: diagnostics)
        self.injectLog = EposLogger(category: "inject", diagnostics: diagnostics)
        self.transcriptTiming = TranscriptTimingDiagnostics(includeTranscriptText: includeTranscriptText)
    }

    /// Synchronous microphone open precedes the AX baseline and analyzer startup.
    func start(format: AVAudioFormat) {
        audio.onBuffer = { [preRoll, reliability] buffer in
            reliability?.recordAudioBuffer(frameCount: Int(buffer.frameLength))
            preRoll.accept(buffer)
        }
        audio.onAmplitude = { [weak self] amplitude in
            Task { @MainActor in
                guard let self, self.phase == .held, self.microphoneOpen else { return }
                self.onEvent(self, .amplitude(amplitude))
            }
        }
        audio.onRawBuffer = settings.saveAudioSamples
            ? { [dogfood, recordingID] buffer in dogfood.write(buffer, recordingID: recordingID) }
            : nil
        audio.onCaptureFailure = { [weak self] error in
            guard let self, self.phase == .held, self.microphoneOpen else { return }
            self.log.error("recording cut short: microphone capture failed (\(String(describing: error)))")
            self.reliability?.emit(.captureInterrupted)
            self.onEvent(self, .captureFailed)
        }
        do {
            try audio.start(targetFormat: format, echoCancellation: settings.echoCancellation)
            microphoneOpen = true
        } catch {
            log.error("recording setup failed: capture start (\(String(describing: error)))")
            reliability?.emit(.setupFailed)
            stopMicrophone()
            clearAudioCallbacks()
            dogfood.stop(keeping: settings.saveAudioSamples)
            complete(finalCharacters: 0, startNotice: StartReadiness.ready.noticeLabel, failed: true)
            return
        }
        RecordingCue.playStart()
        textInsertionSession = FinalTranscriptInsertionSession(
            insertionSession: textInsertion.startInsertionSession(),
            target: targetObserverFactory(),
            recordingID: recordingID
        )
        preview.start(
            bundleIdentifier: textInsertionSession?.targetApplicationBundleIdentifier(),
            selectedRange: textInsertionSession?.baselineSelectedRange
        )
        transcriptTiming.start()
        task = Task { await run() }
    }

    /// Stop capture at release, but drain startup audio before finalizing the analyzer.
    func release() {
        guard phase == .held else { return }
        phase = .released
        reliability?.markReleased()
        releaseWaiter?.resume()
        releaseWaiter = nil
        if !previewMirroring { preview.startDiscard() }
        log.info("recording finalize")
        stopMicrophone()
        if analyzerReadyForAudio { finishAnalyzer() }
    }

    private func finishAnalyzer() {
        guard analyzerFinishTask == nil else { return }
        let transcriber = transcriber
        analyzerFinishTask = Task { await transcriber.finish() }
    }

    private func run() async {
        let events: AsyncStream<TranscriptEvent>
        do {
            events = try await transcriber.start(contextualStrings: contextualStrings)
            let transcriber = transcriber
            let buffers = preRoll.attach { buffer in transcriber.accept(buffer) }
            analyzerReadyForAudio = true
            log.info("capture pre-roll handed to the analyzer (buffers=\(buffers))")
            if phase == .released { finishAnalyzer() }
        } catch {
            log.error("recording setup failed: \(String(describing: error))")
            reliability?.emit(.setupFailed)
            await cleanup()
            complete(finalCharacters: 0, startNotice: StartReadiness.ready.noticeLabel, failed: true)
            return
        }

        var recognizerFailed = false
        transcriptEvents: for await event in events {
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
                break transcriptEvents
            }
        }
        stopMicrophone()
        promotePartialTranscriptAsFallbackFinalIfNeeded()
        if recognizerFailed, phase == .held, isFnKeyHeld() {
            log.error("recognizer failed while fn was held; holding the transcript until release")
            onEvent(self, .recognitionFailedWhileHeld)
            await withCheckedContinuation { releaseWaiter = $0 }
        }
        let finalTranscript = cleanTranscript(finalText)
        var microphoneDenied = false
        if !finalTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            onEvent(self, .inserting)
            await deliverFinalTranscript(
                finalTranscript,
                recognizerFailed: recognizerFailed
            )
        } else {
            microphoneDenied = !recognizerFailed && isMicrophoneAccessMissing()
            if microphoneDenied {
                log.error("recording produced no transcript: microphone access is not granted")
            }
            reliability?.emit(
                recognizerFailed ? .recognizerFailed : microphoneDenied ? .microphoneDenied :
                    (reliability?.hasAudioInput == true ? .emptyTranscript : .noInput)
            )
        }
        await cleanup()
        complete(
            finalCharacters: finalTranscript.count,
            startNotice: microphoneDenied ? StartBlocker.microphoneDenied.noticeLabel : nil
        )
    }

    func handlePartialTranscript(_ text: String) {
        guard phase != .finished else { return }
        partial = text
        refreshDisplayText()
        preview.mirror(displayText)
    }

    func handleFinalTranscriptSegment(_ text: String) {
        guard phase != .finished else { return }
        finalText += text
        partial = ""
        refreshDisplayText()
        preview.mirror(displayText)
    }

    private func refreshDisplayText() {
        displayText = cleanTranscript(finalText + partial)
        onEvent(self, .transcript(final: finalText, partial: partial, display: displayText))
    }

    func promotePartialTranscriptAsFallbackFinalIfNeeded() {
        guard !partial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        finalText += partial
        partial = ""
        refreshDisplayText()
        log.info("recording promoted partial fallback finalChars=\(finalText.count)")
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

    func makeInlinePreviewSession(
        bundleIdentifier: String?,
        transport: (any InlinePreviewTransport)?
    ) -> InlinePreviewSession? {
        preview.makeSession(bundleIdentifier: bundleIdentifier, transport: transport)
    }

    func stageFinalizationSessions(
        inlinePreview: InlinePreviewSession?,
        insertion: FinalTranscriptInsertionSession?
    ) {
        preview.stage(inlinePreview)
        textInsertionSession = insertion
    }

    @discardableResult
    private func finishInlinePreview() async -> Bool {
        guard preview.isActive else { return false }
        let compositionMayLinger = await preview.finish()
        previewMirroring = false
        onEvent(self, .previewActivity(false))
        return compositionMayLinger
    }

    /// The one authoritative write for a recording that produced text, plus the
    /// evidence and reliability records that describe how it went.
    private func deliverFinalTranscript(
        _ finalTranscript: String,
        recognizerFailed: Bool
    ) async {
        switch await commitFinalTranscript(finalTranscript) {
        case .completed(let insertionResult, let viaIME):
            let applied = insertionResult == .accepted
            if !applied {
                // A refusal caused by revoked Accessibility is not the user
                // having clicked away, and "Not inserted" would send them
                // looking for the wrong thing.
                onEvent(self, .insertionUnavailable(
                    insertionResult == .accessibilityUntrusted
                        ? "No access"
                        : AppCoordinator.defaultInsertionNotice
                ))
            }
            let insertedTranscript = textInsertionSession?.insertedTranscript
            if let evidenceID = evidenceRecorder.recordIfEnabled(
                enabled: settings.saveCorrectionEvidence,
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
        let previewSession = preview.session
        if let session = previewSession,
           let route = await FinalTranscriptCommitRouter.attemptIMECommit(
               transcript: transcript,
               preview: session,
               insertion: textInsertionSession
           ) {
            await finishInlinePreview()
            return route
        }
        // Ordering is load-bearing: the marked text must be gone before the one
        // guarded write, or the field shows the utterance twice. Only a
        // composition that may still be drawn needs the baseline settle — it
        // gives a Chromium host's asynchronous un-mark a bounded window to
        // leave the AX value before the guard reads it; a recording that never
        // marked has nothing to wait for, and its refusals stay instant.
        let compositionMayLinger = await finishInlinePreview()
        if await previewSession?.hasUnsafeTarget() == true {
            cancelTextInsertionSession()
            return .completed(.targetRefused, viaIME: false)
        }
        if compositionMayLinger {
            await textInsertionSession?.settleReadableBaseline()
        }
        return .completed(insertFinalTranscriptResult(transcript), viaIME: false)
    }

    func insertFinalTranscriptResult(_ text: String) -> FinalInsertionResult {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .backendRefused
        }
        return textInsertionSession?.insertFinalResult(text) ?? .backendRefused
    }

    private func emitFinalReliabilityOutcome(
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

    /// Every exit closes this hold's resources before its completion reaches the UI.
    private func cleanup() async {
        stopMicrophone()
        clearAudioCallbacks()
        dogfood.stop(keeping: settings.saveAudioSamples)
        await finishInlinePreview()
        cancelTextInsertionSession()
        finishAnalyzer()
        await analyzerFinishTask?.value
        transcriptTiming.finish()
    }

    private func stopMicrophone() {
        microphoneOpen = false
        preRoll.stopAccepting()
        audio.stop()
    }

    private func clearAudioCallbacks() {
        audio.onBuffer = nil
        audio.onAmplitude = nil
        audio.onRawBuffer = nil
        audio.onCaptureFailure = nil
    }

    private func complete(finalCharacters: Int, startNotice: String?, failed: Bool = false) {
        phase = .finished
        releaseWaiter?.resume()
        releaseWaiter = nil
        task = nil
        log.info("recording done (finalChars=\(finalCharacters)\(failed ? " failed=true" : ""))")
        if let recordingID { RecordingLogContext.clear(recordingID) }
        onEvent(self, .completed(startNotice: startNotice))
    }
}
