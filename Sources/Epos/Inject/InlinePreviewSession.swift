import Foundation

/// Privacy-safe outcome of one recording's preview attempt: counts and states
/// only, never transcript text.
struct InlinePreviewReport: Equatable, Sendable {
    var bundleIdentifier: String
    var began: Bool
    /// Whether any mark was ever put on the wire. A mark whose reply never came
    /// back leaves `marksSent` at zero yet may be rendered in the field, so this
    /// — not `marksSent` — is what "a composition may be on screen" means.
    var didAttemptMark: Bool
    var marksSent: Int
    var cancelAcknowledged: Bool
    var committed: Bool
    var failure: String?

    var logLine: String {
        "inline preview target=\(bundleIdentifier) began=\(began) " +
            "attemptedMark=\(didAttemptMark) marks=\(marksSent) " +
            "cancelAck=\(cancelAcknowledged) committed=\(committed) failure=\(failure ?? "none")"
    }
}

/// Outcome of the one final `commit` attempt, classified by whether the probe
/// can possibly have executed it.
enum InlinePreviewCommitOutcome: Equatable, Sendable {
    case committed
    /// The live composition or selection no longer belongs to this recording.
    /// A keystroke write could alter somebody else's text and must be refused.
    case targetUnsafe
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

    /// The probe acks issuing an un-mark/discard, not the host app having drawn
    /// it. Any keystrokes that follow wait this long so they never land on a
    /// composition still on screen.
    static let compositionSettleDelay: Duration = .milliseconds(30)

    private let transport: InlinePreviewTransport
    private let bundleIdentifier: String
    private let throttle: Duration
    private let sleep: @Sendable (Duration) async -> Void
    /// Fired on transitions in and out of active marking (begin acked, channel
    /// healthy). The coordinator uses it to drop the HUD's duplicate transcript
    /// line while the field shows the same text.
    private let onMarkingActivityChange: @Sendable (Bool) -> Void
    /// Fired once, when the probe acknowledges rendering the FIRST mark — the
    /// moment provisional text is actually visible in the field. The
    /// coordinator hides the recording pill on it: from here the in-field text
    /// itself shows that dictation is flowing.
    private let onFirstMarkRendered: @Sendable () -> Void

    private var phase: Phase = .pending
    private var pendingMark: String?
    private var lastSentMark: String?
    private var draining = false
    private var safetyReplyInFlight = false
    private var safetyReplyCompletions: [CheckedContinuation<Void, Never>] = []
    /// Woken when the in-flight drain finishes, so the commit handshake can wait
    /// for reply alignment without polling.
    private var drainCompletions: [CheckedContinuation<Void, Never>] = []
    private var began = false
    private var didAttemptMark = false
    private var marksSent = 0
    private var cancelAcknowledged = false
    private var compositionCancelled = false
    private var committed = false
    private var failure: String?
    private var unsafeTarget = false

    init(
        transport: InlinePreviewTransport,
        bundleIdentifier: String,
        throttle: Duration = .milliseconds(100),
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        onMarkingActivityChange: @escaping @Sendable (Bool) -> Void = { _ in },
        onFirstMarkRendered: @escaping @Sendable () -> Void = {}
    ) {
        self.transport = transport
        self.bundleIdentifier = bundleIdentifier
        self.throttle = throttle
        self.sleep = sleep
        self.onMarkingActivityChange = onMarkingActivityChange
        self.onFirstMarkRendered = onFirstMarkRendered
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
            let reply = try await sendSafetyCommand("begin \(bundleIdentifier)")
            let targetUnsafe = recordUnsafeTarget(reply)
            guard phase == .pending else { return await transport.close() }
            if targetUnsafe { return degrade("unsafeTarget") }
            guard reply.hasPrefix("ok") else {
                if !reply.hasPrefix("err") { unsafeTarget = true }
                return degrade("beginRefused")
            }
            began = true
            transition(to: .marking)
            startDrainIfNeeded()
        } catch {
            recordUnknownSafetyFailure(error)
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
        transition(to: .discarded)
        pendingMark = nil
        // Consume a pending begin or mark reply so its safety refusal
        // cannot arrive after the coordinator has authorized a fallback write.
        await awaitSafetyReply()
        let shouldCancel = didAttemptMark && !compositionCancelled
        let shouldEnd = began

        if shouldCancel {
            do {
                let reply = try await transport.send("cancel")
                if recordUnsafeTarget(reply) || !reply.hasPrefix("ok") {
                    unsafeTarget = true
                    failure = "unsafeTarget"
                } else {
                    cancelAcknowledged = true
                    compositionCancelled = true
                }
            } catch {
                unsafeTarget = true
                failure = "unsafeTarget"
            }
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

    /// Sticky across degradation and discard. Preview can stop while the target
    /// remains unsafe for either final delivery backend.
    func hasUnsafeTarget() -> Bool { unsafeTarget }

    /// Step 1 of the final IME commit: drop the composition while keeping the
    /// channel and the probe's focus lock open. The insertion guard must verify
    /// a field that reads exactly as it did at fn press, and live marked text is
    /// part of the AX-readable value, so it has to be gone before the guard runs.
    /// Returns true only on a positive ack. Unconfirmed cleanup blocks both
    /// final backends because a composition may still occupy the field.
    func cancelCompositionForFinalCommit() async -> Bool {
        guard isEligibleForFinalCommit() else { return false }
        transition(to: .committing)
        pendingMark = nil
        // Reply alignment is load-bearing: the transport pairs each request
        // with the next reply line, so an in-flight mark must consume its reply
        // before this cancel — and the commit after it — can trust theirs.
        // `committing` stops new drains; waiting out the current one leaves the
        // stream aligned. A mark that fails in flight degrades and aborts here.
        await awaitDrainCompletion()
        guard phase == .committing else { return false }
        guard !unsafeTarget else {
            degrade("unsafeTarget")
            return false
        }
        do {
            let reply = try await transport.send("cancel")
            if recordUnsafeTarget(reply) {
                degrade("unsafeTarget")
                return false
            }
            guard reply.hasPrefix("ok") else {
                unsafeTarget = true
                degrade("commitCancelRefused")
                return false
            }
            cancelAcknowledged = true
            compositionCancelled = true
            return true
        } catch {
            unsafeTarget = true
            degrade("commitCancelFailed")
            return false
        }
    }

    /// Step 2: sends the authoritative transcript as one `commit`, which the
    /// probe executes as a single atomic `insertText` at the caret.
    func commitFinalTranscript(_ text: String) async -> InlinePreviewCommitOutcome {
        guard !unsafeTarget else { return .targetUnsafe }
        guard phase == .committing, compositionCancelled,
              Self.isCommittableText(text) else {
            return .unavailable
        }
        do {
            let reply = try await transport.send(
                "commit \(text)",
                replyTimeout: Self.commitAckTimeout
            )
            if recordUnsafeTarget(reply) {
                degrade("unsafeTarget")
                return .targetUnsafe
            }
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
        } catch InlinePreviewTransportError.replyPeerClosed {
            // Fully sent, then the probe hung up. It may have inserted the text
            // before dying, so this is ambiguous on exactly the same terms as a
            // missing ack; only the recorded reason differs.
            degrade("commitPeerClosed")
            return .ambiguous
        } catch InlinePreviewTransportError.replyMalformed {
            degrade("commitReplyMalformed")
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
            didAttemptMark: didAttemptMark,
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

    /// Suspends until no drain is in flight. The `draining` check and the
    /// continuation hand-off happen without an intervening suspension point, so a
    /// drain finishing in between cannot be missed.
    private func awaitDrainCompletion() async {
        guard draining else { return }
        await withCheckedContinuation { drainCompletions.append($0) }
    }

    /// Discard waits for a begin or mark reply, without the coalescing interval.
    /// That reply can carry a safety refusal that must precede any final write.
    private func awaitSafetyReply() async {
        guard safetyReplyInFlight else { return }
        await withCheckedContinuation { safetyReplyCompletions.append($0) }
    }

    private func sendSafetyCommand(_ line: String) async throws -> String {
        safetyReplyInFlight = true
        defer {
            safetyReplyInFlight = false
            let waiters = safetyReplyCompletions
            safetyReplyCompletions = []
            for waiter in waiters { waiter.resume() }
        }
        return try await transport.send(line)
    }

    private func finishDraining() {
        draining = false
        let waiters = drainCompletions
        drainCompletions = []
        for waiter in waiters { waiter.resume() }
    }

    /// Sends the newest pending text, then holds the throttle interval open. Marks
    /// arriving during that window replace each other, so a burst of partials costs
    /// one write per interval and always shows the latest text.
    private func drain() async {
        defer { finishDraining() }
        while phase == .marking, let text = pendingMark {
            pendingMark = nil
            didAttemptMark = true
            do {
                let reply = try await sendSafetyCommand("mark \(text)")
                _ = recordUnsafeTarget(reply)
                if reply.hasPrefix("err"), marksSent == 0 {
                    // The first mark was conclusively refused before setMarkedText.
                    // No cancellation should disturb the original selection.
                    compositionCancelled = true
                } else if !reply.hasPrefix("ok") {
                    // A previously accepted mark may have been ended by its host.
                    // Losing the ability to update it also retires final delivery.
                    unsafeTarget = true
                }
                guard phase == .marking else { return }
                if unsafeTarget { return degrade("unsafeTarget") }
                guard reply.hasPrefix("ok") else { return degrade("markRefused") }
                marksSent += 1
                lastSentMark = text
                if marksSent == 1 { onFirstMarkRendered() }
            } catch {
                recordUnknownSafetyFailure(error)
                return degrade("markFailed")
            }
            await sleep(throttle)
        }
    }

    private func degrade(_ reason: String) {
        guard phase != .discarded else { return }
        transition(to: .degraded)
        pendingMark = nil
        failure = reason
    }

    private func recordUnsafeTarget(_ reply: String) -> Bool {
        guard reply.hasPrefix("err unsafe ") else { return false }
        unsafeTarget = true
        return true
    }

    private func recordUnknownSafetyFailure(_ error: Error) {
        switch error as? InlinePreviewTransportError {
        case .replyTimedOut, .replyPeerClosed, .replyMalformed:
            unsafeTarget = true
        default:
            break
        }
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
