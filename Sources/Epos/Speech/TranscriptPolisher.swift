import Foundation

/// Decides whether a polished transcript may replace the raw one. The guard is
/// the defense against the model over-compressing a multi-clause command into a
/// fragment: it compares the *significant* (non-filler) words of both and keeps
/// the polished text only when enough of the raw's content survives. Pure and
/// unit-testable; the policy that calls it lands in later slices.
public struct TranscriptPolisher {
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
