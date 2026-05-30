import Foundation

/// The content-retention guard: the pure string→bool decision behind
/// `TranscriptPolisher`. It keeps the model's polished text only when the same
/// content-token sequence survives — allowing only filler removal and the
/// hyphen-merge of an already-spoken compound — with no added `,`/`?`/`!` and no
/// collapsed sentence boundary. Everything else (mishearing "fixes", word
/// substitution, spoken-symbol conversion) is rejected: the guard cannot tell a
/// legitimate one from a corruption, so it keeps the user's raw words. Symbol
/// conversion and known-term correction are owned by `TranscriptCanonicalizer`,
/// which runs on both the raw and polished text, so its deterministic results
/// match on both sides and never reach this guard as a difference.
///
/// The standard is asymmetric: a false reject is harmless (the raw words are
/// kept), a false accept types altered meaning into the user's app, so every
/// ambiguous case rejects. Pure (no I/O), exercised directly with a table of
/// cases. Lives apart from the policy so each file stays one concern.
extension TranscriptPolisher {
    /// True when the polished text preserves the raw content-token sequence and
    /// existing sentence boundaries under the allowed cleanup above.
    public static func polishRetainsContent(raw: String, polished: String) -> Bool {
        guard !polished.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }

        let rawSpans = tokenSpans(from: raw)
        let polishedSpans = tokenSpans(from: polished)

        // Zero-content input: accept only when the polished side is also content-
        // free AND introduces no new non-whitespace characters ("..." -> "." is a
        // fine conversion; "..." -> "???" is an unrelated rewrite).
        if rawSpans.isEmpty {
            guard polishedSpans.isEmpty else { return false }
            return nonWhitespaceScalars(polished).isSubset(of: nonWhitespaceScalars(raw))
        }

        guard let matches = matchedContentTokens(rawSpans: rawSpans, polishedSpans: polishedSpans) else {
            return false
        }
        guard !matches.isEmpty else { return false }
        // The model must not INTRODUCE meaning-bearing punctuation the user didn't
        // dictate — a statement turned into a question ("ship it" -> "ship it?")
        // or a vocative comma ("lets eat grandma" -> "lets eat, grandma") changes
        // meaning even though every word survives. A restored trailing period does
        // not change meaning, so `.` is unbudgeted.
        guard punctuationAdditionsAreJustified(raw: raw, polished: polished) else { return false }
        return preservesRawSentenceBoundaries(
            raw: raw,
            polished: polished,
            rawSpans: rawSpans,
            polishedSpans: polishedSpans,
            matches: matches
        )
    }

    private struct TokenSpan {
        let text: String
        let range: Range<String.Index>
    }

    private struct TokenMatch {
        let rawIndex: Int
        let polishedIndex: Int
    }

    // MARK: Tokenization

    /// Split into content tokens. A character joins the current token when it is
    /// alphanumeric, or when it is a connector (`'`, `’`, `-`, `.`) sitting
    /// *between* two alphanumerics — so "don't", "well-known", and "AGENTS.md"
    /// stay single tokens while a trailing "fig." period is a separator. The
    /// stored `text` is lowercased and has `’` folded to `'` (so "don't" matches
    /// regardless of glyph); the `range` spans the source so the gap between
    /// tokens can be inspected for sentence punctuation.
    private static func tokenSpans(from text: String) -> [TokenSpan] {
        var spans: [TokenSpan] = []
        var tokenStart: String.Index?
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if isAlphanumeric(character) {
                tokenStart = tokenStart ?? index
            } else if isConnector(character), tokenStart != nil, next < text.endIndex, isAlphanumeric(text[next]) {
                // Connector between two alphanumerics: stays part of the token.
            } else if let start = tokenStart {
                spans.append(makeSpan(text, start: start, end: index))
                tokenStart = nil
            }
            index = next
        }

        if let start = tokenStart {
            spans.append(makeSpan(text, start: start, end: text.endIndex))
        }
        return spans
    }

    private static func makeSpan(_ text: String, start: String.Index, end: String.Index) -> TokenSpan {
        TokenSpan(text: normalizeToken(String(text[start..<end])), range: start..<end)
    }

    /// Lowercase and fold the curly apostrophe so "don't" matches regardless of
    /// which glyph the recognizer/model used. We deliberately do NOT strip a
    /// trailing "'s": that would collapse contractions ("let's" -> "let") and let
    /// the guard accept dropping the elided word ("let's go" -> "let go").
    private static func normalizeToken(_ raw: String) -> String {
        raw.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
    }

    private static func isAlphanumeric(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
    }

    private static func isConnector(_ character: Character) -> Bool {
        character == "'" || character == "\u{2019}" || character == "-" || character == "."
    }

    private static func nonWhitespaceScalars(_ text: String) -> Set<Unicode.Scalar> {
        Set(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
    }

    // MARK: Matching

    /// Walk the raw tokens against the polished tokens, allowing only filler drops
    /// and an already-spoken hyphen-merge. Any other unmatched raw token, or any
    /// leftover polished token (an addition), rejects the whole polish.
    private static func matchedContentTokens(rawSpans: [TokenSpan], polishedSpans: [TokenSpan]) -> [TokenMatch]? {
        let rawTokens = rawSpans.map(\.text)
        var rawIndex = 0
        var polishedIndex = 0
        var matchedContent = false
        var matches: [TokenMatch] = []

        while rawIndex < rawTokens.count {
            let raw = rawTokens[rawIndex]
            let polished: String? = polishedIndex < polishedSpans.count ? polishedSpans[polishedIndex].text : nil

            // 1. Force-drop a filler "like" before matching, so a filler the model
            //    happened to keep surfaces later as an unconsumed polished token
            //    (an addition → reject) rather than being silently matched.
            if raw == "like", isDroppableLike(in: rawTokens, at: rawIndex, matchedContent: matchedContent) {
                rawIndex += 1
                continue
            }

            // 2. Match-first: exact, or a polished hyphenated token spanning several
            //    raw tokens ("well", "known" → "well-known").
            if let polished {
                if raw == polished {
                    matches.append(TokenMatch(rawIndex: rawIndex, polishedIndex: polishedIndex))
                    rawIndex += 1; polishedIndex += 1; matchedContent = true
                    continue
                }
                if let parts = hyphenMergeParts(polished, rawTokens: rawTokens, at: rawIndex) {
                    for offset in 0..<parts.count {
                        matches.append(TokenMatch(rawIndex: rawIndex + offset, polishedIndex: polishedIndex))
                    }
                    rawIndex += parts.count; polishedIndex += 1; matchedContent = true
                    continue
                }
            }

            // 3. Drop-on-mismatch: filler removal only.
            if raw == "so", !matchedContent {
                rawIndex += 1; continue
            }
            if raw == "like" {
                return nil
            }
            if PolishVocabulary.singleFillers.contains(raw) {
                rawIndex += 1; continue
            }
            if let phrase = firstMatchingPhrase(in: rawTokens, at: rawIndex, phrases: PolishVocabulary.fillerPhrases) {
                rawIndex += phrase.count; continue
            }
            return nil
        }

        return polishedIndex == polishedSpans.count ? matches : nil
    }

    /// A polished hyphenated token (e.g. "well-known") that exactly spans the next
    /// several raw tokens ("well", "known"). Returns the split parts on a match.
    private static func hyphenMergeParts(_ polished: String, rawTokens: [String], at index: Int) -> [String]? {
        guard polished.contains("-") else { return nil }
        let parts = polished.split(separator: "-", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2, index + parts.count <= rawTokens.count else { return nil }
        return Array(rawTokens[index..<(index + parts.count)]) == parts ? parts : nil
    }

    private static func isDroppableLike(in tokens: [String], at index: Int, matchedContent: Bool) -> Bool {
        let previous = index > 0 ? tokens[index - 1] : nil
        let next = index + 1 < tokens.count ? tokens[index + 1] : nil

        if let previous, PolishVocabulary.semanticLikePrevious.contains(previous) { return false }
        if let next, PolishVocabulary.semanticLikeNext.contains(next) { return false }
        if let next, PolishVocabulary.singleFillers.contains(next) || next == "so" { return true }
        if let previous, PolishVocabulary.singleFillers.contains(previous) || previous == "so" { return true }
        return !matchedContent
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

    // MARK: Added punctuation

    /// Reject polished output containing more `,` `?` or `!` than the raw — the
    /// user did not dictate them, and they can change meaning with every word kept
    /// (statement→question, a vocative comma). `.` is unbudgeted: the recognizer
    /// routinely omits a trailing one and restoring it does not change meaning.
    private static func punctuationAdditionsAreJustified(raw: String, polished: String) -> Bool {
        for glyph in [",", "?", "!"] as [Character] {
            if occurrences(of: glyph, in: polished) > occurrences(of: glyph, in: raw) { return false }
        }
        return true
    }

    private static func occurrences(of character: Character, in text: String) -> Int {
        text.reduce(0) { $1 == character ? $0 + 1 : $0 }
    }

    // MARK: Sentence boundaries

    private static func preservesRawSentenceBoundaries(
        raw: String,
        polished: String,
        rawSpans: [TokenSpan],
        polishedSpans: [TokenSpan],
        matches: [TokenMatch]
    ) -> Bool {
        guard matches.count > 1 else { return true }

        for index in 0..<(matches.count - 1) {
            let left = matches[index]
            let right = matches[index + 1]
            // A hyphen-merge maps several raw tokens to the same polished token;
            // there is no polished gap between them to inspect.
            guard left.polishedIndex != right.polishedIndex else { continue }

            let rawGap = raw[rawSpans[left.rawIndex].range.upperBound..<rawSpans[right.rawIndex].range.lowerBound]
            let rawNextFirst = raw[rawSpans[right.rawIndex].range.lowerBound]
            guard containsSentenceBoundary(rawGap, nextTokenFirstChar: rawNextFirst) else { continue }

            let polishedGap = polished[
                polishedSpans[left.polishedIndex].range.upperBound..<polishedSpans[right.polishedIndex].range.lowerBound
            ]
            let polishedNextFirst = polished[polishedSpans[right.polishedIndex].range.lowerBound]
            guard containsSentenceBoundary(polishedGap, nextTokenFirstChar: polishedNextFirst) else { return false }
        }

        return true
    }

    /// A `?`/`!` followed by whitespace (or ending the gap) is a boundary. A `.`
    /// is a boundary only when followed by whitespace AND the next token is
    /// capitalized — so an abbreviation/version dot ("fig. 3", "v1.2") is not a
    /// false boundary, and a `.` with no following space ("this.Next") never is.
    private static func containsSentenceBoundary(_ separator: Substring, nextTokenFirstChar: Character) -> Bool {
        var index = separator.startIndex
        while index < separator.endIndex {
            let character = separator[index]
            let after = separator.index(after: index)
            let followedByWhitespace = after < separator.endIndex && separator[after].isWhitespace
            if character == "?" || character == "!" {
                if followedByWhitespace || after == separator.endIndex { return true }
            } else if character == "." {
                if followedByWhitespace && nextTokenFirstChar.isUppercase { return true }
            }
            index = after
        }
        return false
    }
}
