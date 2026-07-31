import Foundation

/// Records one dictation's correction evidence, then watches the fn-press field for
/// the user's own edit of the text that was inserted there.
///
/// The watch is a sparse poll rather than an AX notification subscription: the
/// insertion target is frequently opaque (Electron), and a span read is only
/// attributable to this transcript until the next dictation types into the field —
/// which is why `AppCoordinator` cancels the outstanding checks at the next press.
@MainActor
final class CorrectionEvidenceRecorder {
    private let corrections: CorrectionStore
    private let evidence: CorrectionEvidenceStore
    private let captureDelays: [TimeInterval]
    /// The recording an evidence row belongs to when the caller does not name one.
    private let currentRecordingID: @MainActor () -> String?
    private var captureWorkItems: [DispatchWorkItem] = []

    init(
        corrections: CorrectionStore,
        evidence: CorrectionEvidenceStore,
        captureDelays: [TimeInterval],
        currentRecordingID: @escaping @MainActor () -> String?
    ) {
        self.corrections = corrections
        self.evidence = evidence
        self.captureDelays = captureDelays
        self.currentRecordingID = currentRecordingID
    }

    @discardableResult
    func recordIfEnabled(
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
        return record(
            rawTranscript: rawTranscript,
            finalTranscript: finalTranscript,
            applied: applied,
            finalInsertedTranscript: finalInsertedTranscript,
            recordingID: recordingID,
            session: session
        )
    }

    @discardableResult
    func record(
        rawTranscript: String,
        finalTranscript: String,
        applied: Bool,
        finalInsertedTranscript: String? = nil,
        recordingID: String? = nil,
        session: FinalTranscriptInsertionSession? = nil
    ) -> String {
        let canonicalizedRaw = corrections.canonicalize(rawTranscript)
        return evidence.record(CorrectionEvidence(
            id: UUID().uuidString,
            observedAt: Date(),
            recordingID: recordingID ?? currentRecordingID(),
            rawTranscript: rawTranscript,
            canonicalizedTranscript: canonicalizedRaw,
            finalInsertedTranscript: finalInsertedTranscript ?? (applied ? finalTranscript : canonicalizedRaw),
            userEditedTranscript: nil,
            applicationBundleIdentifier: session?.targetApplicationBundleIdentifier(),
            windowTitle: session?.targetWindowTitle(),
            appliedRuleIDs: corrections.dictionary.appliedRecordIDs(in: rawTranscript)
        ))
    }

    /// The evidence row for the row just written and the field it landed in: read
    /// back at each configured delay until one read differs from what was inserted.
    func scheduleObservedUserEditCapture(
        evidenceID: String,
        finalInsertedTranscript: String,
        session: FinalTranscriptInsertionSession?
    ) {
        cancelObservedEditCaptureChecks()
        guard let session else { return }

        let delays = captureDelays.isEmpty ? [0] : captureDelays

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
            captureWorkItems.append(workItem)
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

        return evidence.recordUserEdit(
            evidenceID: evidenceID,
            userEditedTranscript: validatedEdit
        )
    }

    func cancelObservedEditCaptureChecks() {
        captureWorkItems.forEach { $0.cancel() }
        captureWorkItems = []
    }
}
