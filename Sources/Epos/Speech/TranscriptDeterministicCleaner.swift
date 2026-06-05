import Foundation

/// A tiny, deterministic cleanup pass for transforms the retention guard can prove:
/// hard filler tokens, comma-delimited opening `so`/`like`, exact standalone
/// numeric ordinal formatting, and the measured `seems to getting` grammar miss.
/// It deliberately does not remove ambiguous phrase fillers such as "you know"
/// or bare `like`/`so`.
enum TranscriptDeterministicCleaner {
    static func clean(_ text: String) -> String {
        let segments = Self.segments(from: text)
        var removed: Set<Int> = []
        var replacements: [Int: String] = [:]

        for (index, segment) in segments.enumerated() where segment.isWord {
            guard let normalized = segment.normalized else { continue }
            if PolishVocabulary.singleFillers.contains(normalized), !isAcronym(segment.text) {
                removed.insert(index)
            } else if let ordinalWord = ordinalWord(forNumericOrdinal: normalized) {
                replacements[index] = ordinalWord
            } else if normalized == "getting", isMissingBeBeforeGetting(at: index, in: segments) {
                replacements[index] = "be getting"
            }
        }

        while let leadingIndex = firstKeptWordIndex(in: segments, removed: removed),
              let normalized = segments[leadingIndex].normalized,
              (normalized == "so" || normalized == "like"),
              gapAfterWordContainsComma(leadingIndex, in: segments, removed: removed) {
            removed.insert(leadingIndex)
        }

        guard !removed.isEmpty || !replacements.isEmpty else { return text }
        // A comma directly trailing a removed filler punctuated the disfluency, not
        // the preceding kept word — drop it with the filler. Leaving it would let
        // whitespace normalization transplant it onto the kept word ("let's eat um,
        // grandma" → "let's eat, grandma"), inventing a pause the user never spoke.
        // A comma BEFORE the filler belongs to the kept word and stays
        // ("I want, um, apples" → "I want, apples").
        var gapReplacements: [Int: String] = [:]
        for index in removed {
            let gapIndex = segments.index(after: index)
            guard gapIndex < segments.endIndex, !segments[gapIndex].isWord else { continue }
            let gapText = gapReplacements[gapIndex] ?? segments[gapIndex].text
            if let comma = gapText.firstIndex(of: ",") {
                gapReplacements[gapIndex] = String(gapText[..<comma]) + String(gapText[gapText.index(after: comma)...])
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

    private static func firstKeptWordIndex(in segments: [Segment], removed: Set<Int>) -> Int? {
        segments.indices.first { segments[$0].isWord && !removed.contains($0) }
    }

    private static func gapAfterWordContainsComma(
        _ wordIndex: Int,
        in segments: [Segment],
        removed: Set<Int>
    ) -> Bool {
        var index = segments.index(after: wordIndex)
        while index < segments.endIndex {
            let segment = segments[index]
            if segment.isWord && !removed.contains(index) { return false }
            if !segment.isWord && segment.text.contains(",") { return true }
            index = segments.index(after: index)
        }
        return false
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

    private static func isMissingBeBeforeGetting(at index: Int, in segments: [Segment]) -> Bool {
        guard let previousIndex = previousWordIndex(before: index, in: segments),
              segments[previousIndex].normalized == "to",
              let seemIndex = previousWordIndex(before: previousIndex, in: segments),
              ["seem", "seems", "seemed"].contains(segments[seemIndex].normalized ?? ""),
              gapBetweenWordsIsWhitespace(seemIndex, previousIndex, in: segments),
              gapBetweenWordsIsWhitespace(previousIndex, index, in: segments) else {
            return false
        }
        return true
    }

    private static func previousWordIndex(before index: Int, in segments: [Segment]) -> Int? {
        guard index > segments.startIndex else { return nil }
        return segments[..<index].indices.reversed().first { segments[$0].isWord }
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
