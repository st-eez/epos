import Foundation

/// The content-retention guard: the pure string→bool decision behind
/// `TranscriptPolisher`. It keeps the model's polished text only when the same
/// content-token sequence survives — allowing only filler removal and the
/// hyphen-merge of an already-spoken compound — preserving every dictated symbol
/// and sentence-punctuation glyph (`? ! : ; — – / -- $ …`) exactly, allowing only a
/// stranded comma to drop with its filler, and neither collapsing nor inventing a
/// sentence boundary. Everything else
/// (mishearing "fixes", word substitution, spoken-symbol conversion) is rejected:
/// the guard cannot tell a legitimate one from a corruption, so it keeps the
/// user's raw words. Symbol conversion and known-term correction are owned by
/// `TranscriptCanonicalizer`, which runs on both the raw and polished text, so its
/// deterministic results match on both sides and never reach this guard as a
/// difference.
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

        guard let matches = matchedContentTokens(raw: raw, rawSpans: rawSpans, polishedSpans: polishedSpans) else {
            return false
        }
        guard !matches.isEmpty else { return false }
        // The model must not change the symbols the user dictated — neither ADD
        // meaning-bearing punctuation ("ship it" -> "ship it?", "the error is
        // timeout" -> "the error is: timeout"), DROP or SWAP a dictated `?`/`!`
        // (inverting a question/command into a statement: "is it broken?" -> "is it
        // broken."), nor drop/add a content symbol ("run -- verbose" -> "run
        // verbose"). Only a comma stranded by filler removal may drop. A restored
        // trailing period does not change meaning, so `.` is unbudgeted
        // (boundary-checked below).
        guard symbolUsageIsJustified(raw: raw, polished: polished) else { return false }
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
    private static func matchedContentTokens(
        raw rawText: String,
        rawSpans: [TokenSpan],
        polishedSpans: [TokenSpan]
    ) -> [TokenMatch]? {
        let rawTokens = rawSpans.map(\.text)
        var rawIndex = 0
        var polishedIndex = 0
        var matchedContent = false
        var matches: [TokenMatch] = []

        while rawIndex < rawTokens.count {
            let raw = rawTokens[rawIndex]
            let polished: String? = polishedIndex < polishedSpans.count ? polishedSpans[polishedIndex].text : nil

            // 1. Force-drop a droppable filler "like" before matching. After
            //    `isDroppableLike` was tightened, this fires only sentence-initially
            //    (or with no semantic anchor around it), where "like" is a discourse
            //    marker — so a filler the model happened to keep there surfaces later
            //    as an unconsumed polished token (an addition → reject) rather than
            //    being silently matched. A post-content "like" is never force-dropped:
            //    the guard can't tell a comparator ("tastes like") from a verbal tic,
            //    so it keeps it (matched as content, or — if the model dropped it —
            //    rejected by the "like" arm of drop-on-mismatch below).
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
                if let parts = hyphenMergeParts(polished, raw: rawText, rawSpans: rawSpans, at: rawIndex) {
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
    /// several raw tokens ("well", "known"). Returns the split parts on a match —
    /// but only when the raw source gaps between those tokens are pure whitespace.
    private static func hyphenMergeParts(
        _ polished: String,
        raw: String,
        rawSpans: [TokenSpan],
        at index: Int
    ) -> [String]? {
        guard polished.contains("-") else { return nil }
        let parts = polished.split(separator: "-", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2, index + parts.count <= rawSpans.count else { return nil }
        guard rawSpans[index..<(index + parts.count)].map(\.text) == parts else { return nil }
        // The merge fuses the spanned raw tokens into one polished token, erasing
        // the source gaps between them. Allow it only when every such gap is pure
        // whitespace — a dictated sentence boundary ("done. Ship") or other
        // punctuation between the words must not be silently collapsed into a
        // compound ("done-ship"). Spoken compounds ("well known" → "well-known")
        // are space-separated, so they pass.
        for offset in 0..<(parts.count - 1) {
            let gap = raw[rawSpans[index + offset].range.upperBound..<rawSpans[index + offset + 1].range.lowerBound]
            guard gap.allSatisfy(\.isWhitespace) else { return nil }
        }
        return parts
    }

    /// "like" is droppable only when nothing marks it as content: no semantic
    /// anchor on either side (a comparator verb or pronoun), and only sentence-
    /// initially (`!matchedContent`), where it is a discourse marker ("Like, we
    /// should ship it"). A filler merely sitting next to "like" does NOT make it
    /// droppable — "it tastes like um chicken" must keep its comparator "like" even
    /// though the filler "um" follows. Once a content word precedes "like" it is
    /// almost always a comparator ("tastes like", "works like") or quotative ("I was
    /// like") the guard cannot distinguish from a verbal tic, so it is kept: matched
    /// as content if the model kept it, or rejected by the "like" arm of
    /// drop-on-mismatch if the model dropped it.
    private static func isDroppableLike(in tokens: [String], at index: Int, matchedContent: Bool) -> Bool {
        let previous = index > 0 ? tokens[index - 1] : nil
        let next = index + 1 < tokens.count ? tokens[index + 1] : nil

        if let previous, PolishVocabulary.semanticLikePrevious.contains(previous) { return false }
        if let next, PolishVocabulary.semanticLikeNext.contains(next) { return false }
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

    // MARK: Added/dropped symbols and punctuation

    /// Reject any change to the significant symbols the user dictated. The comma is
    /// the one exception: the recognizer delimits disfluencies with commas
    /// ("um, like, you know,"), so removing a filler legitimately strands one — a
    /// comma may DROP (but never be added). Every other significant glyph is
    /// preserved EXACTLY (count must not change):
    ///   • sentence punctuation (`? ! : ; — –`): adding one reframes the text
    ///     ("the error is timeout" → "the error is: timeout"); dropping or swapping
    ///     a dictated `?`/`!` for the exempt `.` inverts a question or command into a
    ///     statement ("is it broken?" → "is it broken.").
    ///   • content symbols (`/`, `--`, `$`, `(`, …): canonicalizer output present on
    ///     both sides — a silently dropped `--`/`/` and an invented one both reject.
    /// `.` is exempt: the recognizer routinely omits a trailing period and restoring
    /// it does not change meaning, and a mid-text `.` is policed by
    /// `preservesRawSentenceBoundaries`.
    private static func symbolUsageIsJustified(raw: String, polished: String) -> Bool {
        let rawCounts = significantSymbolCounts(raw)
        let polishedCounts = significantSymbolCounts(polished)
        for glyph in Set(rawCounts.keys).union(polishedCounts.keys) where glyph != "." {
            let rawCount = rawCounts[glyph, default: 0]
            let polishedCount = polishedCounts[glyph, default: 0]
            if glyph == "," {
                if polishedCount > rawCount { return false }
            } else if polishedCount != rawCount {
                return false
            }
        }
        return true
    }

    /// Counts of each significant symbol — a non-alphanumeric, non-whitespace glyph
    /// that is NOT a connector flanked by alphanumerics (those stay inside their
    /// token: "well-known", "don't", "v1.2"). A standalone `--`/`/`/`$` between
    /// spaces is significant and counted; an intra-token `-`/`'`/`.` is not. The
    /// flanked-on-BOTH-sides test is deliberately conservative: classifying a
    /// borderline glyph as significant can only over-reject (harmless), never
    /// over-accept.
    private static func significantSymbolCounts(_ text: String) -> [Character: Int] {
        var counts: [Character: Int] = [:]
        let characters = Array(text)
        for (offset, character) in characters.enumerated() {
            if isAlphanumeric(character) || character.isWhitespace { continue }
            let flankedByAlphanumerics = offset > 0 && isAlphanumeric(characters[offset - 1])
                && offset + 1 < characters.count && isAlphanumeric(characters[offset + 1])
            if isConnector(character), flankedByAlphanumerics { continue }
            counts[character, default: 0] += 1
        }
        return counts
    }

    // MARK: Sentence boundaries

    /// The model must neither COLLAPSE a dictated sentence boundary between two kept
    /// words nor INVENT one, and must keep a dictated `?`/`!` boundary's TYPE (a
    /// question must not become a command, or vice versa). For each adjacent matched
    /// pair the raw and polished gaps must agree on whether a boundary is present and
    /// on its mood mark; a restored trailing end-of-text period sits after the last
    /// token, so it is never inspected here.
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
            // A hyphen-merge maps several raw tokens to the same polished token; there
            // is no polished gap between them to inspect (and the merge already
            // verified those raw gaps were whitespace-only).
            guard left.polishedIndex != right.polishedIndex else { continue }

            let rawGap = raw[rawSpans[left.rawIndex].range.upperBound..<rawSpans[right.rawIndex].range.lowerBound]
            let rawNextFirst = raw[rawSpans[right.rawIndex].range.lowerBound]
            let polishedGap = polished[
                polishedSpans[left.polishedIndex].range.upperBound..<polishedSpans[right.polishedIndex].range.lowerBound
            ]
            let polishedNextFirst = polished[polishedSpans[right.polishedIndex].range.lowerBound]

            let rawBoundary = sentenceBoundaryGlyph(rawGap, nextTokenFirstChar: rawNextFirst)
            let polishedBoundary = sentenceBoundaryGlyph(polishedGap, nextTokenFirstChar: polishedNextFirst)

            if let rawBoundary {
                // A dictated boundary must survive ("...do this. You..." must not
                // become "...do this.You...").
                guard let polishedBoundary else { return false }
                // ...and a dictated mood mark must keep its type: a `?`↔`!` swap that
                // balances the per-glyph counts (so the symbol-count check passes)
                // still flips a question and a command between clauses ("do it? stop
                // it!" → "do it! stop it?"). `.` is the soft mark — promoting it to a
                // `?`/`!` ADDS a mood glyph, which the symbol-count check rejects.
                if rawBoundary == "?" || rawBoundary == "!" {
                    guard polishedBoundary == rawBoundary else { return false }
                }
            } else {
                // ...and the model must not invent one where the user dictated none
                // ("ship it now" → "ship it. Now"), splitting one sentence into two.
                guard polishedBoundary == nil else { return false }
            }
        }

        return true
    }

    /// The first sentence-boundary glyph in `separator` (`?`/`!`/`.`), or nil if
    /// none. A `?`/`!` followed by whitespace (or ending the gap) is a boundary; a
    /// `.` is a boundary only when followed by whitespace AND the next token is
    /// capitalized — so an abbreviation/version dot ("fig. 3", "v1.2") is not a false
    /// boundary, and a `.` with no following space ("this.Next") never is. Returning
    /// the glyph (not just a bool) lets the caller reject a `?`↔`!` mood swap that
    /// keeps the per-glyph counts balanced.
    private static func sentenceBoundaryGlyph(_ separator: Substring, nextTokenFirstChar: Character) -> Character? {
        var index = separator.startIndex
        while index < separator.endIndex {
            let character = separator[index]
            let after = separator.index(after: index)
            let followedByWhitespace = after < separator.endIndex && separator[after].isWhitespace
            if character == "?" || character == "!" {
                if followedByWhitespace || after == separator.endIndex { return character }
            } else if character == "." {
                if followedByWhitespace && nextTokenFirstChar.isUppercase { return character }
            }
            index = after
        }
        return nil
    }
}
