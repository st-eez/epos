import Foundation

/// The model call behind `TranscriptPolisher`, isolated as a protocol so the
/// gate/guard/fallback policy is unit-testable with a fake. The real engine
/// wraps FoundationModels guided generation (added in the live-wiring slice).
public protocol PolishEngine: Sendable {
    /// Whether the on-device model is usable right now.
    var isAvailable: Bool { get }
    /// Hint the model to load so the first real polish is faster.
    func prewarm()
    /// Clean up the raw transcript. May throw; the policy treats any throw as a
    /// fallback to the raw text.
    func polish(_ raw: String) async throws -> String
}

/// Decides whether a polished transcript may replace the raw one, and applies
/// the gate/guard/fallback policy around the engine. The guard is the defense
/// against the model over-compressing a multi-clause command into a fragment:
/// it compares the *significant* (non-filler) words of both and keeps the
/// polished text only when enough of the raw's content survives. The policy
/// never throws and always falls back to the user's own words on any failure.
public struct TranscriptPolisher: Sendable {
    private let enabled: Bool
    private let engine: any PolishEngine

    public init(enabled: Bool, engine: any PolishEngine) {
        self.enabled = enabled
        self.engine = engine
    }

    /// Returns polished text on the happy path, or the raw text on any
    /// disabled/unavailable/throw/guard-fail path. Never throws.
    public func polish(_ raw: String) async -> String {
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return raw }
        guard enabled, engine.isAvailable else { return raw }
        do {
            let polished = try await engine.polish(raw)
            return Self.polishRetainsContent(raw: raw, polished: polished) ? polished : raw
        } catch {
            return raw
        }
    }

    // MARK: - Content-retention guard

    /// Minimum fraction of the raw's significant tokens that must survive in the
    /// polished output for it to be accepted. Errs toward keeping raw, which is
    /// safe because the fallback is the user's own words.
    static let minRetention = 0.6

    /// Tokens shorter than this are treated as noise and ignored when measuring
    /// retention (articles, pronouns, spoken-symbol fragments).
    static let minTokenLength = 3

    /// Filler words dropped before measuring retention. Spec list:
    /// um, uh, er, hmm, so, like, you know, i mean, sort of — multi-word phrases
    /// flattened to their component words, since retention is measured per word.
    static let fillerWords: Set<String> = [
        "um", "uh", "er", "hmm", "so", "like",
        "you", "know", "i", "mean", "sort", "of",
    ]

    /// True when the polished text retains enough of the raw's significant words.
    /// False when polished is empty/whitespace or drops too many content words.
    public static func polishRetainsContent(raw: String, polished: String) -> Bool {
        guard !polished.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }

        let rawTokens = significantTokens(raw)
        // No significant words to lose (raw was all filler/short): nothing to guard.
        guard !rawTokens.isEmpty else { return true }

        let retained = rawTokens.intersection(significantTokens(polished)).count
        return Double(retained) / Double(rawTokens.count) >= minRetention
    }

    private static func significantTokens(_ text: String) -> Set<String> {
        Set(
            text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= minTokenLength && !fillerWords.contains($0) }
        )
    }
}
