import Foundation

/// The content-retention guard: the pure string→bool decision behind
/// `TranscriptPolisher`. It keeps the model's polished text only when the same
/// content-token sequence survives — allowing only filler removal and the
/// hyphen-merge of an already-spoken compound — preserving every dictated symbol
/// and sentence-punctuation glyph (`? ! : ; — – / -- $ …`) exactly, allowing a
/// comma to drop ONLY when stranded beside a removed filler (never added, never
/// dropped beside a kept word), holding all-caps acronyms case-sensitive so they
/// cannot fold to/from a lowercase homograph, and neither collapsing nor inventing
/// a sentence boundary. Everything else (mishearing "fixes", word substitution,
/// spoken-symbol conversion) is rejected: the guard cannot tell a legitimate one
/// from a corruption, so it keeps the user's raw words. Symbol conversion and
/// known-term correction are owned by `TranscriptCanonicalizer`, which runs on
/// both the raw and polished text, so its deterministic results match on both
/// sides and never reach this guard as a difference.
///
/// The standard is asymmetric: a false reject is harmless (the raw words are
/// kept), a false accept types altered meaning into the user's app, so every
/// ambiguous case rejects. Pure (no I/O), exercised directly with a table of
/// cases. Lives apart from the policy so each file stays one concern.
extension TranscriptPolisher {
    /// True when the polished text preserves the raw content-token sequence and
    /// existing sentence boundaries under the allowed cleanup above.
    public static func polishRetainsContent(raw: String, polished: String) -> Bool {
        polishRetentionEvaluation(raw: raw, polished: polished).retainsContent
    }

    /// The full guard decision, with rejection metadata for dogfood
    /// diagnostics. The rejected candidate is logged verbatim so dogfood runs can
    /// evaluate the model's attempted rewrite; the diff adds structured context.
    public static func polishRetentionEvaluation(raw: String, polished: String) -> PolishRetentionEvaluation {
        guard !polished.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return rejectedPolish(
                reason: .emptyPolished,
                polished: polished,
                diff: "rawChars=\(raw.count) polishedChars=\(polished.count)"
            )
        }

        let rawSpans = tokenSpans(from: raw)
        let polishedSpans = tokenSpans(from: polished)

        // Zero-content input: accept only when the polished side is also content-
        // free AND introduces no new non-whitespace characters ("..." -> "." is a
        // fine conversion; "..." -> "???" is an unrelated rewrite).
        if rawSpans.isEmpty {
            guard polishedSpans.isEmpty else {
                return rejectedPolish(
                    reason: .contentTokensChanged,
                    polished: polished,
                    diff: contentTokenDiffSummary(
                        rawSpans: rawSpans,
                        polishedSpans: polishedSpans,
                        rejection: .init(kind: .polishedTokenAdded, rawIndex: nil, polishedIndex: 0)
                    )
                )
            }
            let rawScalars = nonWhitespaceScalars(raw)
            let polishedScalars = nonWhitespaceScalars(polished)
            guard polishedScalars.isSubset(of: rawScalars) else {
                return rejectedPolish(
                    reason: .zeroContentRewrite,
                    polished: polished,
                    diff: [
                        "rawNonWhitespaceScalars=\(rawScalars.count)",
                        "polishedNonWhitespaceScalars=\(polishedScalars.count)",
                        "introducedScalars=\(polishedScalars.subtracting(rawScalars).count)"
                    ].joined(separator: " ")
                )
            }
            return acceptedPolish()
        }

        let matches: [TokenMatch]
        switch contentTokenMatch(raw: raw, rawSpans: rawSpans, polishedSpans: polishedSpans) {
        case .matched(let tokenMatches):
            matches = tokenMatches
        case .rejected(let rejection):
            return rejectedPolish(
                reason: .contentTokensChanged,
                polished: polished,
                diff: contentTokenDiffSummary(
                    rawSpans: rawSpans,
                    polishedSpans: polishedSpans,
                    rejection: rejection
                )
            )
        }
        // The model must not change the symbols the user dictated — neither ADD
        // meaning-bearing punctuation ("ship it" -> "ship it?", "the error is
        // timeout" -> "the error is: timeout"), DROP or SWAP a dictated `?`/`!`
        // (inverting a question/command into a statement: "is it broken?" -> "is it
        // broken."), nor drop/add a content symbol ("run -- verbose" -> "run
        // verbose"). A restored trailing period does not change meaning, so `.` is
        // unbudgeted (boundary-checked below). The comma is handled separately,
        // positionally: it may drop ONLY when stranded by a removed filler, never be
        // added, and never drop beside a kept content word.
        guard symbolUsageIsJustified(raw: raw, polished: polished) else {
            return rejectedPolish(
                reason: .symbolUsageChanged,
                polished: polished,
                diff: symbolDiffSummary(raw: raw, polished: polished)
            )
        }
        guard commaUsageIsJustified(
            raw: raw,
            polished: polished,
            rawSpans: rawSpans,
            polishedSpans: polishedSpans,
            matches: matches
        ) else {
            return rejectedPolish(
                reason: .commaUsageChanged,
                polished: polished,
                diff: commaDiffSummary(raw: raw, polished: polished)
            )
        }
        guard preservesRawSentenceBoundaries(
            raw: raw,
            polished: polished,
            rawSpans: rawSpans,
            polishedSpans: polishedSpans,
            matches: matches
        ) else {
            return rejectedPolish(
                reason: .sentenceBoundaryChanged,
                polished: polished,
                diff: sentenceBoundaryDiffSummary(raw: raw, polished: polished)
            )
        }
        return acceptedPolish()
    }

    private struct TokenSpan {
        /// Normalized (lowercased, `’`→`'`) form used for content matching.
        let text: String
        /// The token exactly as it appeared in the source. Carried so the match-
        /// first arm can enforce acronym case-sensitivity: an all-caps acronym must
        /// not silently fold to/from a lowercase homograph ("IT" ≠ "it", "US" ≠
        /// "us"), in either direction.
        let original: String
        let range: Range<String.Index>
    }

    private struct TokenMatch {
        let rawIndex: Int
        let polishedIndex: Int
    }

    private enum ContentTokenMatchResult {
        case matched([TokenMatch])
        case rejected(ContentTokenRejection)
    }

    private struct ContentTokenRejection {
        let kind: ContentTokenRejectionKind
        let rawIndex: Int?
        let polishedIndex: Int?
    }

    private enum ContentTokenRejectionKind: String {
        case noContentMatched = "no-content-matched"
        case rawTokenChanged = "raw-token-changed"
        case rawTokenDeleted = "raw-token-deleted"
        case polishedTokenAdded = "polished-token-added"
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
        let original = String(text[start..<end])
        return TokenSpan(text: normalizeToken(original), original: original, range: start..<end)
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

    private static func acceptedPolish() -> PolishRetentionEvaluation {
        PolishRetentionEvaluation(retainsContent: true, rejection: nil)
    }

    private static func rejectedPolish(
        reason: PolishGuardRejectionReason,
        polished: String,
        diff: String
    ) -> PolishRetentionEvaluation {
        PolishRetentionEvaluation(
            retainsContent: false,
            rejection: PolishGuardRejection(
                reason: reason,
                candidateText: polished,
                candidateCharacterCount: polished.count,
                diff: diff
            )
        )
    }

    // MARK: Matching

    /// Walk the raw tokens against the polished tokens, allowing only filler drops
    /// and an already-spoken hyphen-merge. Any other unmatched raw token, or any
    /// leftover polished token (an addition), rejects the whole polish.
    private static func contentTokenMatch(
        raw rawText: String,
        rawSpans: [TokenSpan],
        polishedSpans: [TokenSpan]
    ) -> ContentTokenMatchResult {
        let rawTokens = rawSpans.map(\.text)
        var rawIndex = 0
        var polishedIndex = 0
        var matchedContent = false
        var matches: [TokenMatch] = []

        while rawIndex < rawTokens.count {
            let raw = rawTokens[rawIndex]
            let polished: String? = polishedIndex < polishedSpans.count ? polishedSpans[polishedIndex].text : nil

            // 1. Match-first: exact, or a polished hyphenated token spanning several
            //    raw tokens ("well", "known" → "well-known"). This runs BEFORE the
            //    force-drop-"like" arm so a leading "like" the model KEPT ("Like
            //    button is broken") matches as content (keeping a possible filler
            //    never changes meaning); a leading discourse "like" the model dropped
            //    is not present in `polished` here, so it falls through to the force-
            //    drop arm below.
            if let polished {
                if raw == polished, acronymCaseAgrees(rawSpans[rawIndex], polishedSpans[polishedIndex]) {
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

            // 2. Drop-on-mismatch: filler removal only. The deletion decision uses
            //    the original token surface, not only the normalized text, so all-
            //    caps acronyms such as "ER" cannot be dropped as filler "er".
            if canDropRawToken(
                rawSpans[rawIndex],
                raw: rawText,
                rawSpans: rawSpans,
                rawTokens: rawTokens,
                at: rawIndex,
                matchedContent: matchedContent
            ) {
                rawIndex += 1; continue
            }
            return .rejected(ContentTokenRejection(
                kind: polished == nil ? .rawTokenDeleted : .rawTokenChanged,
                rawIndex: rawIndex,
                polishedIndex: polished == nil ? nil : polishedIndex
            ))
        }

        guard polishedIndex == polishedSpans.count else {
            return .rejected(ContentTokenRejection(
                kind: .polishedTokenAdded,
                rawIndex: nil,
                polishedIndex: polishedIndex
            ))
        }
        guard !matches.isEmpty else {
            return .rejected(ContentTokenRejection(kind: .noContentMatched, rawIndex: nil, polishedIndex: nil))
        }
        return .matched(matches)
    }

    private static func contentTokenDiffSummary(
        rawSpans: [TokenSpan],
        polishedSpans: [TokenSpan],
        rejection: ContentTokenRejection
    ) -> String {
        var parts = [
            "kind=\(rejection.kind.rawValue)",
            "rawTokens=\(rawSpans.count)",
            "polishedTokens=\(polishedSpans.count)"
        ]
        if let rawIndex = rejection.rawIndex, rawSpans.indices.contains(rawIndex) {
            appendTokenSummary(prefix: "raw", index: rawIndex, span: rawSpans[rawIndex], to: &parts)
        }
        if let polishedIndex = rejection.polishedIndex, polishedSpans.indices.contains(polishedIndex) {
            appendTokenSummary(prefix: "polished", index: polishedIndex, span: polishedSpans[polishedIndex], to: &parts)
        }
        if let hint = tokenChangeHint(rawSpans: rawSpans, polishedSpans: polishedSpans, rejection: rejection) {
            parts.append("hint=\(hint)")
        }
        return parts.joined(separator: " ")
    }

    private static func appendTokenSummary(
        prefix: String,
        index: Int,
        span: TokenSpan,
        to parts: inout [String]
    ) {
        parts.append("\(prefix)Index=\(index)")
        parts.append("\(prefix)TokenShape=\(tokenShape(span.original))")
        parts.append("\(prefix)TokenChars=\(span.original.count)")
    }

    private static func tokenShape(_ token: String) -> String {
        if isNumericOrdinal(token) { return "numeric-ordinal" }
        if isOrdinalWord(token) { return "ordinal-word" }
        if token.allSatisfy(\.isNumber) { return "number" }
        if isAcronym(token) { return "acronym" }
        if token.allSatisfy(\.isLetter) { return "word" }
        if token.contains("-") { return "hyphenated" }
        if token.contains(".") { return "dotted" }
        if token.contains("'") || token.contains("\u{2019}") { return "apostrophe" }
        if token.contains(where: \.isNumber), token.contains(where: \.isLetter) { return "alphanumeric" }
        return "mixed"
    }

    private static func tokenChangeHint(
        rawSpans: [TokenSpan],
        polishedSpans: [TokenSpan],
        rejection: ContentTokenRejection
    ) -> String? {
        guard
            let rawIndex = rejection.rawIndex,
            let polishedIndex = rejection.polishedIndex,
            rawSpans.indices.contains(rawIndex),
            polishedSpans.indices.contains(polishedIndex)
        else {
            return nil
        }

        let raw = rawSpans[rawIndex]
        let polished = polishedSpans[polishedIndex]
        if (isNumericOrdinal(raw.original) && isOrdinalWord(polished.original))
            || (isOrdinalWord(raw.original) && isNumericOrdinal(polished.original)) {
            return "ordinal-normalization"
        }
        if raw.text == polished.text, !acronymCaseAgrees(raw, polished) {
            return "acronym-case-fold"
        }
        if tokenShape(raw.original) == "number", tokenShape(polished.original) == "number" {
            return "number-changed"
        }
        if tokenShape(raw.original) != tokenShape(polished.original) {
            return "token-shape-changed"
        }
        return nil
    }

    private static func isNumericOrdinal(_ token: String) -> Bool {
        let lowercased = token.lowercased()
        guard ["st", "nd", "rd", "th"].contains(where: { lowercased.hasSuffix($0) }) else {
            return false
        }
        let suffixStart = lowercased.index(lowercased.endIndex, offsetBy: -2)
        let digits = lowercased[..<suffixStart]
        return !digits.isEmpty && digits.allSatisfy(\.isNumber)
    }

    private static func isOrdinalWord(_ token: String) -> Bool {
        ordinalWords.contains(normalizeToken(token))
    }

    private static let ordinalWords: Set<String> = [
        "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth",
        "eleventh", "twelfth", "thirteenth", "fourteenth", "fifteenth", "sixteenth", "seventeenth",
        "eighteenth", "nineteenth", "twentieth", "twenty-first", "twenty-second", "twenty-third",
        "twenty-fourth", "twenty-fifth", "twenty-sixth", "twenty-seventh", "twenty-eighth",
        "twenty-ninth", "thirtieth", "thirty-first"
    ]

    /// True when, given two tokens whose normalized forms are equal, their case is
    /// compatible. An all-caps acronym ("IT", "US") must not silently fold to/from a
    /// lowercase homograph in EITHER direction — the model lowercasing "IT" → "it"
    /// or uppercasing "us" → "US" both change meaning. When either side is an
    /// acronym, require the un-normalized forms to match case-sensitively; otherwise
    /// ordinary case differences (sentence-initial capitalization) are fine. A
    /// single letter ("I") is not an acronym, so "I" ↔ "i" still matches.
    private static func acronymCaseAgrees(_ raw: TokenSpan, _ polished: TokenSpan) -> Bool {
        guard isAcronym(raw.original) || isAcronym(polished.original) else { return true }
        return raw.original == polished.original
    }

    /// An all-caps acronym: at least two characters, every character a letter, and
    /// equal to its own uppercase but not its own lowercase (so it is genuinely
    /// upper-cased, ruling out non-cased scripts).
    private static func isAcronym(_ string: String) -> Bool {
        string.count >= 2
            && string.allSatisfy(\.isLetter)
            && string == string.uppercased()
            && string != string.lowercased()
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
        // The normalized comparison above is case-insensitive, so it cannot police an
        // acronym folding case inside a merge ("API KEY" → "api-key"). Rather than
        // thread original-case parts through, reject any merge that spans an all-caps
        // acronym and keep the raw words — a spoken acronym compound being hyphenated
        // is rare, and a false reject here is harmless.
        guard !rawSpans[index..<(index + parts.count)].contains(where: { isAcronym($0.original) }) else {
            return nil
        }
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

    private static func canDropRawToken(
        _ span: TokenSpan,
        raw: String,
        rawSpans: [TokenSpan],
        rawTokens: [String],
        at index: Int,
        matchedContent: Bool
    ) -> Bool {
        let token = span.text
        if PolishVocabulary.singleFillers.contains(token) {
            return !isAcronym(span.original)
        }
        if token == "so" {
            return !matchedContent && isCommaDelimitedDiscourseMarker(raw: raw, rawSpans: rawSpans, at: index)
        }
        if token == "like" {
            return isDroppableLike(in: rawTokens, raw: raw, rawSpans: rawSpans, at: index, matchedContent: matchedContent)
        }
        return false
    }

    /// "like" is droppable only when nothing marks it as content AND the source
    /// punctuation marks it as a disfluency ("Like, we should ship it"). A bare
    /// leading "like" is ambiguous ("Like button is broken"), so dropping it
    /// rejects and keeps the raw words. A filler merely sitting next to "like" does
    /// NOT make it droppable — "it tastes like um chicken" must keep its comparator
    /// "like" even though the filler "um" follows.
    private static func isDroppableLike(in tokens: [String], at index: Int, matchedContent: Bool) -> Bool {
        let previous = index > 0 ? tokens[index - 1] : nil
        let next = index + 1 < tokens.count ? tokens[index + 1] : nil

        if let previous, PolishVocabulary.semanticLikePrevious.contains(previous) { return false }
        if let next, PolishVocabulary.semanticLikeNext.contains(next) { return false }
        return !matchedContent
    }

    private static func isDroppableLike(
        in tokens: [String],
        raw: String,
        rawSpans: [TokenSpan],
        at index: Int,
        matchedContent: Bool
    ) -> Bool {
        isDroppableLike(in: tokens, at: index, matchedContent: matchedContent)
            && isCommaDelimitedDiscourseMarker(raw: raw, rawSpans: rawSpans, at: index)
    }

    private static func isCommaDelimitedDiscourseMarker(
        raw: String,
        rawSpans: [TokenSpan],
        at index: Int
    ) -> Bool {
        guard index + 1 < rawSpans.count else { return false }
        let gap = raw[rawSpans[index].range.upperBound..<rawSpans[index + 1].range.lowerBound]
        return gap.contains(",")
    }

    // MARK: Added/dropped symbols and punctuation

    /// Reject any change to the significant symbols the user dictated. Every
    /// significant glyph is preserved EXACTLY (count must not change):
    ///   • sentence punctuation (`? ! : ; — –`): adding one reframes the text
    ///     ("the error is timeout" → "the error is: timeout"); dropping or swapping
    ///     a dictated `?`/`!` for the exempt `.` inverts a question or command into a
    ///     statement ("is it broken?" → "is it broken.").
    ///   • content symbols (`/`, `--`, `$`, `(`, …): canonicalizer output present on
    ///     both sides — a silently dropped `--`/`/` and an invented one both reject.
    /// Two glyphs are exempt here and policed elsewhere:
    ///   • `.` — the recognizer routinely omits a trailing period and restoring it
    ///     does not change meaning; a mid-text `.` is policed by
    ///     `preservesRawSentenceBoundaries`.
    ///   • `,` — a comma may legitimately drop with a stranded filler but never be
    ///     added; all comma policy lives in `commaUsageIsJustified`, which is
    ///     positional (a count test cannot tell a *stranded* comma from a content
    ///     one), so this exact-count pass must not also touch it.
    private static func symbolUsageIsJustified(raw: String, polished: String) -> Bool {
        let rawCounts = significantSymbolCounts(raw)
        let polishedCounts = significantSymbolCounts(polished)
        for glyph in Set(rawCounts.keys).union(polishedCounts.keys) where glyph != "." && glyph != "," {
            if polishedCounts[glyph, default: 0] != rawCounts[glyph, default: 0] {
                return false
            }
        }
        return true
    }

    /// All comma policy, positional and PER-GAP. The matched content tokens partition
    /// both the raw and polished text into aligned gaps — before the first matched
    /// token, between each consecutive pair, and after the last. A hyphen-merge maps
    /// several raw tokens to one polished token, and the merge already verified those
    /// inner raw gaps are whitespace-only, so each DISTINCT polished token is one
    /// anchor spanning its contiguous raw token range. Every unmatched raw token in a
    /// gap is a dropped filler (an unmatched non-filler would have failed the match).
    /// Within each aligned gap:
    ///   • the polished comma count may not EXCEED the raw count — a comma is never
    ///     added, even at a boundary the model "improved" ("let's eat grandma" →
    ///     "let's eat, grandma" rejects); and
    ///   • the number of DROPPED commas may not exceed the number of dropped fillers
    ///     in that gap. Each disfluency is delimited by at most one comma (a bracketed
    ///     ",um," collapses to a single comma when the word goes), so one filler
    ///     licenses one comma drop — a content list/vocative comma that merely SHARES
    ///     a gap with a filler is not licensed ("buy milk, um, eggs" → "buy milk eggs"
    ///     rejects; the correct "buy milk, eggs" is accepted), and a comma stranded by
    ///     a *kept* word never drops ("a, b" → "a b" rejects).
    ///
    /// Comparing per gap, not per total, also rejects a count-neutral RELOCATION
    /// ("let's eat, grandma" → "let's, eat grandma") and stops a licensed drop in one
    /// gap from masking an illicit drop or addition in another ("a, b um, c" →
    /// "a b, c" rejects).
    private static func commaUsageIsJustified(
        raw: String,
        polished: String,
        rawSpans: [TokenSpan],
        polishedSpans: [TokenSpan],
        matches: [TokenMatch]
    ) -> Bool {
        // Collapse the matches into anchors: one per distinct polished token, spanning
        // the contiguous raw token indices it matched (>1 only for a hyphen-merge).
        var anchors: [(firstRaw: Int, lastRaw: Int, polLower: String.Index, polUpper: String.Index)] = []
        var cursor = 0
        while cursor < matches.count {
            let polishedIndex = matches[cursor].polishedIndex
            let firstRaw = matches[cursor].rawIndex
            var lastRaw = firstRaw
            while cursor < matches.count, matches[cursor].polishedIndex == polishedIndex {
                lastRaw = matches[cursor].rawIndex
                cursor += 1
            }
            anchors.append((
                firstRaw: firstRaw,
                lastRaw: lastRaw,
                polLower: polishedSpans[polishedIndex].range.lowerBound,
                polUpper: polishedSpans[polishedIndex].range.upperBound
            ))
        }
        guard !anchors.isEmpty else { return true }

        func commaCount(_ slice: Substring) -> Int { slice.filter { $0 == "," }.count }

        for gap in 0...anchors.count {
            // Dropped raw tokens (all fillers) in this gap = the raw indices strictly
            // between the bounding anchors (or before the first / after the last).
            let firstDropped = gap == 0 ? 0 : anchors[gap - 1].lastRaw + 1
            let lastDropped = gap == anchors.count ? rawSpans.count - 1 : anchors[gap].firstRaw - 1
            let droppedFillers = max(0, lastDropped - firstDropped + 1)

            let rawLower = gap == 0 ? raw.startIndex : rawSpans[anchors[gap - 1].lastRaw].range.upperBound
            let rawUpper = gap == anchors.count ? raw.endIndex : rawSpans[anchors[gap].firstRaw].range.lowerBound
            let polLower = gap == 0 ? polished.startIndex : anchors[gap - 1].polUpper
            let polUpper = gap == anchors.count ? polished.endIndex : anchors[gap].polLower

            let rawCommas = commaCount(raw[rawLower..<rawUpper])
            let polishedCommas = commaCount(polished[polLower..<polUpper])

            if polishedCommas > rawCommas { return false }
            if (rawCommas - polishedCommas) > droppedFillers { return false }
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

    private static func symbolDiffSummary(raw: String, polished: String) -> String {
        let rawCounts = significantSymbolCounts(raw)
        let polishedCounts = significantSymbolCounts(polished)
        let changed = Set(rawCounts.keys).union(polishedCounts.keys)
            .filter { $0 != "." && $0 != "," && rawCounts[$0, default: 0] != polishedCounts[$0, default: 0] }
            .sorted { symbolLabel($0) < symbolLabel($1) }
        let symbolDiffs = changed.prefix(6).map {
            "\(symbolLabel($0)):\(rawCounts[$0, default: 0])->\(polishedCounts[$0, default: 0])"
        }
        return [
            "changedSymbols=\(changed.count)",
            "symbolDiffs=\(symbolDiffs.joined(separator: ","))"
        ].joined(separator: " ")
    }

    private static func commaDiffSummary(raw: String, polished: String) -> String {
        [
            "rawCommas=\(raw.filter { $0 == "," }.count)",
            "polishedCommas=\(polished.filter { $0 == "," }.count)"
        ].joined(separator: " ")
    }

    private static func sentenceBoundaryDiffSummary(raw: String, polished: String) -> String {
        let rawCounts = sentenceBoundaryCounts(raw)
        let polishedCounts = sentenceBoundaryCounts(polished)
        let boundaryDiffs = [".", "?", "!"].map {
            "\($0):\(rawCounts[Character($0), default: 0])->\(polishedCounts[Character($0), default: 0])"
        }
        return "boundaryDiffs=\(boundaryDiffs.joined(separator: ","))"
    }

    private static func sentenceBoundaryCounts(_ text: String) -> [Character: Int] {
        var counts: [Character: Int] = [:]
        for character in text where character == "." || character == "?" || character == "!" {
            counts[character, default: 0] += 1
        }
        return counts
    }

    private static func symbolLabel(_ symbol: Character) -> String {
        switch symbol {
        case "?": return "question"
        case "!": return "exclamation"
        case ":": return "colon"
        case ";": return "semicolon"
        case "\u{2014}": return "em-dash"
        case "\u{2013}": return "en-dash"
        case "/": return "slash"
        case "-": return "hyphen"
        case "$": return "dollar"
        case "(": return "left-paren"
        case ")": return "right-paren"
        case "[": return "left-bracket"
        case "]": return "right-bracket"
        case "{": return "left-brace"
        case "}": return "right-brace"
        case "\u{2026}": return "ellipsis"
        default: return "other"
        }
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
