import Foundation

/// Deterministic post-final transcript cleanup for recurring ASR misses.
/// This intentionally stays narrow: exposed correction rules, not general grammar
/// or style rewriting.
public struct TranscriptCanonicalizer: Sendable {
    public static let rulesDefaultsKey = "settings.canonicalizer.rulesJSON"
    /// `AnalysisContext.contextualStrings` is bounded; cap the bias list so a large
    /// rule set can't flood it. Apple does not document a hard limit, so this is a
    /// conservative ceiling, not a guarantee.
    public static let maxSpeechContextualStringCount = 100

    public struct Rule: Codable, Equatable, Sendable {
        public enum MatchStrategy: String, Codable, Equatable, Hashable, Sendable {
            case literal
            case personNameSlot
        }

        public var canonical: String
        public var aliases: [String]
        public var contexts: [String]
        public var matchStrategy: MatchStrategy

        public init(
            canonical: String,
            aliases: [String] = [],
            contexts: [String] = [],
            matchStrategy: MatchStrategy = .literal
        ) {
            self.canonical = canonical
            self.aliases = aliases
            self.contexts = contexts
            self.matchStrategy = matchStrategy
        }

        private enum CodingKeys: String, CodingKey {
            case canonical
            case aliases
            case contexts
            case matchStrategy
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            canonical = try container.decode(String.self, forKey: .canonical)
            aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
            contexts = try container.decodeIfPresent([String].self, forKey: .contexts) ?? []
            matchStrategy = try container.decodeIfPresent(MatchStrategy.self, forKey: .matchStrategy) ?? .literal
        }
    }

    public let rules: [Rule]

    /// Compiled once from `rules` at init: the alias regexes, sorted longest-alias-first
    /// so a longer phrase wins over a shorter one it contains. `canonicalize` just runs
    /// these — it never recompiles regexes or re-sorts per call.
    private let specs: [CorrectionRuleMatchSpec]

    public static let defaultRules: [Rule] = CorrectionRuleCompiler.compile(
        records: CorrectionDictionary.defaultRecords
    )

    public init(rules: [Rule] = Self.defaultRules) {
        self.rules = rules
        self.specs = Self.compile(rules)
    }

    public static func load(from defaults: UserDefaults = .standard) -> TranscriptCanonicalizer {
        let dictionary = CorrectionDictionary.load(from: defaults)
        return TranscriptCanonicalizer(rules: CorrectionRuleCompiler.compile(records: dictionary.records))
    }

    public static func rules(from defaults: UserDefaults = .standard) -> [Rule] {
        let dictionary = CorrectionDictionary.load(from: defaults)
        return CorrectionRuleCompiler.compile(records: dictionary.records)
    }

    public func canonicalize(_ text: String) -> String {
        CorrectionRuleMatcher.apply(specs, to: text).output
    }

    /// Canonical vocabulary to pass to the polish model as known exact spellings.
    /// Yields each rule's canonical form once (de-duplicated, capped), skipping
    /// pure-symbol canonicals like `--` or `/` that carry no pronounceable token.
    public var canonicalVocabularyStrings: [String] {
        contextualStrings()
    }

    /// Canonical vocabulary to feed the recognizer as best-effort `AnalysisContext`
    /// bias. Post-hoc aliases intentionally stay out: many are observed recognizer
    /// errors, and feeding those errors back as desired vocabulary can create the
    /// exact phrase that a later correction rewrites.
    public var speechContextualStrings: [String] {
        contextualStrings()
    }

    private func contextualStrings() -> [String] {
        var phrases: [String] = []
        var seen: Set<String> = []

        for rule in rules {
            let phrase = rule.canonical.trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.isUsefulSpeechContext(phrase) else { continue }

            let key = CorrectionMatchContext.normalizedPhrase(phrase)
            guard seen.insert(key).inserted else { continue }

            phrases.append(phrase)
            if phrases.count == Self.maxSpeechContextualStringCount { return phrases }
        }

        return phrases
    }
}

private extension TranscriptCanonicalizer {
    static func compile(_ rules: [Rule]) -> [CorrectionRuleMatchSpec] {
        rules.enumerated()
            .flatMap { ruleOrder, rule in
                allAliases(for: rule).enumerated().map { aliasOrder, alias in
                    (
                        canonical: rule.canonical,
                        alias: alias,
                        contexts: rule.contexts,
                        matchStrategy: rule.matchStrategy,
                        order: (ruleOrder, aliasOrder)
                    )
                }
            }
            .sorted { lhs, rhs in
                if lhs.alias.count == rhs.alias.count {
                    return lhs.order < rhs.order
                }
                return lhs.alias.count > rhs.alias.count
            }
            .compactMap { spec in
                CorrectionMatchContext.regex(forAlias: spec.alias).map {
                    CorrectionRuleMatchSpec(
                        recordID: nil,
                        canonical: spec.canonical,
                        regex: $0,
                        contexts: spec.contexts,
                        matchStrategy: spec.matchStrategy,
                        attachesFlagArgument: CorrectionRuleMatcher.isFlagPrefixRule(
                            canonical: spec.canonical,
                            aliasRegex: $0
                        )
                    )
                }
            }
    }

    static func allAliases(for rule: Rule) -> [String] {
        CorrectionMatchContext.uniqueAliases(rule.aliases)
    }

    /// A canonical worth biasing the recognizer toward carries at least one letter
    /// or digit; pure punctuation (`--`, `/`) has nothing for the model to match.
    static func isUsefulSpeechContext(_ phrase: String) -> Bool {
        phrase.contains { $0.isLetter || $0.isNumber }
    }
}
