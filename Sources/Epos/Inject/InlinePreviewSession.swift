import Foundation

/// Privacy-safe outcome of one recording's preview attempt: counts and states
/// only, never transcript text.
struct InlinePreviewReport: Equatable, Sendable {
    var bundleIdentifier: String
    var began: Bool
    /// Whether any mark was ever put on the wire, including refused commands.
    var didAttemptMark: Bool
    /// Unknown replies may have rendered a mark; a conclusive first refusal cannot.
    var mayHaveRendered: Bool
    var marksSent: Int
    var cancelAcknowledged: Bool
    var committed: Bool
    var commitMayHaveExecuted: Bool
    var failure: String?
    var acquisitionDetail: String? = nil

    var logLine: String {
        "inline preview target=\(bundleIdentifier) began=\(began) " +
            "attemptedMark=\(didAttemptMark) mayHaveRendered=\(mayHaveRendered) marks=\(marksSent) " +
            "cancelAck=\(cancelAcknowledged) committed=\(committed) failure=\(failure ?? "none") " +
            "acquisition=\(acquisitionDetail ?? "none")"
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
/// The healthy final path commits its owned composition in place. Unavailable
/// preview paths discard it before the guarded keystroke fallback. Unknown
/// commit outcomes suppress both a second write and further composition edits.
actor InlinePreviewSession {
    private enum Phase {
        /// `begin` has not resolved yet; marks accumulate but are not sent.
        case pending
        case marking
        /// The final-commit handshake has started; no further marks are sent.
        case committing
        case sealing
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
    private let acquisitionArgument: String?
    private let throttle: Duration
    private let sleep: @Sendable (Duration) async -> Void
    private let validateTarget: @MainActor @Sendable () -> Bool
    private let onAcquisitionFailure: @MainActor @Sendable () -> Void
    /// Fired on transitions in and out of active marking (begin acked, channel
    /// healthy). The coordinator uses it to drop the HUD's duplicate transcript
    /// line while the field shows the same text.
    private let onMarkingActivityChange: @Sendable (Bool) -> Void
    /// Fired once, when the probe acknowledges rendering the FIRST mark — the
    /// moment provisional text is actually visible in the field. The
    /// coordinator hides the recording pill on it: from here the in-field text
    /// itself shows that dictation is flowing.
    private let onFirstMarkRendered: @Sendable () -> Void
    private let onCaretChange: @Sendable (CGRect?) -> Void

    private var phase: Phase = .pending
    private var pendingMark: String?
    private var lastSentMark: String?
    private var draining = false
    private var safetyReplyInFlight = false
    private var safetyReplyCompletions: [CheckedContinuation<Void, Never>] = []
    /// Woken when the current coalescing drain finishes.
    private var drainCompletions: [CheckedContinuation<Void, Never>] = []
    private var began = false
    private var didAttemptMark = false
    private var firstMarkRefused = false
    private var marksSent = 0
    private var cancelAcknowledged = false
    private var compositionCancelled = false
    private var committed = false
    private var committedPrefix = ""
    private var phraseCommitAmbiguous = false
    private var commitMayHaveExecuted = false
    private var failure: String?
    private var acquisitionDetail: String?
    private var unsafeTarget = false

    init(
        transport: InlinePreviewTransport,
        bundleIdentifier: String,
        acquisitionArgument: String? = nil,
        throttle: Duration = .milliseconds(100),
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        validateTarget: @escaping @MainActor @Sendable () -> Bool = { true },
        onAcquisitionFailure: @escaping @MainActor @Sendable () -> Void = {},
        onMarkingActivityChange: @escaping @Sendable (Bool) -> Void = { _ in },
        onFirstMarkRendered: @escaping @Sendable () -> Void = {},
        onCaretChange: @escaping @Sendable (CGRect?) -> Void = { _ in }
    ) {
        self.transport = transport
        self.bundleIdentifier = bundleIdentifier
        self.acquisitionArgument = acquisitionArgument
        self.throttle = throttle
        self.sleep = sleep
        self.validateTarget = validateTarget
        self.onAcquisitionFailure = onAcquisitionFailure
        self.onMarkingActivityChange = onMarkingActivityChange
        self.onFirstMarkRendered = onFirstMarkRendered
        self.onCaretChange = onCaretChange
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
            var openAttempts = 0
            while true {
                openAttempts += 1
                acquisitionDetail = "openAttempts=\(openAttempts)"
                do {
                    try await transport.open()
                    break
                } catch InlinePreviewTransportError.unavailable where openAttempts < 11 {
                    await sleep(.milliseconds(30))
                    guard phase == .pending else { return await transport.close() }
                }
            }
            guard phase == .pending else { return await transport.close() }
            let command = "begin \(bundleIdentifier)" + (acquisitionArgument.map { " \($0)" } ?? "")
            var reply = try await sendSafetyCommand(command)
            // Native source selection and controller activation are separate
            // events. Wait only for this explicit, no-write activation reply.
            let deadline = ContinuousClock.now + .milliseconds(200)
            while acquisitionArgument != nil, reply == "err input method activation pending",
                  phase == .pending, ContinuousClock.now < deadline {
                await sleep(.milliseconds(5))
                guard phase == .pending else { return await transport.close() }
                reply = try await sendSafetyCommand(command)
            }
            acquisitionDetail = "\(acquisitionDetail ?? "") reply=\(reply)"
            let targetUnsafe = recordUnsafeTarget(reply)
            guard phase == .pending else { return await transport.close() }
            if targetUnsafe { return await failAcquisition("unsafeTarget") }
            guard reply.hasPrefix("ok") else {
                if !reply.hasPrefix("err") { unsafeTarget = true }
                return await failAcquisition("beginRefused")
            }
            began = true
            let targetIsUnchanged = await validateTarget()
            guard phase == .pending else { return await transport.close() }
            guard targetIsUnchanged else {
                unsafeTarget = true
                return await failAcquisition("unsafeTarget")
            }
            transition(to: .marking)
            onCaretChange(Self.caret(from: reply))
            startDrainIfNeeded()
        } catch {
            acquisitionDetail = "\(acquisitionDetail ?? "open") error=\(String(describing: error))"
            recordUnknownSafetyFailure(error)
            await failAcquisition("connectFailed")
        }
    }

    /// No draft has been sent during acquisition, so retiring its connection is
    /// sufficient before restoring the borrowed keyboard source.
    private func failAcquisition(_ reason: String) async {
        degrade(reason)
        if began { _ = try? await transport.send("end") }
        await transport.close()
        await onAcquisitionFailure()
    }

    /// Records the latest volatile display text. Sending is coalesced: only the
    /// newest text is ever transmitted, at most once per throttle interval.
    func mark(_ text: String) {
        guard phase == .pending || phase == .marking else { return }
        // A newline would split the probe's line protocol into a bogus command.
        guard text.hasPrefix(committedPrefix) else { return }
        let sanitized = String(text.dropFirst(committedPrefix.count))
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        // Matching the update already sent or awaiting its reply makes any
        // queued revision obsolete.
        pendingMark = sanitized == lastSentMark ? nil : sanitized
        startDrainIfNeeded()
    }

    /// Drops the preview and releases the probe's focus lock. Idempotent, and safe
    /// to call after a degradation: if any mark was ever put on the wire, `cancel`
    /// is still sent, because the composition may be on screen even when the reply
    /// never came back.
    func discard() async {
        guard phase != .discarded else { return }
        // A native commit may already have consumed the draft. Never cancel it
        // after a committed or ambiguous result. A conclusive refusal still
        // needs owned cleanup before the fallback can write.
        transition(to: .discarded)
        pendingMark = nil
        // Consume a pending begin, mark, or preview-clear reply so its safety refusal
        // cannot arrive after the coordinator has authorized a fallback write.
        await awaitSafetyReply()
        let shouldCancel = didAttemptMark && !compositionCancelled && !commitMayHaveExecuted
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

    func isEligibleForFinalCommit() -> Bool {
        phase == .marking && (marksSent > 0 || !committedPrefix.isEmpty)
    }

    /// Sticky across degradation and discard. Preview can stop while the target
    /// remains unsafe for either final delivery backend.
    func hasUnsafeTarget() -> Bool { unsafeTarget }

    /// Stops new marks and waits only for the pending native reply. Keep the
    /// acknowledged composition visible while the target guard authorizes it.
    func prepareFinalCommit() async -> Bool {
        guard isEligibleForFinalCommit() else { return false }
        transition(to: .committing)
        pendingMark = nil
        await awaitSafetyReply()
        guard phase == .committing, !unsafeTarget, (!compositionCancelled || !committedPrefix.isEmpty),
              !committedPrefix.isEmpty || lastSentMark?.isEmpty == false else { return false }
        return true
    }

    func commitFinalTranscript(_ text: String) async -> InlinePreviewCommitOutcome {
        guard !phraseCommitAmbiguous else { return .ambiguous }
        guard !unsafeTarget else { return .targetUnsafe }
        guard phase == .committing, !committed, !commitMayHaveExecuted else { return .unavailable }
        guard text.hasPrefix(committedPrefix) else { return .targetUnsafe }
        let remainder = String(text.dropFirst(committedPrefix.count))
        if remainder.isEmpty, !committedPrefix.isEmpty {
            await clearPreviewComposition()
            guard !unsafeTarget else { return .targetUnsafe }
            committed = true
            return .committed
        }
        if !committedPrefix.isEmpty { compositionCancelled = false }
        return await sendCommit(remainder, continuing: false)
    }

    func commitPhrase(_ text: String) async -> InlinePreviewCommitOutcome {
        guard phase == .marking, !unsafeTarget, text.hasPrefix(committedPrefix) else { return .unavailable }
        let remainder = String(text.dropFirst(committedPrefix.count))
        guard Self.isCommittableText(remainder) else { return .unavailable }
        transition(to: .sealing)
        pendingMark = nil
        await awaitSafetyReply()
        guard phase == .sealing, !unsafeTarget else { return .targetUnsafe }
        compositionCancelled = false
        let outcome = await sendCommit(remainder, continuing: true)
        if outcome == .committed {
            committedPrefix = text
            commitMayHaveExecuted = false
            committed = false
            lastSentMark = nil
            compositionCancelled = true
            if phase == .sealing { transition(to: .marking) }
        } else if outcome == .ambiguous {
            phraseCommitAmbiguous = true
        }
        return outcome
    }

    func hasCommittedPrefix() -> Bool { !committedPrefix.isEmpty }
    func hasAmbiguousPhraseCommit() -> Bool { phraseCommitAmbiguous }

    private func sendCommit(_ text: String, continuing: Bool) async -> InlinePreviewCommitOutcome {
        guard (phase == .committing || phase == .sealing), !compositionCancelled, !commitMayHaveExecuted,
              !text.isEmpty else {
            return .unavailable
        }
        let command: String
        if Self.isCommittableText(text) {
            command = "\(continuing ? "seal" : "commit") \(text)"
        } else if !continuing, !committedPrefix.isEmpty {
            command = "commit64 " + Data(text.utf8).base64EncodedString()
        } else { return .unavailable }
        commitMayHaveExecuted = true
        do {
            let reply = try await sendSafetyCommand(
                command,
                replyTimeout: Self.commitAckTimeout
            )
            if recordUnsafeTarget(reply) {
                commitMayHaveExecuted = false
                degrade("unsafeTarget")
                return .targetUnsafe
            }
            if reply.hasPrefix("ok committed") {
                committed = true
                commitMayHaveExecuted = true
                return .committed
            }
            if reply.hasPrefix("err") {
                commitMayHaveExecuted = false
                // The probe replies `err` only from paths that precede
                // `insertText`, so a refusal proves the commit did not land.
                degrade("commitRefused")
                return .refused
            }
            // Any other reply means the request/reply pairing can no longer be
            // trusted; the commit may still execute.
            degrade("commitReplyUnexpected")
            commitMayHaveExecuted = true
            return .ambiguous
        } catch InlinePreviewTransportError.replyTimedOut {
            // Fully sent, no ack: the probe may have executed it. The caller
            // must not fall back to keystrokes — the transcript could land twice.
            degrade("commitAckTimeout")
            commitMayHaveExecuted = true
            return .ambiguous
        } catch InlinePreviewTransportError.replyPeerClosed {
            // Fully sent, then the probe hung up. It may have inserted the text
            // before dying, so this is ambiguous on exactly the same terms as a
            // missing ack; only the recorded reason differs.
            degrade("commitPeerClosed")
            commitMayHaveExecuted = true
            return .ambiguous
        } catch InlinePreviewTransportError.replyMalformed {
            degrade("commitReplyMalformed")
            commitMayHaveExecuted = true
            return .ambiguous
        } catch {
            // Send-side failure: the newline terminator never reached the
            // probe, so the commit line was never parsed, let alone executed.
            commitMayHaveExecuted = false
            degrade("commitSendFailed")
            return .refused
        }
    }

    func report() -> InlinePreviewReport {
        InlinePreviewReport(
            bundleIdentifier: bundleIdentifier,
            began: began,
            didAttemptMark: didAttemptMark,
            mayHaveRendered: didAttemptMark && !firstMarkRefused,
            marksSent: marksSent,
            cancelAcknowledged: cancelAcknowledged,
            committed: committed,
            commitMayHaveExecuted: commitMayHaveExecuted || !committedPrefix.isEmpty,
            failure: failure,
            acquisitionDetail: acquisitionDetail
        )
    }

    static func caret(from reply: String) -> CGRect? {
        guard let token = reply.split(separator: " ").last, token.hasPrefix("caret=") else { return nil }
        let fields = token.dropFirst(6).split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count == 4 else { return nil }
        let values = fields.compactMap { Double($0) }
        guard values.count == 4, values.allSatisfy(\.isFinite) else { return nil }
        let rect = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
        return RecordingIndicatorPlacementPolicy.isUsableCaret(rect) ? rect : nil
    }

    private func startDrainIfNeeded() {
        guard phase == .marking, !draining, pendingMark != nil else { return }
        draining = true
        Task { await self.drain() }
    }

    /// Suspends until no drain is in flight. The `draining` check and the
    /// continuation hand-off happen without an intervening suspension point, so a
    /// drain finishing in between cannot be missed.
    func awaitDrainCompletion() async {
        guard draining else { return }
        await withCheckedContinuation { drainCompletions.append($0) }
    }

    /// Discard waits for a begin, mark, or clear reply, without the coalescing interval.
    /// That reply can carry a safety refusal that must precede any final write.
    private func awaitSafetyReply() async {
        guard safetyReplyInFlight else { return }
        await withCheckedContinuation { safetyReplyCompletions.append($0) }
    }

    private func sendSafetyCommand(_ line: String, replyTimeout: TimeInterval? = nil) async throws -> String {
        safetyReplyInFlight = true
        defer {
            safetyReplyInFlight = false
            let waiters = safetyReplyCompletions
            safetyReplyCompletions = []
            for waiter in waiters { waiter.resume() }
        }
        if let replyTimeout { return try await transport.send(line, replyTimeout: replyTimeout) }
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
            // Deduplicate against the in-flight state too. A newer revision
            // must replace this update while its reply is pending.
            lastSentMark = text
            if text.isEmpty {
                await clearPreviewComposition()
                guard phase == .marking else { return }
                await sleep(throttle)
                continue
            }
            didAttemptMark = true
            compositionCancelled = false
            cancelAcknowledged = false
            do {
                let reply = try await sendSafetyCommand("mark \(text)")
                _ = recordUnsafeTarget(reply)
                let refusedBeforeMark = reply.hasPrefix("err unmarked ") || reply.hasPrefix("err unsafe unmarked ")
                if refusedBeforeMark, marksSent == 0 {
                    // Only explicit pre-write proof can skip owned cleanup.
                    // Other errors may follow a native mark that rendered.
                    firstMarkRefused = true
                    compositionCancelled = true
                } else if !reply.hasPrefix("ok") {
                    // Without pre-write proof, even the first error may follow
                    // a native mark. Retire final delivery and attempt owned cleanup.
                    unsafeTarget = true
                }
                guard phase == .marking else { return }
                if unsafeTarget { return degrade("unsafeTarget") }
                guard reply.hasPrefix("ok") else { return degrade("markRefused") }
                onCaretChange(Self.caret(from: reply))
                marksSent += 1
                if marksSent == 1 { onFirstMarkRendered() }
            } catch {
                recordUnknownSafetyFailure(error)
                return degrade("markFailed")
            }
            await sleep(throttle)
        }
    }

    /// Empty display text retires the owned composition while retaining the pass.
    /// Sending `mark ` would leave the companion with a zero-length ownership record.
    private func clearPreviewComposition() async {
        guard didAttemptMark, !compositionCancelled else { return }
        do {
            let reply = try await sendSafetyCommand("cancel")
            if recordUnsafeTarget(reply) || !reply.hasPrefix("ok") {
                unsafeTarget = true
                return degrade("previewCancelRefused")
            }
            cancelAcknowledged = true
            compositionCancelled = true
            onCaretChange(nil)
        } catch {
            unsafeTarget = true
            degrade("previewCancelFailed")
        }
    }

    private func degrade(_ reason: String) {
        guard phase != .discarded else { return }
        onCaretChange(nil)
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
        let wasActive = phase == .marking || phase == .sealing
        phase = newPhase
        let isActive = phase == .marking || phase == .sealing
        if wasActive != isActive { onMarkingActivityChange(isActive) }
    }
}
