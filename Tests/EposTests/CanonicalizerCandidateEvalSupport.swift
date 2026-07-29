import Foundation
@testable import Epos

struct CandidateCorpusRow: Decodable {
    let arm: String
    let file: String
    let humanIntendedTranscript: String
    let transcript: String
    let error: String?

    static func loadProductionArm(_ url: URL) throws -> [Self] {
        let decoder = JSONDecoder()
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .map { try decoder.decode(Self.self, from: Data($0.utf8)) }
            .filter { $0.arm == "speech-progressive-fast" }
    }
}

struct CandidateCorpusManifest {
    private struct Row: Decodable {
        let file: String
        let humanIntendedTranscript: String
    }

    let orderedFiles: [String]
    let transcripts: [String: String]

    static func load(_ url: URL) throws -> Self {
        let decoder = JSONDecoder()
        let rows = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .map { try decoder.decode(Row.self, from: Data($0.utf8)) }
        return Self(
            orderedFiles: rows.map(\.file),
            transcripts: Dictionary(uniqueKeysWithValues: rows.map {
                ($0.file, $0.humanIntendedTranscript)
            })
        )
    }

    func slice(for file: String) -> CandidateSlice {
        orderedFiles.firstIndex(of: file).map { $0 < 80 ? .baseline : .holdout } ?? .unknown
    }
}

enum CandidateCorpus {
    static func validate(rows: [CandidateCorpusRow], manifest: CandidateCorpusManifest) throws {
        guard manifest.orderedFiles.count == 114,
              Set(manifest.orderedFiles).count == 114,
              rows.count == 114,
              Set(rows.map(\.file)).count == 114,
              Set(rows.map(\.file)) == Set(manifest.orderedFiles),
              rows.allSatisfy({ $0.error == nil && !$0.transcript.isEmpty }),
              rows.allSatisfy({
                  manifest.transcripts[$0.file] == $0.humanIntendedTranscript
              }) else {
            throw CandidateEvalError.invalidCorpus
        }
    }
}

enum CandidateSlice: String {
    case baseline
    case holdout
    case unknown
}

struct CandidateEvaluation {
    let file: String
    let intended: String
    let raw: String
    let slice: CandidateSlice
    let baseline: String
    let variant: String
    let before: TranscriptWordErrorScore
    let after: TranscriptWordErrorScore

    init(
        row: CandidateCorpusRow,
        slice: CandidateSlice,
        baseline: String,
        variant: String
    ) {
        self.file = row.file
        self.intended = row.humanIntendedTranscript
        self.raw = row.transcript
        self.slice = slice
        self.baseline = baseline
        self.variant = variant
        self.before = PolishEvalScoring.wordErrorScore(
            reference: row.humanIntendedTranscript,
            hypothesis: baseline
        )
        self.after = PolishEvalScoring.wordErrorScore(
            reference: row.humanIntendedTranscript,
            hypothesis: variant
        )
    }

    static func synthetic(slice: CandidateSlice, before: Int, after: Int) -> Self {
        let row = CandidateCorpusRow(
            arm: "speech-progressive-fast",
            file: "synthetic.wav",
            humanIntendedTranscript: "right",
            transcript: "wrong",
            error: nil
        )
        return Self(
            row: row,
            slice: slice,
            baseline: before == 0 ? "right" : "wrong",
            variant: after == 0 ? "right" : "wrong"
        )
    }

    var delta: Int {
        after.wordErrors - before.wordErrors
    }
}

struct CandidateVerdict {
    let evaluations: [CandidateEvaluation]

    var changed: [CandidateEvaluation] {
        evaluations.filter { $0.baseline != $0.variant }
    }

    var baselineRegressions: Int {
        evaluations.filter { $0.slice == .baseline && $0.delta > 0 }.count
    }

    var holdoutRegressions: Int {
        evaluations.filter { $0.slice == .holdout && $0.delta > 0 }.count
    }

    var holdoutWins: Int {
        evaluations.filter { $0.slice == .holdout && $0.delta < 0 }.count
    }

    var passes: Bool {
        !changed.isEmpty && baselineRegressions == 0 && holdoutRegressions == 0 && holdoutWins > 0
    }

    func report(candidates: [CorrectionRecord], artifact: URL) -> String {
        var lines = [
            "",
            "Correction candidate eval",
            "  candidates: \(candidates.map(\.id).joined(separator: ", "))",
            "  artifact: \(artifact.lastPathComponent)",
            "  changed rows: \(changed.count)",
            "  baseline regressions: \(baselineRegressions)",
            "  holdout wins/regressions: \(holdoutWins)/\(holdoutRegressions)",
            "  verdict: \(passes ? "PASS" : "REJECT")",
        ]
        for item in changed {
            lines.append(
                "  [\(item.slice.rawValue)] \(item.file) errors "
                    + "\(item.before.wordErrors)->\(item.after.wordErrors) delta=\(item.delta)"
            )
            lines.append("    raw: \(item.raw)")
            lines.append("    intended: \(item.intended)")
            lines.append("    before: \(item.baseline)")
            lines.append("    after: \(item.variant)")
        }
        return lines.joined(separator: "\n")
    }
}

enum CandidateEvalError: Error, Equatable {
    case invalidCorpus
    case emptyCandidate
    case inactiveCandidate
    case duplicateCandidateID
    case candidateIDCollidesWithBuiltIn
}

enum CandidatePayload: Decodable {
    case one(CorrectionRecord)
    case many([CorrectionRecord])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let records = try? container.decode([CorrectionRecord].self) {
            self = .many(records)
        } else {
            self = .one(try container.decode(CorrectionRecord.self))
        }
    }

    var records: [CorrectionRecord] {
        switch self {
        case .one(let record): [record]
        case .many(let records): records
        }
    }

    static func validate(_ records: [CorrectionRecord]) throws {
        guard !records.isEmpty else {
            throw CandidateEvalError.emptyCandidate
        }
        guard records.allSatisfy({ $0.status == .active }) else {
            throw CandidateEvalError.inactiveCandidate
        }
        let candidateIDs = Set(records.map(\.id))
        guard candidateIDs.count == records.count else {
            throw CandidateEvalError.duplicateCandidateID
        }
        let builtInIDs = Set(CorrectionDictionary.defaultRecords.map(\.id))
        guard candidateIDs.isDisjoint(with: builtInIDs) else {
            throw CandidateEvalError.candidateIDCollidesWithBuiltIn
        }
    }
}
