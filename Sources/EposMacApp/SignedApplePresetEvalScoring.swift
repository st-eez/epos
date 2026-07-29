#if DEBUG
import Foundation

struct GroundTruthManifest {
    private let transcriptsByFile: [String: String]

    static func load(from url: URL) throws -> Self {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw GroundTruthError.notFound(url.path)
        }
        let body = try String(contentsOf: url, encoding: .utf8)
        let decoder = JSONDecoder()
        var transcripts: [String: String] = [:]
        for (offset, rawLine) in body.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            do {
                let row = try decoder.decode(GroundTruthRow.self, from: Data(line.utf8))
                let file = row.file.trimmingCharacters(in: .whitespacesAndNewlines)
                let transcript = row.humanIntendedTranscript
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !file.isEmpty, !transcript.isEmpty, transcripts[file] == nil else {
                    throw GroundTruthError.invalidRow(url.path, offset + 1)
                }
                transcripts[file] = transcript
            } catch {
                throw GroundTruthError.invalidRow(url.path, offset + 1)
            }
        }
        return Self(transcriptsByFile: transcripts)
    }

    func transcript(for recording: URL) -> String? {
        transcriptsByFile[recording.lastPathComponent]
    }
}

private struct GroundTruthRow: Decodable {
    let file: String
    let humanIntendedTranscript: String
}

private enum GroundTruthError: Error, CustomStringConvertible {
    case invalidRow(String, Int)
    case notFound(String)

    var description: String {
        switch self {
        case .invalidRow(let path, let line):
            "invalid or duplicate ground-truth row at \(path):\(line)"
        case .notFound(let path):
            "ground-truth manifest not found: \(path)"
        }
    }
}

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
