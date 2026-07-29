import Foundation

public struct CorrectionDictionary: Equatable, Sendable {
    public static let recordsDefaultsKey = "settings.correctionDictionary.recordsJSON"
    static let storedDictionaryVersion = 1
    static let builtInIntroductionVersions: [String: Int] = [
        "builtin.claude-md": 1,
        "builtin.llm-polish": 1,
        "builtin.epos-app": 1,
        "builtin.readme-and-agents-file": 1,
        "builtin.subagents-context-window": 1,
        "builtin.foundation-models": 1,
        "builtin.saying-deprecate": 1,
        "builtin.yesterday-saying": 1,
        "builtin.not-working-properly": 1,
        "builtin.did-we-close-phase-one": 1,
        "builtin.it-would-add-extra": 1,
        "builtin.text-is-redundant": 1,
        "builtin.three-letter-code": 1,
        "builtin.two-tickets": 1,
        "builtin.two-things": 1,
        "builtin.part-two": 1,
        "builtin.add-comment-ticket": 1,
        "builtin.add-comment-tickets": 1,
        "builtin.codebase": 1,
        "builtin.unslopify": 1,
        "builtin.claude-vibe-coding": 1,
        "builtin.different-than-main": 1,
        "builtin.different-from-main": 1,
        "builtin.regressions-suite": 1,
        "builtin.slash": 1,
        "builtin.cmux": 1,
        "builtin.agents-md": 1,
        "builtin.readme-md": 1,
        "builtin.project-yml": 1,
        "builtin.updates-to-claude-md": 1,
        "builtin.env": 1,
        "builtin.dash-dash": 1,
        "builtin.slash-goal": 1,
        "builtin.dollar-home": 1
    ]
    private static let log = EposLogger(category: "corrections")

    public var records: [CorrectionRecord]

    public init(records: [CorrectionRecord] = Self.defaultRecords) {
        self.records = records
    }

    public static func load(from defaults: UserDefaults = .standard) -> CorrectionDictionary {
        let result = storedRecords(from: defaults)
        if let migratedRecords = result.migratedRecords {
            saveRecords(migratedRecords, to: defaults)
        }
        if result.shouldRemoveLegacyRules {
            defaults.removeObject(forKey: TranscriptCanonicalizer.rulesDefaultsKey)
        }
        return CorrectionDictionary(records: result.records)
    }

    public static func records(from defaults: UserDefaults = .standard) -> [CorrectionRecord] {
        storedRecords(from: defaults).records
    }

    public static func saveRecords(_ records: [CorrectionRecord], to defaults: UserDefaults = .standard) {
        let storedDictionary = StoredDictionary(version: storedDictionaryVersion, records: records)
        guard let data = try? JSONEncoder().encode(storedDictionary) else { return }
        defaults.set(String(decoding: data, as: UTF8.self), forKey: recordsDefaultsKey)
    }

    public static func records(from rules: [TranscriptCanonicalizer.Rule]) -> [CorrectionRecord] {
        var defaultPairs = builtInRuleMigrationPairs()

        return rules.enumerated().map { index, rule in
            if let defaultIndex = defaultPairs.firstIndex(where: { $0.rule == rule }) {
                return defaultPairs.remove(at: defaultIndex).record
            }

            return manualRecord(index: index, rule: rule)
        }
    }

    public static let defaultRecords: [CorrectionRecord] = [
        defaultRecord(
            id: "builtin.claude-md",
            canonical: "CLAUDE.md",
            aliases: [
                "CLAUDE.md",
                "claude dot md",
                "claude dot m d",
                "claude md",
                "cloud dot md",
                "cloud dot m d",
                "cloud.md"
            ]
        ),
        defaultRecord(id: "builtin.llm-polish", canonical: "LLM polish", aliases: ["LOL polish"]),
        defaultRecord(id: "builtin.epos-app", canonical: "Epos app", aliases: ["Ipos app"]),
        defaultRecord(
            id: "builtin.readme-and-agents-file",
            canonical: "the README and the AGENTS file",
            aliases: ["the read me and the agent's file"]
        ),
        defaultRecord(
            id: "builtin.subagents-context-window",
            canonical: "Use subagents as needed to keep your context window clean",
            aliases: ["Use of agents as needed to keep your context window clean"]
        ),
        defaultRecord(
            id: "builtin.foundation-models",
            canonical: "Foundation Models",
            aliases: ["foundation models", "foundational models", "the foundation models"]
        ),
        defaultRecord(id: "builtin.saying-deprecate", canonical: "saying deprecate", aliases: ["seeing deprecate"]),
        defaultRecord(id: "builtin.yesterday-saying", canonical: "yesterday, saying", aliases: ["history seeing"]),
        defaultRecord(
            id: "builtin.not-working-properly",
            canonical: "not working properly",
            aliases: ["not working progress"]
        ),
        defaultRecord(
            id: "builtin.did-we-close-phase-one",
            canonical: "Did we close phase one",
            aliases: ["They'd be closed phase one"]
        ),
        defaultRecord(
            id: "builtin.it-would-add-extra",
            canonical: "It would add extra",
            aliases: ["It'd be add extra"]
        ),
        defaultRecord(
            id: "builtin.text-is-redundant",
            canonical: "text is redundant and what you can remove",
            aliases: ["text is redundant and you can remove"]
        ),
        defaultRecord(
            id: "builtin.three-letter-code",
            canonical: "three-letter code",
            aliases: ["3 litter code", "three litter code"]
        ),
        defaultRecord(id: "builtin.two-tickets", canonical: "two tickets", aliases: ["2 tickets"]),
        defaultRecord(id: "builtin.two-things", canonical: "two things", aliases: ["2 things"]),
        defaultRecord(id: "builtin.part-two", canonical: "part two", aliases: ["part 2"]),
        defaultRecord(
            id: "builtin.add-comment-ticket",
            canonical: "Add a comment to the ticket",
            aliases: ["At a comment to the ticket"]
        ),
        defaultRecord(
            id: "builtin.add-comment-tickets",
            canonical: "Add a comment to the tickets",
            aliases: ["I recommend to the tickets"]
        ),
        defaultRecord(id: "builtin.codebase", canonical: "codebase", aliases: ["code basis", "code base"]),
        defaultRecord(id: "builtin.unslopify", canonical: "unslopify", aliases: ["unslop the fight"]),
        defaultRecord(
            id: "builtin.claude-vibe-coding",
            canonical: "Claude has been vibe coding",
            aliases: ["Plot has been vibe coding"]
        ),
        defaultRecord(
            id: "builtin.different-than-main",
            canonical: "different than main",
            aliases: ["different than Maine"]
        ),
        defaultRecord(
            id: "builtin.different-from-main",
            canonical: "different from main",
            aliases: ["different from Maine"]
        ),
        defaultRecord(
            id: "builtin.regressions-suite",
            canonical: "regressions in the suite",
            aliases: ["regressions in the sweet"]
        ),
        defaultRecord(id: "builtin.slash", kind: .spokenCommand, canonical: "/", aliases: ["slash"]),
        defaultRecord(
            id: "builtin.cmux",
            canonical: "CMUX",
            aliases: ["CMUX", "simux", "siemux", "semux", "cmox", "c m u x", "c mux", "see mux", "sea mux"]
        ),
        defaultRecord(
            id: "builtin.agents-md",
            canonical: "AGENTS.md",
            aliases: ["AGENTS.md", "agents dot md", "agents dot m d", "agents md", "agents dot markdown"]
        ),
        defaultRecord(
            id: "builtin.readme-md",
            canonical: "README.md",
            aliases: ["README.md", "read me dot md", "readme dot md", "read me md"]
        ),
        defaultRecord(
            id: "builtin.project-yml",
            canonical: "project.yml",
            aliases: ["project.yml", "project.yaml", "project.yamo", "project dot yml", "project dot yaml"]
        ),
        defaultRecord(
            id: "builtin.updates-to-claude-md",
            canonical: "updates to CLAUDE.md",
            aliases: ["updates to the CLAUDE.md", "updates to the cloud.MD"]
        ),
        defaultRecord(id: "builtin.env", canonical: ".env", aliases: ["dot env"]),
        // Developer-token shorthands. Plain alias->canonical, so they ride the same
        // engine as user rules; only the flag-prefix form stays in TranscriptCanonicalizer.
        defaultRecord(
            id: "builtin.dash-dash",
            kind: .spokenCommand,
            canonical: "--",
            aliases: ["dash dash"]
        ),
        defaultRecord(
            id: "builtin.slash-goal",
            kind: .spokenCommand,
            canonical: "/goal",
            aliases: ["slash goal"]
        ),
        defaultRecord(
            id: "builtin.dollar-home",
            kind: .spokenCommand,
            canonical: "$HOME",
            aliases: ["dollar home"]
        )
    ]

    private static func defaultRecord(
        id: String,
        kind: CorrectionRecord.Kind = .replacement,
        canonical: String,
        aliases: [String],
        contexts: [String] = []
    ) -> CorrectionRecord {
        CorrectionRecord(
            id: id,
            kind: kind,
            canonical: canonical,
            aliases: aliases,
            contexts: contexts,
            source: .builtIn,
            status: .active
        )
    }

    private static func builtInRuleMigrationPairs() -> [
        (rule: TranscriptCanonicalizer.Rule, record: CorrectionRecord)
    ] {
        let currentPairs = zip(
            CorrectionRuleCompiler.compile(records: defaultRecords),
            defaultRecords
        ).map { (rule: $0.0, record: $0.1) }
        let legacyPairs = zip(
            CorrectionRuleCompiler.compile(records: legacyBuiltInRecordsForMigration),
            legacyBuiltInRecordsForMigration.compactMap { currentDefaultRecord(for: $0.id) }
        ).map { (rule: $0.0, record: $0.1) }
        return currentPairs + legacyPairs
    }

    private static var legacyBuiltInRecordsForMigration: [CorrectionRecord] {
        defaultRecords.map { record in
            var record = record
            switch record.id {
            case "builtin.yesterday-saying":
                record.aliases = ["history, seeing"]
            case "builtin.text-is-redundant":
                record.aliases = ["text is redundant, and you can remove"]
            default:
                break
            }
            return record
        }
    }

    private static func currentDefaultRecord(for id: String) -> CorrectionRecord? {
        defaultRecords.first { $0.id == id }
    }

    private static func storedRecords(from defaults: UserDefaults) -> StoredRecordsResult {
        if let rawDictionary = defaults.string(forKey: recordsDefaultsKey),
           let data = rawDictionary.data(using: .utf8),
           let storedDictionary = try? JSONDecoder().decode(TolerantStoredDictionary.self, from: data) {
            // Per-record tolerance: one record carrying an unknown enum case or a
            // future-added field must not throw away the WHOLE dictionary — that
            // silently reset every user correction to defaults, and the next save
            // made the reset permanent. Keep the readable records, log the rest;
            // the stripped set is NOT persisted here, so nothing is lost until the
            // user's own next save.
            if storedDictionary.undecodableRecordCount > 0 {
                log.error(
                    "correction dictionary dropped \(storedDictionary.undecodableRecordCount) undecodable record(s) on load"
                )
            }
            let migrated = migratingStoredBuiltInRecords(
                storedDictionary.records,
                storedVersion: storedDictionary.version,
                appendIntroducedDefaults: storedDictionary.undecodableRecordCount == 0
            )
            // Never rewrite the stored blob when undecodable records were dropped:
            // a built-in migration in the same load would otherwise persist the
            // stripped set, destroying the future-schema records the tolerant
            // decode just promised to leave intact. The in-memory records still
            // migrate; persistence waits for the user's own next save.
            let canPersistMigration = storedDictionary.undecodableRecordCount == 0
            return StoredRecordsResult(
                records: migrated.records,
                migratedRecords: migrated.didChange && canPersistMigration ? migrated.records : nil,
                shouldRemoveLegacyRules: migrated.didChange && canPersistMigration
            )
        }

        let migratedRules = migratedRulesFromFlatStorage(defaults)
        let migratedRecords = records(from: migratedRules.rules)
        return StoredRecordsResult(
            records: migratedRecords,
            migratedRecords: migratedRules.shouldPersist ? migratedRecords : nil,
            shouldRemoveLegacyRules: migratedRules.shouldPersist
        )
    }

    private static func migratedRulesFromFlatStorage(_ defaults: UserDefaults) -> MigratedRules {
        guard let rawRules = defaults.string(forKey: TranscriptCanonicalizer.rulesDefaultsKey),
              let data = rawRules.data(using: .utf8) else {
            return MigratedRules(rules: TranscriptCanonicalizer.defaultRules, shouldPersist: false)
        }

        if let storedRules = try? JSONDecoder().decode(StoredRules.self, from: data) {
            return MigratedRules(rules: storedRules.rules, shouldPersist: true)
        }

        if let legacyCustomRules = try? JSONDecoder().decode([TranscriptCanonicalizer.Rule].self, from: data) {
            return MigratedRules(
                rules: legacyCustomRules + TranscriptCanonicalizer.defaultRules,
                shouldPersist: true
            )
        }

        return MigratedRules(rules: TranscriptCanonicalizer.defaultRules, shouldPersist: false)
    }

    private static func migratingStoredBuiltInRecords(
        _ records: [CorrectionRecord],
        storedVersion: Int,
        appendIntroducedDefaults: Bool
    ) -> (
        records: [CorrectionRecord],
        didChange: Bool
    ) {
        let defaultsByID = Dictionary(uniqueKeysWithValues: defaultRecords.map { ($0.id, $0) })
        var didChange = false
        var migratedRecords = records.compactMap { record -> CorrectionRecord? in
            guard record.source == .builtIn else { return record }

            guard var current = defaultsByID[record.id] else {
                var manual = record
                manual.source = .manual
                didChange = true
                return manual
            }

            guard current != record else {
                return record
            }

            current.status = record.status
            didChange = true
            return current
        }
        if appendIntroducedDefaults {
            let storedIDs = Set(migratedRecords.map(\.id))
            let missingDefaults = defaultRecords.filter { record in
                guard !storedIDs.contains(record.id),
                      let introductionVersion = builtInIntroductionVersions[record.id] else {
                    return false
                }
                return introductionVersion > storedVersion
            }
            if !missingDefaults.isEmpty {
                migratedRecords.append(contentsOf: missingDefaults)
                didChange = true
            }
        }
        return (migratedRecords, didChange)
    }

    private static func manualRecord(index: Int, rule: TranscriptCanonicalizer.Rule) -> CorrectionRecord {
        if rule.matchStrategy == .personNameSlot {
            return CorrectionRecord(
                id: manualRecordID(index: index, canonical: rule.canonical),
                kind: .lexicon,
                canonical: rule.canonical,
                aliases: [],
                ambiguousAliases: rule.aliases,
                contexts: rule.contexts,
                lexiconClass: .person,
                source: .manual,
                status: .active
            )
        }

        return CorrectionRecord(
            id: manualRecordID(index: index, canonical: rule.canonical),
            kind: .replacement,
            canonical: rule.canonical,
            aliases: rule.aliases,
            contexts: rule.contexts,
            source: .manual,
            status: .active
        )
    }

    private static func manualRecordID(index: Int, canonical: String) -> String {
        let slug = canonical
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: "-")
        let suffix = slug.isEmpty ? "replacement" : slug
        return "manual.\(index).\(suffix)"
    }

}

private extension CorrectionDictionary {
    struct StoredDictionary: Codable {
        var version: Int
        var records: [CorrectionRecord]
    }

    /// Load-side counterpart of `StoredDictionary` that decodes records one by one,
    /// keeping the readable ones instead of letting a single bad record (an unknown
    /// enum case written by a future build, say) fail the whole array and silently
    /// reset the user's dictionary to defaults.
    struct TolerantStoredDictionary: Decodable {
        var version: Int
        var records: [CorrectionRecord]
        var undecodableRecordCount: Int

        private struct FailableRecord: Decodable {
            let record: CorrectionRecord?

            init(from decoder: Decoder) throws {
                record = try? CorrectionRecord(from: decoder)
            }
        }

        private enum CodingKeys: String, CodingKey {
            case version
            case records
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            let failableRecords = try container.decode([FailableRecord].self, forKey: .records)
            records = failableRecords.compactMap(\.record)
            undecodableRecordCount = failableRecords.count - records.count
        }
    }

    struct StoredRules: Codable {
        var version: Int
        var rules: [TranscriptCanonicalizer.Rule]
    }

    struct StoredRecordsResult {
        var records: [CorrectionRecord]
        var migratedRecords: [CorrectionRecord]?
        var shouldRemoveLegacyRules: Bool
    }

    struct MigratedRules {
        var rules: [TranscriptCanonicalizer.Rule]
        var shouldPersist: Bool
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
