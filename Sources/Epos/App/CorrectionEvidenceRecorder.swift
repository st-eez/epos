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
    private let evidence: CorrectionEvidenceStore
    private let captureDelays: [TimeInterval]
    /// The recording an evidence row belongs to when the caller does not name one.
    private let currentRecordingID: @MainActor () -> String?
    private var captureTasks: [Task<Void, Never>] = []

    init(
        evidence: CorrectionEvidenceStore,
        captureDelays: [TimeInterval],
        currentRecordingID: @escaping @MainActor () -> String?
    ) {
        self.evidence = evidence
        self.captureDelays = captureDelays
        self.currentRecordingID = currentRecordingID
    }

    @discardableResult
    func recordIfEnabled(
        enabled: Bool,
        rawTranscript: String,
        correctionResult: CorrectionRuleMatchResult,
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
            correctionResult: correctionResult,
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
        correctionResult: CorrectionRuleMatchResult,
        finalTranscript: String,
        applied: Bool,
        finalInsertedTranscript: String? = nil,
        recordingID: String? = nil,
        session: FinalTranscriptInsertionSession? = nil
    ) -> String {
        let canonicalizedRaw = correctionResult.output
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
            appliedRuleIDs: correctionResult.appliedRecordIDs
        ))
    }

    /// The evidence row for the row just written and the field it landed in: read
    /// back at each configured delay until one read differs from what was inserted.
    @discardableResult
    func scheduleObservedUserEditCapture(
        evidenceID: String,
        finalInsertedTranscript: String,
        session: FinalTranscriptInsertionSession?,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { delay in
            try await Task.sleep(for: .seconds(delay))
        }
    ) -> [Task<Void, Never>] {
        cancelObservedEditCaptureChecks()
        guard let session else { return [] }

        let delays = captureDelays.isEmpty ? [0] : captureDelays

        for delay in delays {
            guard delay > 0 else {
                if captureObservedUserEdit(
                    evidenceID: evidenceID,
                    finalInsertedTranscript: finalInsertedTranscript,
                    session: session
                ) {
                    cancelObservedEditCaptureChecks()
                    return []
                }
                continue
            }

            let task = Task { [weak self, session, evidenceID, finalInsertedTranscript] in
                do {
                    try await sleep(delay)
                    try Task.checkCancellation()
                } catch {
                    return
                }
                guard let self else { return }
                if self.captureObservedUserEdit(
                    evidenceID: evidenceID,
                    finalInsertedTranscript: finalInsertedTranscript,
                    session: session
                ) {
                    self.cancelObservedEditCaptureChecks()
                }
            }
            captureTasks.append(task)
        }
        return captureTasks
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
        captureTasks.forEach { $0.cancel() }
        captureTasks = []
    }
}
