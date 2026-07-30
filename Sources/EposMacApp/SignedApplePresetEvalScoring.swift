#if DEBUG
import Foundation

struct WordErrorScore: Codable {
    let referenceWordCount: Int
    let comparedWordCount: Int
    let wordErrors: Int
    let substitutions: Int
    let insertions: Int
    let deletions: Int
    let wordErrorRate: Double
}

enum WordErrorScoring {
    static func score(reference: String, hypothesis: String) -> WordErrorScore {
        let reference = tokens(reference)
        let hypothesis = tokens(hypothesis)
        let final = cell(reference: reference, hypothesis: hypothesis)
        return WordErrorScore(
            referenceWordCount: reference.count,
            comparedWordCount: hypothesis.count,
            wordErrors: final.errors,
            substitutions: final.substitutions,
            insertions: final.insertions,
            deletions: final.deletions,
            wordErrorRate: Double(final.errors) / Double(max(reference.count, 1))
        )
    }

    private static func tokens(_ text: String) -> [String] {
        let lowercased = text.lowercased()
        let regex = try? NSRegularExpression(
            pattern: #"[$/]?[a-z0-9]+(?:[.'_-][a-z0-9]+)*|--+"#
        )
        let range = NSRange(lowercased.startIndex..<lowercased.endIndex, in: lowercased)
        return regex?.matches(in: lowercased, range: range).compactMap {
            Range($0.range, in: lowercased).map { String(lowercased[$0]) }
        } ?? []
    }

    private static func cell(reference: [String], hypothesis: [String]) -> WordErrorCell {
        var previous = (0...hypothesis.count).map {
            WordErrorCell(errors: $0, substitutions: 0, insertions: $0, deletions: 0)
        }
        for referenceIndex in reference.indices {
            var current = [
                WordErrorCell(
                    errors: referenceIndex + 1,
                    substitutions: 0,
                    insertions: 0,
                    deletions: referenceIndex + 1
                ),
            ]
            for hypothesisIndex in hypothesis.indices {
                if reference[referenceIndex] == hypothesis[hypothesisIndex] {
                    current.append(previous[hypothesisIndex])
                } else {
                    current.append([
                        previous[hypothesisIndex].addingSubstitution(),
                        previous[hypothesisIndex + 1].addingDeletion(),
                        current[hypothesisIndex].addingInsertion(),
                    ].min { $0.isPreferred(over: $1) }!)
                }
            }
            previous = current
        }
        return previous[hypothesis.count]
    }
}

private struct WordErrorCell {
    let errors: Int
    let substitutions: Int
    let insertions: Int
    let deletions: Int

    func isPreferred(over other: Self) -> Bool {
        if errors != other.errors { return errors < other.errors }
        if substitutions != other.substitutions { return substitutions < other.substitutions }
        if deletions != other.deletions { return deletions < other.deletions }
        return insertions < other.insertions
    }

    func addingSubstitution() -> Self {
        Self(
            errors: errors + 1,
            substitutions: substitutions + 1,
            insertions: insertions,
            deletions: deletions
        )
    }

    func addingInsertion() -> Self {
        Self(
            errors: errors + 1,
            substitutions: substitutions,
            insertions: insertions + 1,
            deletions: deletions
        )
    }

    func addingDeletion() -> Self {
        Self(
            errors: errors + 1,
            substitutions: substitutions,
            insertions: insertions,
            deletions: deletions + 1
        )
    }
}
#endif
