import Foundation

enum CorrectionMatchContext {
    static func regex(forAlias alias: String) -> NSRegularExpression? {
        let parts = alias
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)

        guard !parts.isEmpty else { return nil }

        let body = parts
            .map(NSRegularExpression.escapedPattern(for:))
            .joined(separator: #"(?:[\s,\-\.']+)"#)
        let pattern = #"(?<![A-Za-z0-9])"# + body + #"(?![A-Za-z0-9])"#
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

    static func hasContext(_ contexts: [String], before range: NSRange, in text: NSString) -> Bool {
        let prefix = normalizedWindow(before: range, in: text, maxLength: 64)
        return contexts.contains { context in
            let normalizedContext = normalizedPhrase(context)
            return !normalizedContext.isEmpty && prefix.contains(normalizedContext)
        }
    }

    static func normalizedPhrase(_ phrase: String) -> String {
        phrase
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: " ")
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
