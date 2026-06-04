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
    private static let storedRulesVersion = 1

    public struct Rule: Codable, Equatable, Sendable {
        public var canonical: String
        public var aliases: [String]
        public var contexts: [String]

        public init(canonical: String, aliases: [String] = [], contexts: [String] = []) {
            self.canonical = canonical
            self.aliases = aliases
            self.contexts = contexts
        }

        private enum CodingKeys: String, CodingKey {
            case canonical
            case aliases
            case contexts
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            canonical = try container.decode(String.self, forKey: .canonical)
            aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
            contexts = try container.decodeIfPresent([String].self, forKey: .contexts) ?? []
        }
    }

    public let rules: [Rule]

    /// Compiled once from `rules` at init: the alias regexes, sorted longest-alias-first
    /// so a longer phrase wins over a shorter one it contains. `canonicalize` just runs
    /// these — it never recompiles regexes or re-sorts per call.
    private let specs: [CompiledSpec]

    struct CompiledSpec: Sendable {
        let canonical: String
        let regex: NSRegularExpression
        let contexts: [String]
    }

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

    public static func saveRules(_ rules: [Rule], to defaults: UserDefaults = .standard) {
        CorrectionDictionary.saveRecords(CorrectionDictionary.records(from: rules), to: defaults)
        let storedRules = StoredRules(version: storedRulesVersion, rules: rules)
        guard let data = try? JSONEncoder().encode(storedRules) else { return }
        defaults.set(String(decoding: data, as: UTF8.self), forKey: rulesDefaultsKey)
    }

    public func canonicalize(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        // Only the flag-prefix form ("dash dash verbose" -> "--verbose") needs a capture
        // group; every other spoken shorthand is a plain alias->canonical default rule,
        // so it flows through the same engine as user rules below.
        var output = Self.attachingFlagPrefix(in: text)
        for spec in specs {
            output = Self.replacingMatches(in: output, spec: spec)
        }
        return output
    }

    /// Canonical vocabulary to pass to the polish model as known exact spellings.
    /// Yields each rule's canonical form once (de-duplicated, capped), skipping
    /// pure-symbol canonicals like `--` or `/` that carry no pronounceable token.
    public var canonicalVocabularyStrings: [String] {
        contextualStrings(includingAliases: false)
    }

    /// Vocabulary to feed the recognizer as `AnalysisContext` bias so it can produce
    /// these terms up front instead of relying only on the post-hoc rewrite. Includes
    /// canonical forms plus unguarded spoken aliases, because the recognizer hears
    /// phrases like "net suite" or "claude dot md" before the canonicalizer rewrites
    /// them into their written forms.
    ///
    /// Note: a canonical's *written* form (`CLAUDE.md`) is not how it is *spoken*
    /// (`claude dot md`), so biasing helps most for terms pronounced as written
    /// (proper nouns, acronyms). Alias forms cover the spoken spellings.
    public var speechContextualStrings: [String] {
        contextualStrings(includingAliases: true)
    }

    private func contextualStrings(includingAliases: Bool) -> [String] {
        var phrases: [String] = []
        var seen: Set<String> = []

        for rule in rules {
            let candidates = [rule.canonical]
                + (includingAliases && rule.contexts.isEmpty ? Self.allAliases(for: rule) : [])
            for candidate in candidates {
                let phrase = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                guard Self.isUsefulSpeechContext(phrase) else { continue }

                let key = Self.normalizedPhrase(phrase)
                guard seen.insert(key).inserted else { continue }

                phrases.append(phrase)
                if phrases.count == Self.maxSpeechContextualStringCount { return phrases }
            }
        }

        return phrases
    }
}

private extension TranscriptCanonicalizer {
    struct StoredRules: Codable {
        var version: Int
        var rules: [Rule]
    }

    static func compile(_ rules: [Rule]) -> [CompiledSpec] {
        rules.enumerated()
            .flatMap { ruleOrder, rule in
                allAliases(for: rule).map {
                    (canonical: rule.canonical, alias: $0, contexts: rule.contexts, ruleOrder: ruleOrder)
                }
            }
            .sorted { lhs, rhs in
                if lhs.alias.count == rhs.alias.count {
                    return lhs.ruleOrder < rhs.ruleOrder
                }
                return lhs.alias.count > rhs.alias.count
            }
            .compactMap { spec in
                regex(forAlias: spec.alias).map {
                    CompiledSpec(canonical: spec.canonical, regex: $0, contexts: spec.contexts)
                }
            }
    }

    static func allAliases(for rule: Rule) -> [String] {
        var seen: Set<String> = []
        return rule.aliases.filter { alias in
            let key = normalizedPhrase(alias)
            guard !key.isEmpty, !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }

    static func replacingMatches(in text: String, spec: CompiledSpec) -> String {
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let matches = spec.regex.matches(in: text, range: fullRange)
        guard !matches.isEmpty else { return text }

        var output = ""
        var cursor = 0

        for match in matches {
            guard match.range.location >= cursor else { continue }
            guard spec.contexts.isEmpty || hasContext(spec.contexts, before: match.range, in: nsText) else {
                continue
            }

            output += nsText.substring(
                with: NSRange(location: cursor, length: match.range.location - cursor)
            )
            output += spec.canonical
            cursor = match.range.location + match.range.length
        }

        output += nsText.substring(from: cursor)
        return output
    }

    static func regex(forAlias alias: String) -> NSRegularExpression? {
        let parts = alias
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)

        guard !parts.isEmpty else { return nil }

        let body = parts
            .map(NSRegularExpression.escapedPattern(for:))
            .joined(separator: #"(?:[\s,\-\.']+)"#)
        let pattern = #"(?<![A-Za-z0-9])"# + body + #"(?![A-Za-z0-9])"#
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    static func hasContext(_ contexts: [String], before range: NSRange, in text: NSString) -> Bool {
        let windowLength = 64
        let start = max(0, range.location - windowLength)
        let prefix = text.substring(with: NSRange(location: start, length: range.location - start))
        let normalizedPrefix = normalizedPhrase(prefix)

        return contexts.contains { context in
            let normalizedContext = normalizedPhrase(context)
            return !normalizedContext.isEmpty && normalizedPrefix.contains(normalizedContext)
        }
    }

    /// `dash dash <flag>` -> `--<flag>`. The one shorthand the alias->canonical engine
    /// can't express (it prepends `--` to a captured word), so it stays a pre-pass.
    /// Bare `dash dash`, `slash goal`, and `dollar home` are plain default rules.
    static func attachingFlagPrefix(in text: String) -> String {
        guard let regex = flagPrefixRegex else { return text }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: #"--$1"#)
    }

    /// Compiled once at type load, not per call: the flag-prefix pattern is a fixed literal
    /// (it does not depend on `rules`), and `canonicalize` runs per streamed partial, so
    /// recompiling it each call was pure waste. Optional to mirror the alias-regex path
    /// (`regex(forAlias:)`); the literal always compiles, so the `nil` branch never trips.
    static let flagPrefixRegex = try? NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9])dash\s+dash\s+([A-Za-z][A-Za-z0-9_-]*)"#,
        options: [.caseInsensitive]
    )

    static func normalizedPhrase(_ phrase: String) -> String {
        phrase
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: " ")
    }

    /// A canonical worth biasing the recognizer toward carries at least one letter
    /// or digit; pure punctuation (`--`, `/`) has nothing for the model to match.
    static func isUsefulSpeechContext(_ phrase: String) -> Bool {
        phrase.contains { $0.isLetter || $0.isNumber }
    }
}
