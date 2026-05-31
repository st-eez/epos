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
/// log the outcome without re-deriving the policy's gate.
public struct PolishResult: Sendable, Equatable {
    public let text: String
    public let outcome: PolishOutcome
}

/// Which path `TranscriptPolisher.polish` took. `unchanged` covers a model no-op,
/// a guard rejection, and an engine throw — all keep the user's raw words.
public enum PolishOutcome: Sendable, Equatable {
    case disabled
    case unavailable
    case timedOut
    case tooLong
    case unchanged
    case applied
}

private enum EnginePolishAttempt: Sendable, Equatable {
    case success(String)
    case failed
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
    /// text with `.disabled`/`.unavailable`/`.timedOut`/`.tooLong`/`.unchanged`
    /// (no-op, throw, or guard-fail) on every other path. Never throws.
    public func polish(_ raw: String) async -> PolishResult {
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return PolishResult(text: raw, outcome: .unchanged)
        }
        let canonicalRaw = canonicalize(raw)
        guard enabled else { return PolishResult(text: canonicalRaw, outcome: .disabled) }
        guard engine.isAvailable else { return PolishResult(text: canonicalRaw, outcome: .unavailable) }
        switch await enginePolishAttempt(raw) {
        case .success(let polished):
            let candidate = canonicalize(polished)
            guard candidate != canonicalRaw,
                  Self.polishRetainsContent(raw: canonicalRaw, polished: candidate) else {
                return PolishResult(text: canonicalRaw, outcome: .unchanged)
            }
            return PolishResult(text: candidate, outcome: .applied)
        case .failed:
            return PolishResult(text: canonicalRaw, outcome: .unchanged)
        case .tooLong:
            return PolishResult(text: canonicalRaw, outcome: .tooLong)
        case .timedOut:
            return PolishResult(text: canonicalRaw, outcome: .timedOut)
        }
    }

    /// Downgrade a `.applied` outcome to `.unchanged` when the insertion layer
    /// reports that no keystrokes actually landed (the append-only latch
    /// suppressed the retype), so observability never claims a polish the user
    /// didn't receive.
    public static func effectivePolishOutcome(_ result: PolishResult, applied: Bool) -> PolishOutcome {
        (result.outcome == .applied && !applied) ? .unchanged : result.outcome
    }

    /// Hint the engine to load the model so the first real polish is faster. A
    /// no-op unless polish is enabled and the engine is available.
    public func prewarm() {
        guard enabled, engine.isAvailable else { return }
        preparedSession.session = engine.makeSession(knownTerms: knownTerms)
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

        // Race the polish against a sleep; whichever finishes first wins and the
        // other is cancelled. A task group makes both cancellations structural —
        // no continuation/onTermination bookkeeping to get wrong — and guarantees
        // the engine child has finished before this returns.
        return await withTaskGroup(of: EnginePolishAttempt.self) { group in
            group.addTask {
                do { return .success(try await session.polish(raw)) }
                catch is PolishInputTooLargeError { return .tooLong }
                catch { return .failed }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                return .timedOut
            }
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            return first
        }
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
