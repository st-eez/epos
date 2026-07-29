import Foundation

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

    public enum LexiconClass: String, Codable, Equatable, Sendable {
        case generic
        case person
    }

    public var id: String
    public var kind: Kind
    public var canonical: String
    public var aliases: [String]
    public var ambiguousAliases: [String]
    public var contexts: [String]
    public var lexiconClass: LexiconClass
    public var source: Source
    public var status: Status

    public init(
        id: String,
        kind: Kind,
        canonical: String,
        aliases: [String] = [],
        ambiguousAliases: [String] = [],
        contexts: [String] = [],
        lexiconClass: LexiconClass = .generic,
        source: Source,
        status: Status
    ) {
        self.id = id
        self.kind = kind
        self.canonical = canonical
        self.aliases = aliases
        self.ambiguousAliases = ambiguousAliases
        self.contexts = contexts
        self.lexiconClass = lexiconClass
        self.source = source
        self.status = status
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case canonical
        case aliases
        case ambiguousAliases
        case contexts
        case lexiconClass
        case source
        case status
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(Kind.self, forKey: .kind)
        canonical = try container.decode(String.self, forKey: .canonical)
        aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
        ambiguousAliases = try container.decodeIfPresent([String].self, forKey: .ambiguousAliases) ?? []
        contexts = try container.decodeIfPresent([String].self, forKey: .contexts) ?? []
        lexiconClass = try container.decodeIfPresent(LexiconClass.self, forKey: .lexiconClass) ?? .generic
        source = try container.decode(Source.self, forKey: .source)
        status = try container.decode(Status.self, forKey: .status)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(canonical, forKey: .canonical)
        try container.encode(aliases, forKey: .aliases)
        try container.encode(ambiguousAliases, forKey: .ambiguousAliases)
        try container.encode(contexts, forKey: .contexts)
        try container.encode(lexiconClass, forKey: .lexiconClass)
        try container.encode(source, forKey: .source)
        try container.encode(status, forKey: .status)
    }
}
