import Foundation

/// The model call behind `TranscriptPolisher`, isolated as a protocol so the
/// gate/guard/fallback policy is unit-testable with a fake. The real engine
/// wraps FoundationModels guided generation (added in the live-wiring slice).
public protocol PolishEngine: Sendable {
    /// Whether the on-device model is usable right now.
    var isAvailable: Bool { get }
    /// Hint the model to load so the first real polish is faster.
    func prewarm(knownTerms: [String])
    /// Clean up the raw transcript. May throw; the policy treats any throw as a
    /// fallback to the raw text.
    func polish(_ raw: String, knownTerms: [String]) async throws -> String
}

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
    case unchanged
    case applied
}

/// Decides whether a polished transcript may replace the raw one, and applies
/// the gate/guard/fallback policy around the engine. The guard is the defense
/// against the model over-compressing a multi-clause command into a fragment:
/// it keeps the polished text only when the same content-token sequence survives
/// after allowed filler removal and spoken-symbol conversion. The policy never
/// throws and always falls back to the user's own words on any failure.
public struct TranscriptPolisher: Sendable {
    private let enabled: Bool
    private let engine: any PolishEngine
    private let knownTerms: [String]

    public init(enabled: Bool, engine: any PolishEngine, knownTerms: [String] = []) {
        self.enabled = enabled
        self.engine = engine
        self.knownTerms = knownTerms
    }

    /// Returns the text to insert plus the path taken: `.applied` with the
    /// polished text on the happy path, or the raw text with
    /// `.disabled`/`.unavailable`/`.unchanged` (no-op, throw, or guard-fail) on
    /// every other path. Never throws.
    public func polish(_ raw: String) async -> PolishResult {
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return PolishResult(text: raw, outcome: .unchanged)
        }
        guard enabled else { return PolishResult(text: raw, outcome: .disabled) }
        guard engine.isAvailable else { return PolishResult(text: raw, outcome: .unavailable) }
        do {
            let polished = try await engine.polish(raw, knownTerms: knownTerms)
            guard polished != raw, Self.polishRetainsContent(raw: raw, polished: polished) else {
                return PolishResult(text: raw, outcome: .unchanged)
            }
            return PolishResult(text: polished, outcome: .applied)
        } catch {
            return PolishResult(text: raw, outcome: .unchanged)
        }
    }

    /// Hint the engine to load the model so the first real polish is faster. A
    /// no-op unless polish is enabled and the engine is available.
    public func prewarm() {
        guard enabled, engine.isAvailable else { return }
        engine.prewarm(knownTerms: knownTerms)
    }

    // MARK: - Content-retention guard

    static let singleFillers: Set<String> = ["um", "uh", "er", "hmm", "like", "basically"]
    static let fillerPhrases: [[String]] = [
        ["you", "know"],
        ["i", "mean"],
        ["sort", "of"],
        ["kind", "of"],
    ]
    static let rawSpokenSymbolPhrases: [[String]] = [
        ["dash", "dash"],
        ["open", "paren"],
        ["close", "paren"],
        ["open", "parenthesis"],
        ["close", "parenthesis"],
        ["new", "line"],
        ["question", "mark"],
    ]
    static let rawSpokenSymbolWords: Set<String> = [
        "comma", "period", "slash", "dollar", "plus", "times", "equals", "dot"
    ]
    static let semanticLikePrevious: Set<String> = [
        "i", "we", "you", "they", "he", "she", "it",
        "seem", "seems", "seemed",
        "look", "looks", "looked",
        "sound", "sounds", "sounded",
        "feel", "feels", "felt",
    ]
    static let semanticLikeNext: Set<String> = [
        "to", "it", "this", "that", "these", "those",
        "me", "us", "you", "him", "her", "them",
    ]

    /// True when the polished text preserves the raw content-token sequence,
    /// allowing only filler phrases and spoken-symbol words to disappear.
    public static func polishRetainsContent(raw: String, polished: String) -> Bool {
        guard !polished.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }

        return polishedTokensRetainRawContent(
            rawTokens: tokens(from: raw),
            polishedTokens: tokens(from: polished)
        )
    }

    private static func tokens(from text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func polishedTokensRetainRawContent(rawTokens: [String], polishedTokens: [String]) -> Bool {
        var rawIndex = 0
        var polishedIndex = 0
        var matchedContent = false

        while rawIndex < rawTokens.count {
            if let droppedCount = preferredDroppableRawTokenCount(
                in: rawTokens,
                at: rawIndex,
                matchedContent: matchedContent
            ) {
                rawIndex += droppedCount
                continue
            }

            if polishedIndex < polishedTokens.count, rawTokens[rawIndex] == polishedTokens[polishedIndex] {
                rawIndex += 1
                polishedIndex += 1
                matchedContent = true
                continue
            }

            if let droppedCount = droppableRawTokenCount(
                in: rawTokens,
                at: rawIndex,
                matchedContent: matchedContent
            ) {
                rawIndex += droppedCount
                continue
            }

            return false
        }

        return polishedIndex == polishedTokens.count
    }

    private static func preferredDroppableRawTokenCount(
        in tokens: [String],
        at index: Int,
        matchedContent: Bool
    ) -> Int? {
        if tokens[index] == "so", !matchedContent {
            return 1
        }
        if tokens[index] == "like", isPreferablyDroppableLike(in: tokens, at: index, matchedContent: matchedContent) {
            return 1
        }
        if tokens[index] != "like", singleFillers.contains(tokens[index]) {
            return 1
        }
        if let filler = firstMatchingPhrase(in: tokens, at: index, phrases: fillerPhrases) {
            return filler.count
        }
        return nil
    }

    private static func droppableRawTokenCount(
        in tokens: [String],
        at index: Int,
        matchedContent: Bool
    ) -> Int? {
        if tokens[index] == "so", !matchedContent {
            return 1
        }
        if tokens[index] == "like" {
            return isDroppableLike(in: tokens, at: index, matchedContent: matchedContent) ? 1 : nil
        }
        if singleFillers.contains(tokens[index]) {
            return 1
        }
        if let filler = firstMatchingPhrase(in: tokens, at: index, phrases: fillerPhrases) {
            return filler.count
        }
        if rawSpokenSymbolWords.contains(tokens[index]) {
            return 1
        }
        if let symbol = firstMatchingPhrase(in: tokens, at: index, phrases: rawSpokenSymbolPhrases) {
            return symbol.count
        }
        return nil
    }

    private static func isDroppableLike(in tokens: [String], at index: Int, matchedContent: Bool) -> Bool {
        guard matchedContent else { return true }

        let previous = index > tokens.startIndex ? tokens[index - 1] : nil
        let next = index + 1 < tokens.endIndex ? tokens[index + 1] : nil

        if let next, singleFillers.contains(next) || next == "so" {
            return true
        }
        if let previous, semanticLikePrevious.contains(previous) {
            return false
        }
        if let next, semanticLikeNext.contains(next) {
            return false
        }
        return true
    }

    private static func isPreferablyDroppableLike(
        in tokens: [String],
        at index: Int,
        matchedContent: Bool
    ) -> Bool {
        guard matchedContent else { return true }

        let previous = index > tokens.startIndex ? tokens[index - 1] : nil
        let next = index + 1 < tokens.endIndex ? tokens[index + 1] : nil
        if let previous, semanticLikePrevious.contains(previous) {
            return false
        }
        if let next, semanticLikeNext.contains(next) {
            return false
        }
        return next.map { singleFillers.contains($0) || $0 == "so" } ?? false
    }

    private static func firstMatchingPhrase(
        in tokens: [String],
        at index: Int,
        phrases: [[String]]
    ) -> [String]? {
        phrases.first { phrase in
            guard index + phrase.count <= tokens.count else { return false }
            return Array(tokens[index..<(index + phrase.count)]) == phrase
        }
    }
}
