import Foundation

/// The model call behind `TranscriptPolisher`, isolated as a protocol so the
/// gate/guard/fallback policy is unit-testable with a fake. The real engine
/// wraps FoundationModels guided generation (added in the live-wiring slice).
public protocol PolishEngine: Sendable {
    /// Whether the on-device model is usable right now.
    var isAvailable: Bool { get }
    /// Build this recording's polish session, warmed for `knownTerms`. Called once at
    /// recording start; the policy holds the returned session across the dictation window
    /// and reuses it for the finish-time polish. Holding a prewarmed session — rather than
    /// prewarming one and building a fresh one at finish — roughly halves first-polish
    /// latency (measured): the model *session*, not just the shared model weights, is warm
    /// by fn-release. A new session per recording keeps transcripts from contaminating
    /// each other.
    func makeSession(knownTerms: [String]) -> any PolishSession
}

/// One recording's warmed polish call. Split out of `PolishEngine` so the engine can
/// prewarm a session at recording start and hand back something the policy holds until
/// finish, without leaking the underlying model-session type through the seam.
public protocol PolishSession: Sendable {
    /// Clean up the raw transcript on the prewarmed session. May throw; the policy treats
    /// a throw as a fallback to the raw text (or `.tooLong` for `PolishInputTooLargeError`).
    func polish(_ raw: String) async throws -> String
}

/// Thrown by the engine when the transcript is too large for the model's context
/// window. Surfaced as the distinct `.tooLong` outcome so an over-long dictation
/// is observably skipped rather than silently indistinguishable from a no-op.
public struct PolishInputTooLargeError: Error, Sendable {}

/// The text to insert plus which decision path produced it, so the caller can
/// log the outcome without re-deriving the policy's gate. `rawCharacterCount`
/// carries `canonicalize(raw).count` — the canonicalized-raw baseline `polish`
/// already computes — so the caller can log it without a third canonicalizer
/// pass over the transcript on the finalize hot path. It equals `text.count` on
/// every path except `.applied`, where `text` is the canonicalized *polished*
/// string while `rawCharacterCount` stays the canonicalized *raw* baseline. The
/// lone exception is the empty/whitespace early return, which carries the
/// uncanonicalized `raw.count` — a path `runSession` never logs.
public struct PolishResult: Sendable, Equatable {
    public let text: String
    public let outcome: PolishOutcome
    public let rawCharacterCount: Int
    public let guardRejection: PolishGuardRejection?

    public init(
        text: String,
        outcome: PolishOutcome,
        rawCharacterCount: Int,
        guardRejection: PolishGuardRejection? = nil
    ) {
        self.text = text
        self.outcome = outcome
        self.rawCharacterCount = rawCharacterCount
        self.guardRejection = guardRejection
    }
}

/// Which path `TranscriptPolisher.polish` took. Every non-`.applied` case keeps
/// the user's raw words, but the reason stays visible for dogfood diagnostics.
public enum PolishOutcome: Sendable, Equatable {
    case disabled
    case unavailable
    case timedOut
    case tooLong
    case sameText
    case guardRejected
    case engineFailed
    case abandoned
    case suppressedByInsertion
    case applied
}

public struct PolishRetentionEvaluation: Sendable, Equatable {
    public let retainsContent: Bool
    public let rejection: PolishGuardRejection?
}

public struct PolishGuardRejection: Sendable, Equatable {
    public let reason: PolishGuardRejectionReason
    public let candidateCharacterCount: Int
    public let diff: String

    public var logDescription: String {
        "reason=\(reason.rawValue) candidateChars=\(candidateCharacterCount) \(diff)"
    }
}

public enum PolishGuardRejectionReason: String, Sendable, Equatable {
    case emptyPolished = "empty-polished"
    case zeroContentRewrite = "zero-content-rewrite"
    case contentTokensChanged = "content-tokens-changed"
    case symbolUsageChanged = "symbol-usage-changed"
    case commaUsageChanged = "comma-usage-changed"
    case sentenceBoundaryChanged = "sentence-boundary-changed"
}

private enum EnginePolishAttempt: Sendable, Equatable {
    case success(String)
    case failed
    case abandoned
    case tooLong
    case timedOut
}

/// Decides whether a polished transcript may replace the raw one, and applies
/// the gate/guard/fallback policy around the engine. The guard
/// (`polishRetainsContent`, in `TranscriptPolisherGuard.swift`) is the defense
/// against the model altering meaning: it keeps the polished text only when the
/// same content-token sequence survives after allowed filler removal (and the
/// hyphen-merge of an already-spoken compound), with no added `,`/`?`/`!` and no
/// collapsed sentence boundary — every other change is rejected. The policy never
/// throws and always falls back to the user's own words on any failure. Both the
/// raw and polished strings are canonicalized before comparison so the retention
/// guarantee holds between exactly the two strings that meet on screen, and so the
/// canonicalizer's deterministic symbol/known-term conversions match on both sides.
public struct TranscriptPolisher: Sendable {
    public static let defaultTimeoutNanoseconds: UInt64 = 2_500_000_000

    private let enabled: Bool
    private let engine: any PolishEngine
    private let knownTerms: [String]
    private let canonicalize: @Sendable (String) -> String
    private let timeoutNanoseconds: UInt64?
    /// Holds the session `prewarm()` warms at recording start so `polish()` at finish can
    /// reuse it across the value-type copy between those two call sites (see the box doc).
    private let preparedSession = PreparedPolishSession()
    /// Lets the coordinator make an in-flight `polish()` give up immediately (return raw)
    /// when a new recording starts during the finalize window. A reference box so the
    /// trigger reaches the running call across the value-type copy, like `preparedSession`.
    private let inFlightAbandon = PolishAbandonHandle()

    public init(
        enabled: Bool,
        engine: any PolishEngine,
        knownTerms: [String] = [],
        canonicalize: @escaping @Sendable (String) -> String = { $0 },
        timeoutNanoseconds: UInt64? = Self.defaultTimeoutNanoseconds
    ) {
        self.enabled = enabled
        self.engine = engine
        self.knownTerms = knownTerms
        self.canonicalize = canonicalize
        self.timeoutNanoseconds = timeoutNanoseconds
    }

    public var willAttemptPolish: Bool {
        enabled && engine.isAvailable
    }

    /// Returns the text to insert plus the path taken: `.applied` with the
    /// canonicalized polished text on the happy path, or the canonicalized raw
    /// text with a specific fallback outcome on every other path. Never throws.
    public func polish(_ raw: String) async -> PolishResult {
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // Unreachable from the log site (`runSession` only polishes when the
            // transcript is non-empty after trimming), so this `rawCharacterCount`
            // is never logged; `raw.count` is a cheap, well-defined placeholder
            // consistent with `text: raw`. Deliberately not canonicalized — running
            // `canonicalize` here would reintroduce the wasted pass this field removes.
            return PolishResult(text: raw, outcome: .sameText, rawCharacterCount: raw.count)
        }
        let canonicalRaw = canonicalize(raw)
        let rawCount = canonicalRaw.count
        guard enabled else { return PolishResult(text: canonicalRaw, outcome: .disabled, rawCharacterCount: rawCount) }
        guard engine.isAvailable else { return PolishResult(text: canonicalRaw, outcome: .unavailable, rawCharacterCount: rawCount) }
        switch await enginePolishAttempt(raw) {
        case .success(let polished):
            let candidate = canonicalize(polished)
            guard candidate != canonicalRaw else {
                return PolishResult(text: canonicalRaw, outcome: .sameText, rawCharacterCount: rawCount)
            }
            let retention = Self.polishRetentionEvaluation(raw: canonicalRaw, polished: candidate)
            guard retention.retainsContent else {
                return PolishResult(
                    text: canonicalRaw,
                    outcome: .guardRejected,
                    rawCharacterCount: rawCount,
                    guardRejection: retention.rejection
                )
            }
            return PolishResult(text: candidate, outcome: .applied, rawCharacterCount: rawCount)
        case .failed:
            return PolishResult(text: canonicalRaw, outcome: .engineFailed, rawCharacterCount: rawCount)
        case .abandoned:
            return PolishResult(text: canonicalRaw, outcome: .abandoned, rawCharacterCount: rawCount)
        case .tooLong:
            return PolishResult(text: canonicalRaw, outcome: .tooLong, rawCharacterCount: rawCount)
        case .timedOut:
            return PolishResult(text: canonicalRaw, outcome: .timedOut, rawCharacterCount: rawCount)
        }
    }

    /// Downgrade a `.applied` outcome when the insertion layer reports that no
    /// keystrokes actually landed (the append-only latch suppressed the retype),
    /// so observability never claims a polish the user didn't receive.
    public static func effectivePolishOutcome(_ result: PolishResult, applied: Bool) -> PolishOutcome {
        (result.outcome == .applied && !applied) ? .suppressedByInsertion : result.outcome
    }

    /// Hint the engine to load the model so the first real polish is faster. A
    /// no-op unless polish is enabled and the engine is available.
    public func prewarm() {
        guard enabled, engine.isAvailable else { return }
        preparedSession.session = engine.makeSession(knownTerms: knownTerms)
    }

    /// Make an in-flight `polish()` give up immediately and return the raw text. A
    /// no-op when no polish is running. The coordinator calls this when a new recording
    /// starts during the finalize window, so the next utterance isn't blocked by the
    /// prior polish (which may still be decoding for up to the timeout).
    public func abandonInFlightPolish() {
        inFlightAbandon.trigger()
    }

    private func enginePolishAttempt(_ raw: String) async -> EnginePolishAttempt {
        // Reuse the session prewarmed at recording start; fall back to a fresh one if
        // polish runs without a prior prewarm (a polisher built at finish). Only reached
        // after polish()'s enabled + isAvailable gates, so `makeSession` is safe to call.
        let session = preparedSession.session ?? engine.makeSession(knownTerms: knownTerms)
        guard let timeoutNanoseconds else {
            do { return .success(try await session.polish(raw)) }
            catch is PolishInputTooLargeError { return .tooLong }
            catch { return .failed }
        }

        // Race three sources — the decode finishing, the deadline, an abandon — and
        // return whichever fires first. The decode runs in an UNSTRUCTURED `Task`
        // (not a task-group child), so this function returns at the deadline (or on
        // abandon) WITHOUT awaiting it: the orphaned decode finishes in the
        // background, and because each recording gets its own session it can't leak
        // into the next recording's transcript. This is required because the
        // on-device `respond()` may not observe cooperative cancellation — a task
        // group would block at scope exit until the decode finished, so the timeout
        // (and the abandon) could not bound the wall-clock return. The `PolishResolver`
        // delivers exactly one of the three outcomes through a one-shot continuation.
        let resolver = PolishResolver()
        let decode = Task {
            let outcome: EnginePolishAttempt
            do { outcome = .success(try await session.polish(raw)) }
            catch is PolishInputTooLargeError { outcome = .tooLong }
            catch { outcome = .failed }
            resolver.resolve(outcome)
        }
        let deadline = Task {
            try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            resolver.resolve(.timedOut)
        }
        // An abandon (a re-press during finalize) gives up promptly with the raw text.
        inFlightAbandon.arm { resolver.resolve(.abandoned) }

        let result = await resolver.value()

        inFlightAbandon.disarm()
        deadline.cancel()
        decode.cancel() // best-effort stop of the orphan; harmless if respond() ignores it
        return result
    }
}

/// Resolves an `EnginePolishAttempt` exactly once, from whichever racing source —
/// decode success, deadline, or abandon — fires first; later resolves are dropped.
/// Routing the result through a one-shot continuation (rather than a task group that
/// would await the orphaned decode at scope exit) is what lets `enginePolishAttempt`
/// return at the deadline or on abandon without waiting for a `respond()` that may
/// ignore cancellation. `@unchecked Sendable`: all state is guarded by `lock`.
private final class PolishResolver: @unchecked Sendable {
    private let lock = NSLock()
    private var settled = false
    private var settledValue: EnginePolishAttempt?
    private var continuation: CheckedContinuation<EnginePolishAttempt, Never>?

    func value() async -> EnginePolishAttempt {
        await withCheckedContinuation { continuation in
            let alreadySettled: EnginePolishAttempt? = lock.withLock {
                if let settledValue { return settledValue }
                self.continuation = continuation
                return nil
            }
            if let alreadySettled { continuation.resume(returning: alreadySettled) }
        }
    }

    func resolve(_ outcome: EnginePolishAttempt) {
        let waiting: CheckedContinuation<EnginePolishAttempt, Never>? = lock.withLock {
            guard !settled else { return nil }
            settled = true
            settledValue = outcome
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(returning: outcome)
    }
}

/// A one-shot abandon trigger armed for the duration of one `polish()` call. `trigger()`
/// (from the main actor, when a new recording starts) runs the armed callback, which
/// resolves the in-flight polish to its raw fallback. If `trigger()` arrives BEFORE the
/// polish arms — the press can land while the recognizer is still draining, before
/// `enginePolishAttempt` runs — the request sticks and the next `arm()` fires it
/// immediately, so an early press still collapses the window. One handle per
/// per-recording polisher, so a stuck request can't leak across recordings.
/// `@unchecked Sendable`: all state is read/written only under `lock`.
final class PolishAbandonHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var onAbandon: (() -> Void)?
    private var triggeredBeforeArm = false

    func arm(_ onAbandon: @escaping () -> Void) {
        let fireImmediately: Bool = lock.withLock {
            if triggeredBeforeArm { return true }
            self.onAbandon = onAbandon
            return false
        }
        if fireImmediately { onAbandon() }
    }

    func disarm() {
        lock.withLock {
            self.onAbandon = nil
            self.triggeredBeforeArm = false
        }
    }

    func trigger() {
        let callback = lock.withLock { () -> (() -> Void)? in
            if let callback = self.onAbandon {
                self.onAbandon = nil
                return callback
            }
            self.triggeredBeforeArm = true
            return nil
        }
        callback?()
    }
}

/// Reference box so the session `prewarm()` warms at recording start is visible to
/// `polish()` at finish: `TranscriptPolisher` is a value type, copied between those call
/// sites, so a plain struct field would not carry the session across the copy. One box per
/// polisher means one session per recording — nothing is shared across recordings, so a
/// timed-out polish still decoding cannot leak into the next recording's transcript.
/// `@unchecked Sendable`: the session is written once on the main actor before the
/// transcription task that later reads it is spawned (a happens-before edge), and is never
/// mutated concurrently.
final class PreparedPolishSession: @unchecked Sendable {
    var session: (any PolishSession)?
}
