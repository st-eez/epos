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

    /// True when the polished text preserves the raw content-token sequence after
    /// dropping only allowed filler phrases and raw spoken-symbol words.
    public static func polishRetainsContent(raw: String, polished: String) -> Bool {
        guard !polished.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }

        return contentTokens(from: raw, droppingFillers: true, droppingRawSpokenSymbols: true) ==
            contentTokens(from: polished, droppingFillers: false, droppingRawSpokenSymbols: false)
    }

    private static func contentTokens(
        from text: String,
        droppingFillers: Bool,
        droppingRawSpokenSymbols: Bool
    ) -> [String] {
        let tokens = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        var output: [String] = []
        var index = 0

        while index < tokens.count {
            if droppingFillers {
                if tokens[index] == "so", output.isEmpty {
                    index += 1
                    continue
                }
                if singleFillers.contains(tokens[index]) {
                    index += 1
                    continue
                }
                if let filler = firstMatchingPhrase(in: tokens, at: index, phrases: fillerPhrases) {
                    index += filler.count
                    continue
                }
            }
            if droppingRawSpokenSymbols {
                if rawSpokenSymbolWords.contains(tokens[index]) {
                    index += 1
                    continue
                }
                if let symbol = firstMatchingPhrase(in: tokens, at: index, phrases: rawSpokenSymbolPhrases) {
                    index += symbol.count
                    continue
                }
            }

            output.append(tokens[index])
            index += 1
        }

        return output
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
