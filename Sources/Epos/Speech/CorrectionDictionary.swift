import Foundation

public struct CorrectionDictionary: Equatable, Sendable {
    public var records: [CorrectionRecord]

    public init(records: [CorrectionRecord] = Self.defaultRecords) {
        self.records = records
    }

    public static let defaultRecords: [CorrectionRecord] = TranscriptCanonicalizer.defaultRules.enumerated().map {
        index, rule in
        CorrectionRecord(
            id: Self.defaultRecordID(index: index, canonical: rule.canonical),
            kind: .replacement,
            canonical: rule.canonical,
            aliases: rule.aliases,
            contexts: rule.contexts,
            source: .builtIn,
            status: .active
        )
    }

    private static func defaultRecordID(index: Int, canonical: String) -> String {
        let slug = canonical
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: "-")
        let suffix = slug.isEmpty ? "symbol" : slug
        return "builtin.\(index).\(suffix)"
    }
}

public struct CorrectionRecord: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Equatable, Sendable {
        case lexicon
        case replacement
        case snippet
        case spokenCommand
        case formattingPolicy
    }

    public enum Source: String, Codable, Equatable, Sendable {
        case builtIn
        case manual
        case suggested
        case imported
        case mined
    }

    public enum Status: String, Codable, Equatable, Sendable {
        case active
        case disabled
        case suggested
        case rejected
    }

    public var id: String
    public var kind: Kind
    public var canonical: String
    public var aliases: [String]
    public var contexts: [String]
    public var source: Source
    public var status: Status

    public init(
        id: String,
        kind: Kind,
        canonical: String,
        aliases: [String] = [],
        contexts: [String] = [],
        source: Source,
        status: Status
    ) {
        self.id = id
        self.kind = kind
        self.canonical = canonical
        self.aliases = aliases
        self.contexts = contexts
        self.source = source
        self.status = status
    }
}
