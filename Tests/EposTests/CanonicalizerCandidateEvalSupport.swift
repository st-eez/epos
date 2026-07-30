import Foundation
@testable import Epos

struct CandidateCorpusRow: Decodable {
    let arm: String
    let file: String
    let referenceDesignation: CandidateSlice
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

enum CandidateCorpus {
    static let expectedDevelopmentRows = 35
    static let expectedHoldoutRows = 40

    static func validate(rows: [CandidateCorpusRow]) throws {
        let development = rows.filter { $0.referenceDesignation == .development }.count
        let holdout = rows.filter { $0.referenceDesignation == .holdout }.count
        guard development == expectedDevelopmentRows,
              holdout == expectedHoldoutRows,
              Set(rows.map(\.file)).count == rows.count,
              rows.allSatisfy({
                  $0.error == nil
                      && !$0.transcript.isEmpty
                      && !$0.humanIntendedTranscript.isEmpty
              }) else {
            throw CandidateEvalError.invalidCorpus
        }
    }
}

/// The artifact's reference designation is the slice: legacy rows developed the
/// correction layer, holdout rows only ever judge it.
enum CandidateSlice: String, Decodable {
    case development = "legacy"
    case holdout
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
        baseline: String,
        variant: String
    ) {
        self.file = row.file
        self.intended = row.humanIntendedTranscript
        self.raw = row.transcript
        self.slice = row.referenceDesignation
        self.baseline = baseline
        self.variant = variant
        self.before = TranscriptEvalScoring.wordErrorScore(
            reference: row.humanIntendedTranscript,
            hypothesis: baseline
        )
        self.after = TranscriptEvalScoring.wordErrorScore(
            reference: row.humanIntendedTranscript,
            hypothesis: variant
        )
    }

    static func synthetic(slice: CandidateSlice, before: Int, after: Int) -> Self {
        Self(
            row: CandidateCorpusRow(
                arm: "speech-progressive-fast",
                file: "synthetic.wav",
                referenceDesignation: slice,
                humanIntendedTranscript: "right",
                transcript: "wrong",
                error: nil
            ),
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

    var developmentRegressions: Int {
        evaluations.filter { $0.slice == .development && $0.delta > 0 }.count
    }

    var holdoutRegressions: Int {
        evaluations.filter { $0.slice == .holdout && $0.delta > 0 }.count
    }

    var holdoutWins: Int {
        evaluations.filter { $0.slice == .holdout && $0.delta < 0 }.count
    }

    var confirmedHoldoutRows: Int {
        evaluations.filter { $0.slice == .holdout }.count
    }

    var baselineWordErrors: Int {
        evaluations.reduce(0) { $0 + $1.before.wordErrors }
    }

    var variantWordErrors: Int {
        evaluations.reduce(0) { $0 + $1.after.wordErrors }
    }

    var baselineExactRows: Int {
        evaluations.filter { $0.before.wordErrors == 0 }.count
    }

    var variantExactRows: Int {
        evaluations.filter { $0.after.wordErrors == 0 }.count
    }

    var passes: Bool {
        !changed.isEmpty &&
            confirmedHoldoutRows > 0 &&
            developmentRegressions == 0 &&
            holdoutRegressions == 0 &&
            holdoutWins > 0
    }

    func report(candidates: [CorrectionRecord], artifact: URL) -> String {
        var lines = [
            "",
            "Correction candidate eval",
            "  candidates: \(candidates.map(\.id).joined(separator: ", "))",
            "  artifact: \(artifact.lastPathComponent)",
            "  changed rows: \(changed.count)",
            "  confirmed word errors: \(baselineWordErrors)->\(variantWordErrors)",
            "  confirmed exact rows: \(baselineExactRows)->\(variantExactRows)",
            "  confirmed development regressions: \(developmentRegressions)",
            "  confirmed holdout rows: \(confirmedHoldoutRows)",
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
