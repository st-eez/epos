import Foundation

/// A tiny, deterministic cleanup pass for transforms the retention guard can prove:
/// hard filler tokens plus comma-delimited opening `so`/`like`. It deliberately does
/// not remove ambiguous phrase fillers such as "you know" or bare `like`/`so`.
enum TranscriptDeterministicCleaner {
    static func clean(_ text: String) -> String {
        let segments = Self.segments(from: text)
        var removed: Set<Int> = []

        for (index, segment) in segments.enumerated() where segment.isWord {
            guard let normalized = segment.normalized else { continue }
            if PolishVocabulary.singleFillers.contains(normalized), !isAcronym(segment.text) {
                removed.insert(index)
            }
        }

        while let leadingIndex = firstKeptWordIndex(in: segments, removed: removed),
              let normalized = segments[leadingIndex].normalized,
              (normalized == "so" || normalized == "like"),
              gapAfterWordContainsComma(leadingIndex, in: segments, removed: removed) {
            removed.insert(leadingIndex)
        }

        guard !removed.isEmpty else { return text }
        let stripped = segments
            .enumerated()
            .map { removed.contains($0.offset) ? "" : $0.element.text }
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
}
