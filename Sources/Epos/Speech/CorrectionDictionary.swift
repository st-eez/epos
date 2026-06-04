import Foundation

public struct CorrectionDictionary: Equatable, Sendable {
    public static let recordsDefaultsKey = "settings.correctionDictionary.recordsJSON"
    private static let storedDictionaryVersion = 1

    public var records: [CorrectionRecord]

    public init(records: [CorrectionRecord] = Self.defaultRecords) {
        self.records = records
    }

    public static func load(from defaults: UserDefaults = .standard) -> CorrectionDictionary {
        let result = storedRecords(from: defaults)
        if let migratedRecords = result.migratedRecords {
            saveRecords(migratedRecords, to: defaults)
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
        var defaultPairs = zip(
            CorrectionRuleCompiler.compile(records: defaultRecords),
            defaultRecords
        ).map { (rule: $0.0, record: $0.1) }

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
        defaultRecord(
            id: "builtin.stath",
            canonical: "Stath",
            aliases: ["steph", "staff", "stas"]
        ),
        defaultRecord(
            id: "builtin.stath-instructions",
            canonical: "Stath instructions",
            aliases: ["stuff instructions"]
        ),
        defaultRecord(id: "builtin.ping-stath", canonical: "ping Stath", aliases: ["ping stuff"]),
        defaultRecord(
            id: "builtin.when-stath-runs-it",
            canonical: "when Stath runs it",
            aliases: ["when stuff runs it"]
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
        defaultRecord(id: "builtin.yesterday-saying", canonical: "yesterday, saying", aliases: ["history, seeing"]),
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
            aliases: ["text is redundant, and you can remove"]
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
        // "suite"/"sweet" are homophones, so the recognizer renders the spoken brand as
        // a two-word common phrase ("net suite", "Net Sweet"). The "NetSuite" alias is the
        // already-correct/no-space form; case-insensitive matching folds in the rest.
        defaultRecord(
            id: "builtin.netsuite",
            canonical: "NetSuite",
            aliases: ["NetSuite", "net suite", "net sweet", "net suit"]
        ),
        defaultRecord(
            id: "builtin.netsuite-login",
            canonical: "NetSuite login",
            aliases: ["net suite login", "next week login"]
        ),
        defaultRecord(
            id: "builtin.netsuite-ticket",
            canonical: "NetSuite ticket",
            aliases: ["next week ticket"]
        ),
        defaultRecord(
            id: "builtin.open-netsuite",
            canonical: "Open NetSuite",
            aliases: ["Open that suite", "Open next feed"]
        ),
        defaultRecord(
            id: "builtin.teams-message",
            canonical: "Teams message",
            aliases: ["team's message", "team s message"]
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

    private static func storedRecords(from defaults: UserDefaults) -> StoredRecordsResult {
        if let rawDictionary = defaults.string(forKey: recordsDefaultsKey),
           let data = rawDictionary.data(using: .utf8),
           let storedDictionary = try? JSONDecoder().decode(StoredDictionary.self, from: data) {
            return StoredRecordsResult(records: storedDictionary.records)
        }

        let migratedRules = migratedRulesFromFlatStorage(defaults)
        let migratedRecords = records(from: migratedRules.rules)
        return StoredRecordsResult(
            records: migratedRecords,
            migratedRecords: migratedRules.shouldPersist ? migratedRecords : nil
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

    private static func manualRecord(index: Int, rule: TranscriptCanonicalizer.Rule) -> CorrectionRecord {
        CorrectionRecord(
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

    struct StoredRules: Codable {
        var version: Int
        var rules: [TranscriptCanonicalizer.Rule]
    }

    struct StoredRecordsResult {
        var records: [CorrectionRecord]
        var migratedRecords: [CorrectionRecord]?
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
