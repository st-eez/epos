import Foundation

enum CorrectionMatchContext {
    static func uniqueAliases(_ aliases: [String]) -> [String] {
        var seen: Set<String> = []
        return aliases.filter { alias in
            let key = alias.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty, !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }

    static func regex(forAlias alias: String) -> NSRegularExpression? {
        let nsAlias = alias as NSString
        let fullRange = NSRange(location: 0, length: nsAlias.length)
        let tokenMatches = aliasTokenRegex?.matches(in: alias, range: fullRange) ?? []
        guard !tokenMatches.isEmpty else { return nil }

        var body = ""
        var cursor = 0
        for (index, tokenMatch) in tokenMatches.enumerated() {
            let separatorRange = NSRange(
                location: cursor,
                length: tokenMatch.range.location - cursor
            )
            if separatorRange.length > 0 {
                let separator = nsAlias.substring(with: separatorRange)
                let isInternal = index > 0
                body += separatorPattern(separator, isInternal: isInternal)
            }
            body += NSRegularExpression.escapedPattern(
                for: nsAlias.substring(with: tokenMatch.range)
            )
            cursor = tokenMatch.range.location + tokenMatch.range.length
        }
        if cursor < nsAlias.length {
            body += NSRegularExpression.escapedPattern(for: nsAlias.substring(from: cursor))
        }

        // Unicode-aware boundaries: an accented letter neighbor (e.g. "caféepos")
        // is still mid-word, so ASCII-only [A-Za-z0-9] classes are too narrow.
        let pattern = #"(?<![\p{L}\p{N}])"# + body + #"(?![\p{L}\p{N}])"#
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    static func allows(
        matchStrategy: TranscriptCanonicalizer.Rule.MatchStrategy,
        contexts: [String],
        before range: NSRange,
        in text: NSString
    ) -> Bool {
        if !contexts.isEmpty, !hasContext(contexts, before: range, in: text) {
            return false
        }

        switch matchStrategy {
        case .literal:
            return true
        case .personNameSlot:
            return isPersonNameSlot(range: range, in: text)
        }
    }

    /// Preserves a recognizer-emitted sentence-initial capital when a lowercase
    /// canonical replaces it: only when the match opens a sentence (string start,
    /// or sentence-ending punctuation plus whitespace, or a newline) AND the
    /// matched source began uppercase AND the canonical begins lowercase.
    /// Canonicals that are uppercase by design (proper nouns) and mid-sentence
    /// or lowercase-source matches pass through untouched.
    static func sentenceCasedCanonical(_ canonical: String, forMatch range: NSRange, in text: NSString) -> String {
        guard let canonicalFirst = canonical.first, canonicalFirst.isLowercase else { return canonical }
        guard let sourceFirst = text.substring(with: range).first, sourceFirst.isUppercase else { return canonical }
        guard isSentenceInitial(before: range.location, in: text) else { return canonical }
        return canonicalFirst.uppercased() + String(canonical.dropFirst())
    }

    static func hasContext(_ contexts: [String], before range: NSRange, in text: NSString) -> Bool {
        let prefix = normalizedWindow(before: range, in: text, maxLength: 64)
        let prefixTokens = prefix.split(separator: " ").map(String.init)
        return contexts.contains { context in
            let contextTokens = normalizedPhrase(context).split(separator: " ").map(String.init)
            guard !contextTokens.isEmpty, contextTokens.count <= prefixTokens.count else {
                return false
            }
            return (0...(prefixTokens.count - contextTokens.count)).contains { start in
                Array(prefixTokens[start..<(start + contextTokens.count)]) == contextTokens
            }
        }
    }

    static func normalizedPhrase(_ phrase: String) -> String {
        phrase
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: " ")
    }

    /// UTF-16 scan back from `location`: skip whitespace/newlines, then require
    /// string start, a newline among the skipped separators, or sentence-ending
    /// punctuation. All probed characters (space, newline, `.?!`) are BMP, so
    /// unichar comparisons are safe; surrogate halves match neither set.
    private static func isSentenceInitial(before location: Int, in text: NSString) -> Bool {
        var index = location
        var sawNewline = false
        var sawSeparator = false
        while index > 0 {
            let unit = text.character(at: index - 1)
            guard let scalar = Unicode.Scalar(unit), CharacterSet.whitespacesAndNewlines.contains(scalar) else {
                break
            }
            sawSeparator = true
            sawNewline = sawNewline || CharacterSet.newlines.contains(scalar)
            index -= 1
        }
        if index == 0 || sawNewline { return true }
        guard sawSeparator else { return false }
        guard let previous = Unicode.Scalar(text.character(at: index - 1)) else { return false }
        return previous == "." || previous == "?" || previous == "!"
    }

    private static func isPersonNameSlot(range: NSRange, in text: NSString) -> Bool {
        let before = normalizedWindow(before: range, in: text, maxLength: 96)
        let after = normalizedWindow(after: range, in: text, maxLength: 64)

        let beforeTokens = before.split(separator: " ").map(String.init)
        let afterTokens = after.split(separator: " ").map(String.init)

        if hasNegativePersonCue(beforeTokens: beforeTokens, afterTokens: afterTokens) {
            return false
        }
        if personPrecedingCues.contains(where: { phrase in ends(with: phrase, tokens: beforeTokens) }) {
            return true
        }
        if personFollowingCues.contains(where: { phrase in starts(with: phrase, tokens: afterTokens) }) {
            return true
        }

        return false
    }

    private static func normalizedWindow(before range: NSRange, in text: NSString, maxLength: Int) -> String {
        let start = max(0, range.location - maxLength)
        let raw = text.substring(with: NSRange(location: start, length: range.location - start))
        return normalizedPhrase(raw)
    }

    private static func normalizedWindow(after range: NSRange, in text: NSString, maxLength: Int) -> String {
        let start = range.location + range.length
        guard start < text.length else { return "" }
        let length = min(maxLength, text.length - start)
        let raw = text.substring(with: NSRange(location: start, length: length))
        return normalizedPhrase(raw)
    }

    private static func hasNegativePersonCue(beforeTokens: [String], afterTokens: [String]) -> Bool {
        if let previous = beforeTokens.last, negativePreviousTokens.contains(previous) {
            return true
        }
        if let next = afterTokens.first, negativeNextTokens.contains(next) {
            return true
        }
        return false
    }

    private static func ends(with phrase: String, tokens: [String]) -> Bool {
        let phraseTokens = phrase.split(separator: " ").map(String.init)
        guard !phraseTokens.isEmpty, tokens.count >= phraseTokens.count else { return false }
        return Array(tokens.suffix(phraseTokens.count)) == phraseTokens
    }

    private static func starts(with phrase: String, tokens: [String]) -> Bool {
        let phraseTokens = phrase.split(separator: " ").map(String.init)
        guard !phraseTokens.isEmpty, tokens.count >= phraseTokens.count else { return false }
        return Array(tokens.prefix(phraseTokens.count)) == phraseTokens
    }

    private static func separatorPattern(_ separator: String, isInternal: Bool) -> String {
        let flexibleSeparators = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: #",-.'"#))
        if isInternal,
           separator.unicodeScalars.allSatisfy({ flexibleSeparators.contains($0) }) {
            return #"(?:[\s,\-\.']+)"#
        }
        return NSRegularExpression.escapedPattern(for: separator)
    }

    private static let aliasTokenRegex = try? NSRegularExpression(pattern: #"[\p{L}\p{N}]+"#)

    private static let personPrecedingCues = [
        "ask",
        "asked",
        "call",
        "called",
        "check with",
        "dm",
        "email",
        "follow up with",
        "invite",
        "message",
        "message to",
        "ping",
        "reply to",
        "respond to",
        "send a message to",
        "send message to",
        "send to",
        "talk to",
        "talk with",
        "teams message to",
        "tell",
        "text"
    ]

    private static let personFollowingCues = [
        "asked",
        "fixed",
        "pushed",
        "replied",
        "responded",
        "reviewed",
        "said",
        "says",
        "sent"
    ]

    private static let negativePreviousTokens = [
        "a",
        "first",
        "last",
        "next",
        "one",
        "second",
        "that",
        "the",
        "third",
        "this",
        "two"
    ]

    private static let negativeNextTokens = [
        "back",
        "by",
        "instructions",
        "one",
        "two"
    ]
}
