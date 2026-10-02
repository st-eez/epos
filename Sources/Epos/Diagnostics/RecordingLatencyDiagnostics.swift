import Foundation

/// Per-recording monotonic durations. The same instance follows detached
/// readback after the recording session has returned to idle.
public final class RecordingLatencyDiagnostics: @unchecked Sendable {
    enum Stage: String, Sendable {
        case microphoneOpen = "microphone-open"
        case targetBaseline = "target-baseline"
        case analyzerStartup = "analyzer-startup"
        case firstRecognizerResult = "first-recognizer-result"
        case firstDisplayPublication = "first-display-publication"
        case firstMarkAcknowledged = "first-mark-acknowledged"
        case recognizerFinalization = "recognizer-finalization"
        case transcriptCleanup = "transcript-cleanup"
        case previewCancel = "preview-cancel"
        case previewDiscard = "preview-discard"
        case compositionSettle = "composition-settle"
        case baselineSettle = "baseline-settle"
        case targetAuthorization = "target-authorization"
        case imeCommit = "ime-commit"
        case keystrokeWrite = "keystroke-write"
        case releaseToWrite = "release-to-write"
        case deliveryReadback = "delivery-readback"
        case sessionCleanup = "session-cleanup"
    }

    enum Outcome: String, Sendable { case completed, failed, refused, ambiguous, unavailable }

    private struct Interval {
        let start: ContinuousClock.Instant
        let attempt: Int
    }

    private let recordingID: String
    private let log: EposLogger
    private let now: @Sendable () -> ContinuousClock.Instant
    private let origin: ContinuousClock.Instant
    private let lock = NSLock()
    private var active: [Stage: Interval] = [:]
    private var attempts: [Stage: Int] = [:]

    init(
        recordingID: String,
        diagnostics: DiagnosticLogSink = .shared,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock().now }
    ) {
        self.recordingID = recordingID
        self.log = EposLogger(category: "timing", diagnostics: diagnostics)
        self.now = now
        self.origin = now()
    }

    func begin(_ stage: Stage) {
        lock.withLock {
            guard active[stage] == nil else { return }
            let attempt = (attempts[stage] ?? 0) + 1
            attempts[stage] = attempt
            active[stage] = Interval(start: now(), attempt: attempt)
        }
    }

    func end(_ stage: Stage, outcome: Outcome = .completed) {
        emit(stage, outcome: outcome, measured: true)
    }

    /// A missing first result is not a zero-latency result. End its outstanding
    /// interval without a duration so the audit counts it but cannot score it.
    func abandon(_ stage: Stage) {
        emit(stage, outcome: .unavailable, measured: false)
    }

    private func emit(_ stage: Stage, outcome: Outcome, measured: Bool) {
        let message: String? = lock.withLock {
            guard let interval = active.removeValue(forKey: stage) else { return nil }
            let end = now()
            let duration = measured ? Self.milliseconds(interval.start.duration(to: end)) : -1
            let elapsed = Self.milliseconds(origin.duration(to: end))
            return "recording timing schema=1 stage=\(stage.rawValue) attempt=\(interval.attempt) "
                + "durationMs=\(Self.format(duration)) elapsedMs=\(Self.format(elapsed)) "
                + "outcome=\(outcome.rawValue)"
        }
        if let message { log.info(message, recordingID: recordingID) }
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return max(0, Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000)
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
