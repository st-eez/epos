import Foundation

/// Launch gate for the inline-preview dogfood spike. Read once, at coordinator
/// init: with the variable unset, no preview object is ever built and the
/// recording path does a single nil check.
enum InlinePreviewPolicy {
    static let environmentKey = "EPOS_INLINE_PREVIEW"

    static func load(
        from environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment[environmentKey] == "1"
    }
}

/// Privacy-safe outcome of one recording's preview attempt: counts and states
/// only, never transcript text.
struct InlinePreviewReport: Equatable, Sendable {
    var bundleIdentifier: String
    var began: Bool
    var marksSent: Int
    var cancelAcknowledged: Bool
    var committed: Bool
    var failure: String?

    var logLine: String {
        "inline preview target=\(bundleIdentifier) began=\(began) marks=\(marksSent) " +
            "cancelAck=\(cancelAcknowledged) committed=\(committed) failure=\(failure ?? "none")"
    }
}

/// Outcome of the one final `commit` attempt, classified by whether the probe
/// can possibly have executed it.
enum InlinePreviewCommitOutcome: Equatable, Sendable {
    case committed
    /// The probe provably did not execute the commit (refusal replies precede
    /// `insertText`; a send-side failure means the command line never arrived
    /// complete). Keystroke fallback is safe.
    case refused
    /// Not attempted at all (channel degraded first). Keystroke fallback is safe.
    case unavailable
    /// The commit was fully sent over a healthy channel and no acknowledgment
    /// arrived. It may have executed — nothing else may write this recording.
    case ambiguous
}

/// Mirrors the volatile transcript into the fn-press application as input-method
/// marked text, for one recording.
///
/// Marked text is preview only; the composition is always dropped before any
/// write. The one exception to "never commit" is the explicit final handshake
/// (`cancelCompositionForFinalCommit` + `commitFinalTranscript`), which
/// `FinalTranscriptCommitRouter` drives only after the shared insertion guard
/// authorized the write — and which itself starts by dropping the composition.
/// On the ordinary path `discard()` drops the composition and releases the
/// probe's focus lock, and the coordinator awaits it before the authoritative
/// guarded keystroke write, so preview and write can never both land.
///
/// Every failure — probe absent, focus lock refused, timeout — degrades to
/// HUD-only for the rest of the recording instead of propagating.
actor InlinePreviewSession {
    private enum Phase {
        /// `begin` has not resolved yet; marks accumulate but are not sent.
        case pending
        case marking
        /// The final-commit handshake has started; no further marks are sent.
        case committing
        case degraded
        case discarded
    }

    /// Bounded ack window for the one `commit`. Wider than the transport's
    /// default budget because a missing ack here is the worst outcome (an
    /// ambiguous write), while a slow ack only delays finalization.
    static let commitAckTimeout: TimeInterval = 0.5

    private let transport: InlinePreviewTransport
    private let bundleIdentifier: String
    private let throttle: Duration
    private let sleep: @Sendable (Duration) async -> Void
    /// Fired on transitions in and out of active marking (begin acked, channel
    /// healthy). The coordinator uses it to drop the HUD's duplicate transcript
    /// line while the field shows the same text.
    private let onMarkingActivityChange: @Sendable (Bool) -> Void
    /// When set, fired with the caret-line rectangle at the composition END
    /// (nil when unavailable): once after the first acknowledged mark, then
    /// refreshed at most every `caretRectRefreshInterval` — always riding along
    /// after a mark ack, never on its own timer, so a silent pause also pauses
    /// the queries. Each query is one bounded round-trip.
    private let onCaretRect: (@Sendable (CGRect?) -> Void)?
    /// Injectable clock for the refresh gate, so tests can pin the cadence.
    private let now: @Sendable () -> TimeInterval

    /// Minimum spacing between caret-rect refreshes while text keeps growing.
    static let caretRectRefreshInterval: TimeInterval = 0.4

    private var phase: Phase = .pending
    private var lastCaretRectQueryTime: TimeInterval?
    private var pendingMark: String?
    private var lastSentMark: String?
    private var draining = false
    private var began = false
    private var didAttemptMark = false
    private var marksSent = 0
    private var cancelAcknowledged = false
    private var compositionCancelled = false
    private var committed = false
    private var failure: String?

    init(
        transport: InlinePreviewTransport,
        bundleIdentifier: String,
        throttle: Duration = .milliseconds(100),
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        onMarkingActivityChange: @escaping @Sendable (Bool) -> Void = { _ in },
        onCaretRect: (@Sendable (CGRect?) -> Void)? = nil,
        now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }
    ) {
        self.transport = transport
        self.bundleIdentifier = bundleIdentifier
        self.throttle = throttle
        self.sleep = sleep
        self.onMarkingActivityChange = onMarkingActivityChange
        self.onCaretRect = onCaretRect
        self.now = now
    }

    /// Text the line protocol can carry verbatim. A transcript that would need
    /// sanitizing must never be IME-committed: the probe would insert something
    /// other than the authoritative transcript.
    static func isCommittableText(_ text: String) -> Bool {
        !text.isEmpty && !text.contains("\n") && !text.contains("\r")
    }

    /// Connects and pins the probe to the fn-press application. The probe resolves
    /// its client session by bundle id because input-method activation order is not
    /// a reliable proxy for the focused field.
    func begin() async {
        guard phase == .pending else { return }
        do {
            try await transport.open()
            guard phase == .pending else { return await transport.close() }
            let reply = try await transport.send("begin \(bundleIdentifier)")
            guard phase == .pending else { return await transport.close() }
            guard reply.hasPrefix("ok") else {
                return degrade("beginRefused")
            }
            began = true
            transition(to: .marking)
            startDrainIfNeeded()
        } catch {
            degrade("connectFailed")
        }
    }

    /// Records the latest volatile display text. Sending is coalesced: only the
    /// newest text is ever transmitted, at most once per throttle interval.
    func mark(_ text: String) {
        guard phase == .pending || phase == .marking else { return }
        // A newline would split the probe's line protocol into a bogus command.
        let sanitized = text
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        guard !sanitized.isEmpty else { return }
        guard sanitized != lastSentMark || pendingMark != nil else { return }
        pendingMark = sanitized
        startDrainIfNeeded()
    }

    /// Drops the preview and releases the probe's focus lock. Idempotent, and safe
    /// to call after a degradation: if any mark was ever put on the wire, `cancel`
    /// is still sent, because the composition may be on screen even when the reply
    /// never came back.
    func discard() async {
        guard phase != .discarded else { return }
        // After an acked composition cancel there is nothing left to un-mark,
        // so the final-commit paths (committed, refused, ambiguous) never send
        // a second `cancel`. `end` only releases the probe's focus lock and can
        // never touch text, so it is safe even after an ambiguous commit.
        let shouldCancel = didAttemptMark && !compositionCancelled
        let shouldEnd = began
        transition(to: .discarded)
        pendingMark = nil

        if shouldCancel, let reply = try? await transport.send("cancel") {
            cancelAcknowledged = reply.hasPrefix("ok")
        }
        if shouldEnd {
            _ = try? await transport.send("end")
        }
        await transport.close()
    }

    // MARK: - Final IME commit

    /// True only when the channel has been healthy for the whole recording:
    /// begin acked, every send round-tripped (any failure is a sticky degrade),
    /// and the probe acknowledged rendering at least one mark.
    func isEligibleForFinalCommit() -> Bool {
        phase == .marking && marksSent > 0
    }

    /// Step 1 of the final IME commit: drop the composition while keeping the
    /// channel and the probe's focus lock open. The insertion guard must verify
    /// a field that reads exactly as it did at fn press, and live marked text is
    /// part of the AX-readable value, so it has to be gone before the guard runs.
    /// Returns true only on a positive ack; anything else degrades, and the
    /// caller falls back to the ordinary discard + keystroke path.
    func cancelCompositionForFinalCommit() async -> Bool {
        guard isEligibleForFinalCommit() else { return false }
        transition(to: .committing)
        pendingMark = nil
        // Reply alignment is load-bearing: the transport pairs each request
        // with the next reply line, so an in-flight mark must consume its reply
        // before this cancel — and the commit after it — can trust theirs.
        // `committing` stops new drains; waiting out the current one leaves the
        // stream aligned. A mark that fails in flight degrades and aborts here.
        // (Real sleep, not the injected throttle sleep: this wait is part of the
        // commit handshake, not the mark cadence.)
        while draining { try? await Task.sleep(for: .milliseconds(2)) }
        guard phase == .committing else { return false }
        do {
            let reply = try await transport.send("cancel")
            guard reply.hasPrefix("ok") else {
                degrade("commitCancelRefused")
                return false
            }
            cancelAcknowledged = true
            compositionCancelled = true
            return true
        } catch {
            degrade("commitCancelFailed")
            return false
        }
    }

    /// Step 2: sends the authoritative transcript as one `commit`, which the
    /// probe executes as a single atomic `insertText` at the caret.
    func commitFinalTranscript(_ text: String) async -> InlinePreviewCommitOutcome {
        guard phase == .committing, compositionCancelled,
              Self.isCommittableText(text) else {
            return .unavailable
        }
        do {
            let reply = try await transport.send(
                "commit \(text)",
                replyTimeout: Self.commitAckTimeout
            )
            if reply.hasPrefix("ok committed") {
                committed = true
                return .committed
            }
            if reply.hasPrefix("err") {
                // The probe replies `err` only from paths that precede
                // `insertText`, so a refusal proves the commit did not land.
                degrade("commitRefused")
                return .refused
            }
            // Any other reply means the request/reply pairing can no longer be
            // trusted; the commit may still execute.
            degrade("commitReplyUnexpected")
            return .ambiguous
        } catch InlinePreviewTransportError.replyTimedOut {
            // Fully sent, no ack: the probe may have executed it. The caller
            // must not fall back to keystrokes — the transcript could land twice.
            degrade("commitAckTimeout")
            return .ambiguous
        } catch {
            // Send-side failure: the newline terminator never reached the
            // probe, so the commit line was never parsed, let alone executed.
            degrade("commitSendFailed")
            return .refused
        }
    }

    func report() -> InlinePreviewReport {
        InlinePreviewReport(
            bundleIdentifier: bundleIdentifier,
            began: began,
            marksSent: marksSent,
            cancelAcknowledged: cancelAcknowledged,
            committed: committed,
            failure: failure
        )
    }

    private func startDrainIfNeeded() {
        guard phase == .marking, !draining, pendingMark != nil else { return }
        draining = true
        Task { await self.drain() }
    }

    /// Sends the newest pending text, then holds the throttle interval open. Marks
    /// arriving during that window replace each other, so a burst of partials costs
    /// one write per interval and always shows the latest text.
    private func drain() async {
        defer { draining = false }
        while phase == .marking, let text = pendingMark {
            pendingMark = nil
            didAttemptMark = true
            do {
                let reply = try await transport.send("mark \(text)")
                guard phase == .marking else { return }
                guard reply.hasPrefix("ok") else { return degrade("markRefused") }
                marksSent += 1
                lastSentMark = text
                await queryCaretRectIfDue()
            } catch {
                return degrade("markFailed")
            }
            await sleep(throttle)
        }
    }

    /// Bounded caret-rect query after a mark ack, gated to at most one per
    /// `caretRectRefreshInterval`. Any failure reports nil and never degrades
    /// the channel: the rect only anchors the HUD, it is no part of the
    /// preview/commit contract.
    private func queryCaretRectIfDue() async {
        guard let onCaretRect else { return }
        let time = now()
        if let lastCaretRectQueryTime,
           time - lastCaretRectQueryTime < Self.caretRectRefreshInterval {
            return
        }
        lastCaretRectQueryTime = time
        let reply = try? await transport.send("rect")
        onCaretRect(reply.flatMap(Self.parseCaretRect))
    }

    /// Reply format: "ok rect <x> <y> <width> <height>", Cocoa screen
    /// coordinates (verified against TextEdit; see the anchor policy).
    nonisolated static func parseCaretRect(_ reply: String) -> CGRect? {
        let parts = reply.split(separator: " ")
        guard parts.count == 6, parts[0] == "ok", parts[1] == "rect",
              let x = Double(parts[2]), let y = Double(parts[3]),
              let width = Double(parts[4]), let height = Double(parts[5]) else {
            return nil
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func degrade(_ reason: String) {
        guard phase != .discarded else { return }
        transition(to: .degraded)
        pendingMark = nil
        failure = reason
    }

    private func transition(to newPhase: Phase) {
        let wasMarking = phase == .marking
        phase = newPhase
        if wasMarking, newPhase != .marking {
            onMarkingActivityChange(false)
        } else if !wasMarking, newPhase == .marking {
            onMarkingActivityChange(true)
        }
    }
}
