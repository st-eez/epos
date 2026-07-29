import Foundation

/// A tiny, deterministic cleanup pass restricted to transforms that provably keep
/// every content word: hard filler tokens, stuttered function-word repeats, and
/// exact standalone numeric ordinal formatting. It deliberately does not remove
/// ambiguous phrase fillers such as "you know", bare `like`/`so`, or reflow grammar —
/// broader edits were measured against local LLM polish and rejected (see
/// `specs/polish-model-benchmark.md`).
public enum TranscriptDeterministicCleaner {
    /// Single-token disfluencies this pass may drop. Deliberately MINIMAL: only the
    /// pure non-words with no content sense. `so` and `like` are excluded because
    /// their spoken uses are ambiguous content ("so we shipped it", "seems like"),
    /// and "basically" because it is a content-bearing degree adverb
    /// ("basically identical" != "identical"). Multi-token phrases ("you know",
    /// "kind of", …) are likewise not droppable: each has a common content use this
    /// pass cannot distinguish from a verbal tic.
    static let hardFillers: Set<String> = ["um", "uh", "er", "hmm"]

    /// The conservative disfluency pass applied to every streamed partial/final and
    /// to the canonicalized final transcript: strip hard fillers, collapse stuttered
    /// function-word repeats, then spell standalone numeric ordinals.
    public static func streamClean(_ canonicalized: String) -> String {
        normalizeNumericOrdinals(
            collapseAdjacentDuplicates(stripStandaloneFillers(canonicalized))
        )
    }

    /// Removes ONLY standalone hard fillers (`um`/`uh`/`er`/`hmm`) and the comma
    /// that punctuated each — nothing else.
    static func stripStandaloneFillers(_ text: String) -> String {
        let segments = Self.segments(from: text)
        var removed: Set<Int> = []
        for (index, segment) in segments.enumerated() where segment.isWord {
            guard let normalized = segment.normalized else { continue }
            if hardFillers.contains(normalized), !isAcronym(segment.text) {
                removed.insert(index)
            }
        }
        guard !removed.isEmpty else { return text }
        return apply(removed: removed, replacements: [:], to: segments)
    }

    private static func normalizeNumericOrdinals(_ text: String) -> String {
        let segments = Self.segments(from: text)
        var replacements: [Int: String] = [:]
        for (index, segment) in segments.enumerated() where segment.isWord {
            guard let normalized = segment.normalized,
                  let ordinal = ordinalWord(forNumericOrdinal: normalized) else {
                continue
            }
            replacements[index] = ordinal
        }
        guard !replacements.isEmpty else { return text }
        return apply(removed: [], replacements: replacements, to: segments)
    }

    /// Collapses an immediately-repeated function word (case-insensitive, whitespace-only
    /// gap) to a single occurrence — the common spoken stutter "the the"/"and and". Restricted
    /// to a closed allow-list (`safeDuplicateWords`) of words whose doubling is ALWAYS
    /// disfluency: it deliberately will NOT touch a content word (can't tell a stutter
    /// "build build" from emphasis without parsing), the valid grammatical doublings
    /// "had had"/"that that", emphatic reduplication ("very very", "so so"), or a
    /// comma-separated repeat. It also skips a pair where EITHER token is an acronym, so an
    /// acronym beside its lowercase homonym is preserved ("the OR or the ICU" keeps the
    /// conjunction) — matching `stripStandaloneFillers`. Like that pass it is safe on volatile
    /// partials and is applied via `streamClean` to both the streamed text and the final
    /// transcript, so a collapsed stutter never flickers back on screen at finalization.
    /// Missing a stutter is harmless; collapsing a real repeat would change meaning, so the
    /// set stays conservative.
    static func collapseAdjacentDuplicates(_ text: String) -> String {
        let segments = Self.segments(from: text)
        var removed: Set<Int> = []
        var previousWord: (index: Int, normalized: String)?
        for (index, segment) in segments.enumerated() where segment.isWord {
            guard let normalized = segment.normalized else { continue }
            if let previous = previousWord,
               previous.normalized == normalized,
               safeDuplicateWords.contains(normalized),
               !isAcronym(segment.text),
               !isAcronym(segments[previous.index].text),
               gapBetweenWordsIsWhitespace(previous.index, index, in: segments) {
                removed.insert(index)
            }
            previousWord = (index, normalized)
        }
        guard !removed.isEmpty else { return text }
        // Keep a comma the user dictated after the stutter: the removed segment is the
        // duplicate copy, and its trailing comma belongs to the kept word.
        return apply(removed: removed, replacements: [:], to: segments, dropTrailingCommaAfterRemoved: false)
    }

    /// Words whose immediate repetition is ALWAYS a spoken stutter — never valid grammar
    /// ("had had", "that that"), never emphatic reduplication ("very very", "so so",
    /// "no no"). Closed and conservative on purpose: a missed stutter is harmless, a wrongly
    /// collapsed real repeat is a meaning change. Excludes "so" (the "so-so" idiom) and the
    /// grammatical doublers by omission. It excludes the phrasal-verb particles "in" and "on",
    /// whose doubling is a legitimate particle+preposition juncture, not a stutter ("log in in
    /// the morning", "turn it on on Monday"); the remaining prepositions (to/of/at/for) have
    /// no such juncture so their doubling is always a stutter. It also excludes the copulas
    /// (is/was/are/were): the cleft construction "[what X is] is Y" ("what it is is important",
    /// "all it was was luck") is a real double-copula, not a stutter.
    private static let safeDuplicateWords: Set<String> = [
        "the", "a", "an", "to", "of", "at", "for", "and", "or", "but",
        "we", "it", "they", "i",
    ]

    /// Drops `removed` segments and substitutes `replacements`, then renormalizes
    /// whitespace and commas. When `dropTrailingCommaAfterRemoved` is true (the filler
    /// passes) a comma directly trailing a removed segment is dropped too — it punctuated
    /// the disfluency, not the kept word. The dedup pass passes false: there the removed
    /// segment is the SECOND copy of a real, kept word, so a comma after it is the user's
    /// punctuation on that word ("the the, report" → "the, report", not "the report").
    private static func apply(
        removed: Set<Int>,
        replacements: [Int: String],
        to segments: [Segment],
        dropTrailingCommaAfterRemoved: Bool = true
    ) -> String {
        // A comma directly trailing a removed filler punctuated the disfluency, not
        // the preceding kept word — drop it with the filler. Leaving it would let
        // whitespace normalization transplant it onto the kept word ("let's eat um,
        // grandma" → "let's eat, grandma"), inventing a pause the user never spoke.
        // A comma BEFORE the filler belongs to the kept word and stays
        // ("I want, um, apples" → "I want, apples").
        var gapReplacements: [Int: String] = [:]
        if dropTrailingCommaAfterRemoved {
            for index in removed {
                let gapIndex = segments.index(after: index)
                guard gapIndex < segments.endIndex, !segments[gapIndex].isWord else { continue }
                let gapText = gapReplacements[gapIndex] ?? segments[gapIndex].text
                if let comma = gapText.firstIndex(of: ",") {
                    gapReplacements[gapIndex] = String(gapText[..<comma]) + String(gapText[gapText.index(after: comma)...])
                }
            }
        }
        let stripped = segments
            .enumerated()
            .map { index, segment in
                if removed.contains(index) { return "" }
                return gapReplacements[index] ?? replacements[index] ?? segment.text
            }
            .joined()
        return normalizeWhitespaceAndCommas(stripped)
    }

    private struct Segment {
        let text: String
        let normalized: String?

        var isWord: Bool { normalized != nil }
    }

    private static func segments(from text: String) -> [Segment] {
        var segments: [Segment] = []
        var current = ""
        var currentIsWord: Bool?
        var index = text.startIndex

        func flush() {
            guard !current.isEmpty else { return }
            if currentIsWord == true {
                segments.append(Segment(text: current, normalized: normalizeToken(current)))
            } else {
                segments.append(Segment(text: current, normalized: nil))
            }
            current = ""
            currentIsWord = nil
        }

        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            let isWordCharacter = isAlphanumeric(character)
                || (
                    isConnector(character)
                        && currentIsWord == true
                        && next < text.endIndex
                        && isAlphanumeric(text[next])
                )

            if let currentIsWord, currentIsWord != isWordCharacter {
                flush()
            }
            currentIsWord = isWordCharacter
            current.append(character)
            index = next
        }
        flush()
        return segments
    }

    private static func normalizeWhitespaceAndCommas(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+([,.;:?!])"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"(,\s*){2,}"#, with: ", ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",")))
    }

    private static func normalizeToken(_ raw: String) -> String {
        raw.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
    }

    private static func isAlphanumeric(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
    }

    private static func isConnector(_ character: Character) -> Bool {
        character == "'" || character == "\u{2019}" || character == "-" || character == "."
    }

    private static func isAcronym(_ token: String) -> Bool {
        token.count > 1 && token == token.uppercased() && token != token.lowercased()
    }

    private static func gapBetweenWordsIsWhitespace(
        _ leftIndex: Int,
        _ rightIndex: Int,
        in segments: [Segment]
    ) -> Bool {
        guard leftIndex < rightIndex else { return false }
        let gapStart = segments.index(after: leftIndex)
        guard gapStart < rightIndex else { return true }
        return segments[gapStart..<rightIndex].allSatisfy { !$0.isWord && $0.text.allSatisfy(\.isWhitespace) }
    }

    private static func ordinalWord(forNumericOrdinal token: String) -> String? {
        let normalized = token.lowercased()
        let numberPart = normalized.prefix { $0.isNumber }
        let suffix = normalized.dropFirst(numberPart.count)
        guard !numberPart.isEmpty,
              !suffix.isEmpty,
              numberPart.count + suffix.count == normalized.count,
              let number = Int(numberPart),
              suffix == expectedOrdinalSuffix(for: number) else {
            return nil
        }
        return ordinalWordByNumber[number]
    }

    private static func expectedOrdinalSuffix(for number: Int) -> String {
        let lastTwo = number % 100
        if (11...13).contains(lastTwo) {
            return "th"
        }

        switch number % 10 {
        case 1: return "st"
        case 2: return "nd"
        case 3: return "rd"
        default: return "th"
        }
    }

    private static let ordinalWordByNumber: [Int: String] = [
        1: "first", 2: "second", 3: "third", 4: "fourth", 5: "fifth", 6: "sixth", 7: "seventh",
        8: "eighth", 9: "ninth", 10: "tenth", 11: "eleventh", 12: "twelfth", 13: "thirteenth",
        14: "fourteenth", 15: "fifteenth", 16: "sixteenth", 17: "seventeenth", 18: "eighteenth",
        19: "nineteenth", 20: "twentieth", 21: "twenty-first", 22: "twenty-second",
        23: "twenty-third", 24: "twenty-fourth", 25: "twenty-fifth", 26: "twenty-sixth",
        27: "twenty-seventh", 28: "twenty-eighth", 29: "twenty-ninth", 30: "thirtieth",
        31: "thirty-first",
    ]
}
