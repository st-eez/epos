#if DEBUG
import Foundation

enum ReferenceDesignation: String, Codable {
    case legacy
    case holdout
}

/// The human-confirmed slice of the v2 evaluation-corpus ledger written by
/// `scripts/corpus`. Inferred and unlabeled rows are never reference text.
struct ConfirmedEvalCorpus {
    static let schemaVersion = 2
    static let expectedLegacyRows = 35
    static let expectedHoldoutRows = 40

    struct Entry {
        let file: String
        let audioSHA256: String
        let reference: String
        let designation: ReferenceDesignation
    }

    let entries: [Entry]

    static func load(from url: URL) throws -> Self {
        guard let body = try? String(contentsOf: url, encoding: .utf8) else {
            throw EvalCorpusError.unreadable(url.path)
        }
        let decoder = JSONDecoder()
        var entries: [Entry] = []
        var seenFiles: Set<String> = []
        for (offset, rawLine) in body.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let lineNumber = offset + 1
            guard let row = try? decoder.decode(LedgerRow.self, from: Data(line.utf8)) else {
                throw EvalCorpusError.invalidRow(url.path, lineNumber)
            }
            guard row.schemaVersion == schemaVersion else {
                throw EvalCorpusError.unsupportedSchema(url.path, lineNumber)
            }
            guard row.verificationStatus == "human_confirmed" else { continue }
            let entry = try entry(from: row, path: url.path, lineNumber: lineNumber)
            guard seenFiles.insert(entry.file).inserted else {
                throw EvalCorpusError.duplicateFile(entry.file)
            }
            entries.append(entry)
        }
        let corpus = Self(entries: entries.sorted { $0.file < $1.file })
        try corpus.validateConfirmedShape()
        return corpus
    }

    func count(of designation: ReferenceDesignation) -> Int {
        entries.filter { $0.designation == designation }.count
    }

    private func validateConfirmedShape() throws {
        let legacy = count(of: .legacy)
        let holdout = count(of: .holdout)
        guard legacy == Self.expectedLegacyRows, holdout == Self.expectedHoldoutRows else {
            throw EvalCorpusError.confirmedShape(legacy: legacy, holdout: holdout)
        }
    }

    private static func entry(
        from row: LedgerRow,
        path: String,
        lineNumber: Int
    ) throws -> Entry {
        let file = row.file.trimmingCharacters(in: .whitespacesAndNewlines)
        let reference = (row.transcriptCandidate ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSafeRecordingFilename(file),
              isLowercaseSHA256(row.audioSHA256),
              !reference.isEmpty else {
            throw EvalCorpusError.invalidRow(path, lineNumber)
        }
        return Entry(
            file: file,
            audioSHA256: row.audioSHA256,
            reference: reference,
            designation: try designation(from: row, path: path, lineNumber: lineNumber)
        )
    }

    /// A legacy confirmation carries its manifest ordinal; a holdout confirmation
    /// has no ordinal and must say so explicitly.
    private static func designation(
        from row: LedgerRow,
        path: String,
        lineNumber: Int
    ) throws -> ReferenceDesignation {
        if row.legacyOrdinal != nil {
            guard row.designation == nil || row.designation == ReferenceDesignation.legacy.rawValue
            else {
                throw EvalCorpusError.invalidRow(path, lineNumber)
            }
            return .legacy
        }
        guard row.designation == ReferenceDesignation.holdout.rawValue else {
            throw EvalCorpusError.invalidRow(path, lineNumber)
        }
        return .holdout
    }

    private static func isSafeRecordingFilename(_ file: String) -> Bool {
        (file as NSString).lastPathComponent == file
            && !file.hasPrefix(".")
            && file.lowercased().hasSuffix(".wav")
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}

private struct LedgerRow: Decodable {
    let schemaVersion: Int
    let file: String
    let audioSHA256: String
    let transcriptCandidate: String?
    let verificationStatus: String
    let legacyOrdinal: Int?
    let designation: String?
}

enum EvalCorpusError: Error, CustomStringConvertible {
    case unreadable(String)
    case invalidRow(String, Int)
    case unsupportedSchema(String, Int)
    case duplicateFile(String)
    case confirmedShape(legacy: Int, holdout: Int)

    var description: String {
        switch self {
        case .unreadable(let path):
            "evaluation corpus not readable: \(path)"
        case .invalidRow(let path, let line):
            "invalid evaluation corpus row at \(path):\(line)"
        case .unsupportedSchema(let path, let line):
            "evaluation corpus row at \(path):\(line) is not schemaVersion "
                + "\(ConfirmedEvalCorpus.schemaVersion)"
        case .duplicateFile(let file):
            "duplicate evaluation corpus file: \(file)"
        case .confirmedShape(let legacy, let holdout):
            "confirmed corpus must hold exactly \(ConfirmedEvalCorpus.expectedLegacyRows) legacy "
                + "and \(ConfirmedEvalCorpus.expectedHoldoutRows) holdout rows, "
                + "found \(legacy) legacy and \(holdout) holdout"
        }
    }
}
#endif
