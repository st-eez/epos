import Foundation

struct CorrectionPhraseReplacement: Equatable, Sendable {
    var alias: String
    var canonical: String

    var key: String {
        "\(normalizedAlias)->\(normalizedCanonical)"
    }

    var normalizedAlias: String {
        CorrectionMatchContext.normalizedPhrase(alias)
    }

    var normalizedCanonical: String {
        CorrectionMatchContext.normalizedPhrase(canonical)
    }

    var aliasSlug: String {
        CorrectionPhraseDiff.slug(alias)
    }

    var canonicalSlug: String {
        CorrectionPhraseDiff.slug(canonical)
    }
}

enum CorrectionPhraseDiff {
    static func replacement(from observed: String, to edited: String) -> CorrectionPhraseReplacement? {
        let observedWords = words(in: observed)
        let editedWords = words(in: edited)
        guard !observedWords.isEmpty, !editedWords.isEmpty else { return nil }
        guard observedWords != editedWords else { return nil }

        var prefixCount = 0
        while prefixCount < observedWords.count,
              prefixCount < editedWords.count,
              observedWords[prefixCount] == editedWords[prefixCount] {
            prefixCount += 1
        }

        var suffixCount = 0
        while suffixCount < observedWords.count - prefixCount,
              suffixCount < editedWords.count - prefixCount,
              observedWords[observedWords.count - 1 - suffixCount] == editedWords[editedWords.count - 1 - suffixCount] {
            suffixCount += 1
        }

        let observedEnd = observedWords.count - suffixCount
        let editedEnd = editedWords.count - suffixCount
        let phrase = trimmingTrailingSentencePunctuation(
            alias: observedWords[prefixCount..<observedEnd].joined(separator: " "),
            canonical: editedWords[prefixCount..<editedEnd].joined(separator: " ")
        )
        let alias = phrase.alias
        let canonical = phrase.canonical
        guard !alias.isEmpty, !canonical.isEmpty else { return nil }
        guard CorrectionMatchContext.normalizedPhrase(alias)
            != CorrectionMatchContext.normalizedPhrase(canonical) else { return nil }
        return CorrectionPhraseReplacement(alias: alias, canonical: canonical)
    }

    static func containsPhrase(_ phrase: String, in text: String) -> Bool {
        let normalizedText = " \(CorrectionMatchContext.normalizedPhrase(text)) "
        let normalizedNeedle = " \(CorrectionMatchContext.normalizedPhrase(phrase)) "
        return !normalizedNeedle.trimmingCharacters(in: .whitespaces).isEmpty
            && normalizedText.contains(normalizedNeedle)
    }

    static func slug(_ phrase: String) -> String {
        let slug = CorrectionMatchContext.normalizedPhrase(phrase)
            .replacingOccurrences(of: " ", with: "-")
        return slug.isEmpty ? "replacement" : slug
    }

    static func words(in text: String) -> [String] {
        text.split { $0.isWhitespace }.map(String.init)
    }

    private static func trimmingTrailingSentencePunctuation(
        alias: String,
        canonical: String
    ) -> (alias: String, canonical: String) {
        var alias = alias.trimmingTrailingSentencePunctuation()
        var canonical = canonical.trimmingTrailingSentencePunctuation { punctuation in
            aliasSpellsTrailingPunctuation(alias, punctuation: punctuation)
        }

        alias = alias.trimmingCharacters(in: .whitespaces)
        canonical = canonical.trimmingCharacters(in: .whitespaces)
        return (alias, canonical)
    }

    fileprivate static let trailingSentencePunctuation: Set<Character> = [".", ",", "!", "?"]

    private static let spokenPunctuationSuffixes: [Character: [String]] = [
        ".": ["period", "dot"],
        ",": ["comma"],
        "!": ["exclamation mark", "exclamation point"],
        "?": ["question mark"]
    ]

    private static func aliasSpellsTrailingPunctuation(_ alias: String, punctuation: Character) -> Bool {
        guard let suffixes = spokenPunctuationSuffixes[punctuation] else { return false }
        let normalizedAlias = CorrectionMatchContext.normalizedPhrase(alias)
        return suffixes.contains { suffix in
            normalizedAlias == suffix || normalizedAlias.hasSuffix(" \(suffix)")
        }
    }
}

private extension String {
    func trimmingTrailingSentencePunctuation(
        preserving shouldPreserve: (Character) -> Bool = { _ in false }
    ) -> String {
        let original = self
        var text = self
        while let last = text.last,
              CorrectionPhraseDiff.trailingSentencePunctuation.contains(last) {
            if shouldPreserve(last) { break }
            text.removeLast()
        }
        if text.trimmingCharacters(in: .whitespaces).isEmpty {
            return original
        }
        return text
    }
}
