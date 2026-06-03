import Foundation
@testable import Epos

enum PolishEvalScoring {
    static func retainsFiller(_ text: String) -> Bool {
        let words = text.lowercased().split { !$0.isLetter }.map(String.init)
        return !PolishVocabulary.singleFillers.isDisjoint(with: Set(words))
    }

    static func wordErrorTokens(_ text: String) -> [String] {
        let lowercased = text.lowercased()
        let pattern = #"[$/]?[a-z0-9]+(?:[.'_-][a-z0-9]+)*|--+"#
        let regex = try? NSRegularExpression(pattern: pattern, options: [])
        let range = NSRange(lowercased.startIndex..<lowercased.endIndex, in: lowercased)
        return regex?.matches(in: lowercased, options: [], range: range).compactMap { match in
            guard let tokenRange = Range(match.range, in: lowercased) else { return nil }
            return String(lowercased[tokenRange])
        } ?? []
    }

    static func wordErrorScore(reference: String, hypothesis: String) -> TranscriptWordErrorScore {
        let referenceTokens = wordErrorTokens(reference)
        let hypothesisTokens = wordErrorTokens(hypothesis)
        let finalCell = wordErrorCell(reference: referenceTokens, hypothesis: hypothesisTokens)
        let denominator = max(referenceTokens.count, 1)
        let errorRate = Double(finalCell.errors) / Double(denominator)
        return TranscriptWordErrorScore(
            referenceWordCount: referenceTokens.count,
            comparedWordCount: hypothesisTokens.count,
            wordErrors: finalCell.errors,
            substitutions: finalCell.substitutions,
            insertions: finalCell.insertions,
            deletions: finalCell.deletions,
            wordErrorRate: errorRate,
            wordAccuracy: max(0, 1 - errorRate)
        )
    }

    private static func wordErrorCell(reference: [String], hypothesis: [String]) -> TranscriptWordErrorCell {
        var previous = (0...hypothesis.count).map {
            TranscriptWordErrorCell(errors: $0, substitutions: 0, insertions: $0, deletions: 0)
        }
        guard !reference.isEmpty else { return previous[hypothesis.count] }

        for refIndex in 1...reference.count {
            var current = [
                TranscriptWordErrorCell(errors: refIndex, substitutions: 0, insertions: 0, deletions: refIndex),
            ]
            guard !hypothesis.isEmpty else {
                previous = current
                continue
            }
            for hypIndex in 1...hypothesis.count {
                if reference[refIndex - 1] == hypothesis[hypIndex - 1] {
                    current.append(previous[hypIndex - 1])
                    continue
                }
                current.append([
                    previous[hypIndex - 1].addingSubstitution(),
                    previous[hypIndex].addingDeletion(),
                    current[hypIndex - 1].addingInsertion(),
                ].min(by: { $0.isPreferred(over: $1) })!)
            }
            previous = current
        }

        return previous[hypothesis.count]
    }
}

struct TranscriptWordErrorScore: Codable, Equatable {
    let referenceWordCount: Int
    let comparedWordCount: Int
    let wordErrors: Int
    let substitutions: Int
    let insertions: Int
    let deletions: Int
    let wordErrorRate: Double
    let wordAccuracy: Double
}

private struct TranscriptWordErrorCell: Equatable {
    let errors: Int
    let substitutions: Int
    let insertions: Int
    let deletions: Int

    func addingSubstitution() -> TranscriptWordErrorCell {
        TranscriptWordErrorCell(
            errors: errors + 1,
            substitutions: substitutions + 1,
            insertions: insertions,
            deletions: deletions
        )
    }

    func addingInsertion() -> TranscriptWordErrorCell {
        TranscriptWordErrorCell(
            errors: errors + 1,
            substitutions: substitutions,
            insertions: insertions + 1,
            deletions: deletions
        )
    }

    func addingDeletion() -> TranscriptWordErrorCell {
        TranscriptWordErrorCell(
            errors: errors + 1,
            substitutions: substitutions,
            insertions: insertions,
            deletions: deletions + 1
        )
    }

    func isPreferred(over other: TranscriptWordErrorCell) -> Bool {
        if errors != other.errors { return errors < other.errors }
        if substitutions != other.substitutions { return substitutions < other.substitutions }
        if deletions != other.deletions { return deletions < other.deletions }
        return insertions < other.insertions
    }
}
