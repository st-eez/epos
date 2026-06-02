import Foundation
import FoundationModels

/// The real on-device polish engine: FoundationModels guided generation with the
/// Stage-1 tuned prompt. Greedy / temperature-0 decoding makes decoding
/// deterministic so the leash lives in the instructions, not in sampling luck. Each
/// recording gets one session via `makeSession`, prewarmed at recording start and held
/// (by the policy) until the finish-time polish, so the session is warm by fn-release; a
/// new session per recording keeps transcripts from contaminating each other. Not
/// unit-testable (it needs the on-device model) — the gate/guard/fallback policy lives in
/// `TranscriptPolisher` and is tested with a fake. Ported from a local-only,
/// gitignored probe (not in the committed repo).
public struct FoundationModelsPolishEngine: PolishEngine {
    private let model: SystemLanguageModel
    private let promptStyle: FoundationModelsPolishPromptStyle

    public init() {
        self.init(promptStyle: .production)
    }

    init(promptStyle: FoundationModelsPolishPromptStyle) {
        // Construct the configured model once and gate on ITS availability, so the
        // model checked by `isAvailable` is exactly the one that does the work — a
        // separate `.default` instance could report a different availability.
        model = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
        self.promptStyle = promptStyle
    }

    public var isAvailable: Bool {
        model.availability == .available
    }

    /// Build and prewarm one session for this recording. The coordinator calls this at
    /// recording start and the policy holds the returned session until fn-release, so the
    /// model session is warm by the time the user stops speaking — measured to roughly
    /// halve first-polish latency vs building a fresh session at finish (a prewarmed-then-
    /// discarded session, as the prior design used, carried no measurable benefit).
    public func makeSession(knownTerms: [String]) -> any PolishSession {
        let session = LanguageModelSession(
            model: model,
            instructions: Self.makeInstructions(knownTerms: knownTerms, promptStyle: promptStyle)
        )
        session.prewarm()
        return Session(session)
    }

    /// One recording's prewarmed session. A new instance per recording keeps transcripts
    /// from contaminating each other; that per-recording lifetime — not cooperative
    /// cancellation — is the correctness guarantee if a timed-out polish is still decoding
    /// when the next recording starts. A context-window overflow maps to a distinct error
    /// so the policy reports `.tooLong` rather than a silent raw fallback.
    ///
    /// `@unchecked Sendable`: the session is created at recording start and used by exactly
    /// one `polish` call; there is no concurrent access (one recording at a time, and the
    /// box hands the session to a single task).
    private final class Session: PolishSession, @unchecked Sendable {
        private let session: LanguageModelSession

        init(_ session: LanguageModelSession) {
            self.session = session
        }

        func polish(_ raw: String) async throws -> String {
            do {
                return try await session
                    .respond(to: raw, generating: CleanedTranscript.self, options: FoundationModelsPolishEngine.options)
                    .content
                    .cleaned
            } catch let error as LanguageModelSession.GenerationError {
                if case .exceededContextWindowSize = error { throw PolishInputTooLargeError() }
                throw error
            }
        }
    }

    /// Greedy + temperature 0: deterministic decoding. No `maximumResponseTokens`
    /// cap — a legitimate long dictation needs as many tokens as it has words, and
    /// a truncated output would make the retention guard reject the whole
    /// transcript (a silent no-polish). Runaway composition is bounded instead by
    /// the policy timeout and the retention guard.
    private static let options = GenerationOptions(sampling: .greedy, temperature: 0)
}

/// Guided-generation output shape. `respond(to:generating:)` forces the model to
/// fill this single field instead of producing a free-form chat turn — the
/// structural lever that kills chat preamble, composition, and ``` fences.
@Generable
struct CleanedTranscript {
    @Guide(description: "The transcript with only exact filler tokens removed and capitalization/spacing fixed, every other word kept exactly as the user said it, in the same order and spelling. Do NOT remove false starts, fix mishearings, substitute words, convert spoken words like comma/period/dash/slash into symbols, or add commas, question marks, or exclamation points. Never summarize, shorten, drop content words, add anything, turn a statement into a question, or answer the text.")
    var cleaned: String
}
