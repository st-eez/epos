import Foundation

/// Owns one recording's inline-preview session: creating it for the fn-press
/// application, mirroring the volatile transcript into it, discarding it, and
/// emitting the per-recording outcome line.
///
/// Preview only — the marked text is always gone before the one authoritative
/// write. The session it holds is handed to `FinalTranscriptCommitRouter` for the
/// IME-commit attempt, which is why `session` is readable from outside.
@MainActor
final class InlinePreviewCoordinator {
    private let isEnabled: @MainActor () -> Bool
    private let log: EposLogger
    /// Raised and lowered by the session as its channel becomes (or stops being)
    /// healthy enough to mirror. Generation-guarded, so a stale session can never
    /// speak for a later recording.
    private let onMarkingActivityChange: @MainActor (Bool) -> Void
    private let onFirstMarkRendered: @MainActor () -> Void

    private(set) var session: InlinePreviewSession?
    private var discard: Task<Void, Never>?
    /// Monotonic token so a stale session's marking-activity callback can never
    /// flip the HUD suppression of a later recording.
    private var generation = 0

    var isActive: Bool { session != nil }

    init(
        isEnabled: @escaping @MainActor () -> Bool,
        log: EposLogger,
        onMarkingActivityChange: @escaping @MainActor (Bool) -> Void,
        onFirstMarkRendered: @escaping @MainActor () -> Void
    ) {
        self.isEnabled = isEnabled
        self.log = log
        self.onMarkingActivityChange = onMarkingActivityChange
        self.onFirstMarkRendered = onFirstMarkRendered
    }

    func start(bundleIdentifier: String?) {
        session = nil
        discard = nil
        guard let session = makeSession(bundleIdentifier: bundleIdentifier) else {
            if isEnabled() {
                // Correlates a "saw nothing in app X" report with an unidentifiable
                // fn-press target rather than a rendering failure.
                log.info("inline preview skipped: no target bundle id")
            }
            return
        }
        self.session = session
        Task { await session.begin() }
    }

    /// Preview needs the fn-press application up front, because the probe pins its
    /// focus lock by bundle id. An unidentifiable target means no preview this
    /// recording — never a delayed or retried one.
    func makeSession(
        bundleIdentifier: String?,
        transport: (any InlinePreviewTransport)? = nil
    ) -> InlinePreviewSession? {
        guard isEnabled(), let bundleIdentifier, !bundleIdentifier.isEmpty else {
            return nil
        }
        generation += 1
        let generation = generation
        return InlinePreviewSession(
            transport: transport ?? UnixSocketInlinePreviewTransport(),
            bundleIdentifier: bundleIdentifier,
            onMarkingActivityChange: { [weak self] active in
                Task { @MainActor in
                    guard let self, self.generation == generation else { return }
                    self.onMarkingActivityChange(active)
                }
            },
            onFirstMarkRendered: { [weak self] in
                Task { @MainActor in
                    guard let self, self.generation == generation else { return }
                    self.onFirstMarkRendered()
                }
            }
        )
    }

    /// Test staging: installs the session `start` would have created, so
    /// release/commit ordering can be pinned without a live speech pipeline.
    func stage(_ session: InlinePreviewSession?) {
        self.session = session
    }

    /// Mirror exactly what the HUD shows. Off unless the preview is enabled, where
    /// it costs one nil check per recognizer event.
    func mirror(_ text: String) {
        guard let session else { return }
        Task { await session.mark(text) }
    }

    func startDiscard() {
        guard let session, discard == nil else { return }
        discard = Task { await session.discard() }
    }

    /// Waits out the discard and emits the one per-recording diagnostic line. The
    /// wait is bounded by the transport's per-operation socket timeouts, and is
    /// normally already satisfied because the discard started at fn release.
    ///
    /// Callers guard on `isActive` first: with no session there is nothing to
    /// finish and no HUD suppression to lift.
    ///
    /// Returns true when a mark was attempted and never committed — the one
    /// case where marked text may still be drawn over the field at return time,
    /// and the only recording whose final write needs a baseline settle.
    @discardableResult
    func finish() async -> Bool {
        guard let session else { return false }
        startDiscard()
        await discard?.value
        let report = await session.report()
        let compositionMayLinger = report.didAttemptMark && !report.committed
        if compositionMayLinger {
            // Keyed to the attempt, not the ack: a mark whose reply timed out
            // leaves marksSent at zero and may still be drawn in the field, and
            // that is exactly the case keystrokes must not land on top of.
            // After an acked IME commit no keystrokes follow, so there is nothing
            // to settle for.
            try? await Task.sleep(for: InlinePreviewSession.compositionSettleDelay)
        }
        log.info(report.logLine)
        self.session = nil
        discard = nil
        return compositionMayLinger
    }
}
