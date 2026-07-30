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
    var failure: String?

    var logLine: String {
        "inline preview target=\(bundleIdentifier) began=\(began) marks=\(marksSent) " +
            "cancelAck=\(cancelAcknowledged) failure=\(failure ?? "none")"
    }
}

/// Mirrors the volatile transcript into the fn-press application as input-method
/// marked text, for one recording.
///
/// Marked text is preview only. This type never sends `commit`: `discard()` drops
/// the composition and releases the probe's focus lock, and the coordinator awaits
/// it before the authoritative guarded write, so the two can never both land.
///
/// Every failure — probe absent, focus lock refused, timeout — degrades to
/// HUD-only for the rest of the recording instead of propagating.
actor InlinePreviewSession {
    private enum Phase {
        /// `begin` has not resolved yet; marks accumulate but are not sent.
        case pending
        case marking
        case degraded
        case discarded
    }

    private let transport: InlinePreviewTransport
    private let bundleIdentifier: String
    private let throttle: Duration
    private let sleep: @Sendable (Duration) async -> Void

    private var phase: Phase = .pending
    private var pendingMark: String?
    private var lastSentMark: String?
    private var draining = false
    private var began = false
    private var didAttemptMark = false
    private var marksSent = 0
    private var cancelAcknowledged = false
    private var failure: String?

    init(
        transport: InlinePreviewTransport,
        bundleIdentifier: String,
        throttle: Duration = .milliseconds(100),
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.transport = transport
        self.bundleIdentifier = bundleIdentifier
        self.throttle = throttle
        self.sleep = sleep
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
            phase = .marking
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
        let shouldCancel = didAttemptMark
        let shouldEnd = began
        phase = .discarded
        pendingMark = nil

        if shouldCancel, let reply = try? await transport.send("cancel") {
            cancelAcknowledged = reply.hasPrefix("ok")
        }
        if shouldEnd {
            _ = try? await transport.send("end")
        }
        await transport.close()
    }

    func report() -> InlinePreviewReport {
        InlinePreviewReport(
            bundleIdentifier: bundleIdentifier,
            began: began,
            marksSent: marksSent,
            cancelAcknowledged: cancelAcknowledged,
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
            } catch {
                return degrade("markFailed")
            }
            await sleep(throttle)
        }
    }

    private func degrade(_ reason: String) {
        guard phase != .discarded else { return }
        phase = .degraded
        pendingMark = nil
        failure = reason
    }
}
