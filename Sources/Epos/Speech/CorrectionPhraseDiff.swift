import Foundation

struct CorrectionPhraseReplacement: Equatable, Sendable {
    var alias: String
    var canonical: String

    var key: String {
        "\(normalizedAlias)->\(normalizedCanonical)"
    }

    var normalizedAlias: String {
        CorrectionPhraseDiff.normalizedPhrase(alias)
    }

    var normalizedCanonical: String {
        CorrectionPhraseDiff.normalizedPhrase(canonical)
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
        let alias = observedWords[prefixCount..<observedEnd].joined(separator: " ")
        let canonical = editedWords[prefixCount..<editedEnd].joined(separator: " ")
        guard !alias.isEmpty, !canonical.isEmpty else { return nil }
        guard normalizedPhrase(alias) != normalizedPhrase(canonical) else { return nil }
        return CorrectionPhraseReplacement(alias: alias, canonical: canonical)
    }

    static func containsPhrase(_ phrase: String, in text: String) -> Bool {
        let normalizedText = " \(normalizedPhrase(text)) "
        let normalizedNeedle = " \(normalizedPhrase(phrase)) "
        return !normalizedNeedle.trimmingCharacters(in: .whitespaces).isEmpty
            && normalizedText.contains(normalizedNeedle)
    }

    static func normalizedPhrase(_ phrase: String) -> String {
        phrase
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: " ")
    }

    static func slug(_ phrase: String) -> String {
        let slug = normalizedPhrase(phrase).replacingOccurrences(of: " ", with: "-")
        return slug.isEmpty ? "replacement" : slug
    }

    static func words(in text: String) -> [String] {
        text.split { $0.isWhitespace }.map(String.init)
    }
}
