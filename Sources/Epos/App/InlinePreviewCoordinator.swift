import Foundation

/// Owns one recording's inline-preview session: creating it for the fn-press
/// application, mirroring the volatile transcript into it, discarding it, and
/// emitting the per-recording outcome line.
///
/// The session is handed to `FinalTranscriptCommitRouter` for an in-place
/// IME-commit attempt, which is why `session` is readable from outside.
@MainActor
final class InlinePreviewCoordinator {
    private let isEnabled: @MainActor () -> Bool
    private let log: EposLogger
    private let latency: RecordingLatencyDiagnostics?
    private let keyboardSourceFactory: @MainActor () -> PreviewKeyboardSource?
    private let transportFactory: @MainActor () -> any InlinePreviewTransport
    /// Raised and lowered by the session as its channel becomes (or stops being)
    /// healthy enough to mirror. Generation-guarded, so a stale session can never
    /// speak for a later recording.
    private let onMarkingActivityChange: @MainActor (Bool) -> Void
    private let onFirstMarkRendered: @MainActor () -> Void

    private(set) var session: InlinePreviewSession?
    private var discard: Task<Void, Never>?
    private var keyboardSource: PreviewKeyboardSource?
    /// Monotonic token so a stale session's marking-activity callback can never
    /// flip the HUD suppression of a later recording.
    private var generation = 0

    var isActive: Bool { session != nil }

    init(
        isEnabled: @escaping @MainActor () -> Bool,
        log: EposLogger,
        latency: RecordingLatencyDiagnostics? = nil,
        keyboardSourceFactory: @escaping @MainActor () -> PreviewKeyboardSource? = { PreviewKeyboardSource() },
        transportFactory: @escaping @MainActor () -> any InlinePreviewTransport = { UnixSocketInlinePreviewTransport() },
        onMarkingActivityChange: @escaping @MainActor (Bool) -> Void,
        onFirstMarkRendered: @escaping @MainActor () -> Void
    ) {
        self.isEnabled = isEnabled
        self.log = log
        self.latency = latency
        self.keyboardSourceFactory = keyboardSourceFactory
        self.transportFactory = transportFactory
        self.onMarkingActivityChange = onMarkingActivityChange
        self.onFirstMarkRendered = onFirstMarkRendered
    }

    func start(
        bundleIdentifier: String?, selectedRange: InsertionTargetTextRange?, holdKeyCode: UInt16? = nil,
        holdModifierFlags: UInt64? = nil,
        validateTarget: @escaping @MainActor @Sendable () -> Bool = { false }
    ) {
        // A skipped preview still starts a new recording. Retire every callback
        // from its predecessor before any early return.
        generation += 1
        session = nil
        discard = nil
        guard (selectedRange?.length ?? 0) == 0 else {
            log.info("inline preview skipped: fn-press text selection is nonempty")
            return
        }
        guard isEnabled(), let bundleIdentifier, !bundleIdentifier.isEmpty else { return }
        guard let keyboardSource = keyboardSourceFactory() else {
            log.info("inline preview unavailable: native keyboard source cannot be acquired status=\(PreviewKeyboardSource.status.rawValue)")
            return
        }
        self.keyboardSource = keyboardSource
        let acquisitionArgument = keyboardSource.acquisitionArgument
            + (holdKeyCode.map { code in
                " hold-key=\(code)" + (holdModifierFlags.map { " hold-flags=\($0)" } ?? "")
            } ?? "")
        guard let session = makeSession(
            bundleIdentifier: bundleIdentifier,
            acquisitionArgument: acquisitionArgument,
            validateTarget: validateTarget
        ) else {
            keyboardSource.release()
            self.keyboardSource = nil
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
        transport: (any InlinePreviewTransport)? = nil,
        acquisitionArgument: String? = nil,
        validateTarget: @escaping @MainActor @Sendable () -> Bool = { true },
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) -> InlinePreviewSession? {
        generation += 1
        guard isEnabled(), let bundleIdentifier, !bundleIdentifier.isEmpty else {
            return nil
        }
        let generation = generation
        return InlinePreviewSession(
            transport: transport ?? transportFactory(),
            bundleIdentifier: bundleIdentifier,
            acquisitionArgument: acquisitionArgument,
            sleep: sleep,
            validateTarget: validateTarget,
            onAcquisitionFailure: { [weak self] in
                guard let self, self.generation == generation else { return }
                self.releaseKeyboardSource()
            },
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
        latency?.begin(.previewDiscard)
        discard = Task { [latency] in
            await session.discard()
            let report = await session.report()
            latency?.end(.previewDiscard, outcome: report.cancelAcknowledged ? .completed : .unavailable)
        }
    }

    /// Waits out the discard and emits the one per-recording diagnostic line. The
    /// wait is bounded by the transport's per-operation socket timeouts, and is
    /// normally already satisfied because the discard started at fn release.
    ///
    /// Callers guard on `isActive` first: with no session there is nothing to
    /// finish and no HUD suppression to lift.
    ///
    /// Returns true when preview could have rendered and never committed. Final
    /// delivery settles that composition before authorizing its write.
    @discardableResult
    func finish() async -> Bool {
        guard let session else { return false }
        startDiscard()
        await discard?.value
        let report = await session.report()
        let compositionMayLinger = report.mayHaveRendered && !report.committed
        log.info(report.logLine)
        self.session = nil
        discard = nil
        releaseKeyboardSource(keepingSelected: report.commitMayHaveExecuted)
        return compositionMayLinger
    }

    private func releaseKeyboardSource(keepingSelected: Bool = false) {
        keyboardSource?.release(keepingSelected: keepingSelected)
        keyboardSource = nil
    }
}
