import Foundation

/// Deterministic post-final transcript cleanup for recurring ASR misses.
/// This intentionally stays narrow: exposed correction rules, not general grammar
/// or style rewriting.
public struct TranscriptCanonicalizer: Equatable, Sendable {
    public static let rulesDefaultsKey = "settings.canonicalizer.rulesJSON"
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

    public var rules: [Rule]

    public static let defaultRules: [Rule] = [
        Rule(
            canonical: "CMUX",
            aliases: ["CMUX", "simux", "siemux", "cmox", "c m u x", "c mux", "see mux", "sea mux"]
        ),
        Rule(
            canonical: "AGENTS.md",
            aliases: ["AGENTS.md", "agents dot md", "agents dot m d", "agents md", "agents dot markdown"]
        ),
        Rule(canonical: "README.md", aliases: ["README.md", "read me dot md", "readme dot md", "read me md"]),
        Rule(canonical: "Package.swift", aliases: ["Package.swift", "package dot swift"]),
        Rule(canonical: "project.yml", aliases: ["project.yml", "project dot yml", "project dot yaml"]),
        Rule(canonical: ".env", aliases: ["dot env"]),
        Rule(canonical: "swiftlint", aliases: ["swiftlint", "swift lint"]),
        Rule(canonical: "SpeechTranscriber", aliases: ["SpeechTranscriber", "speech transcriber"]),
        Rule(canonical: "DictationTranscriber", aliases: ["DictationTranscriber", "dictation transcriber"]),
        Rule(canonical: "UserDefaults", aliases: ["UserDefaults", "user defaults"]),
        Rule(canonical: "Xcode", aliases: ["Xcode", "x code"]),
        Rule(canonical: "macOS", aliases: ["macOS", "mac os"])
    ]

    public init(rules: [Rule] = Self.defaultRules) {
        self.rules = rules
    }

    public static func load(from defaults: UserDefaults = .standard) -> TranscriptCanonicalizer {
        TranscriptCanonicalizer(rules: rules(from: defaults))
    }

    public static func rules(from defaults: UserDefaults = .standard) -> [Rule] {
        guard let rawRules = defaults.string(forKey: rulesDefaultsKey),
              let data = rawRules.data(using: .utf8) else {
            return defaultRules
        }

        if let storedRules = try? JSONDecoder().decode(StoredRules.self, from: data) {
            return storedRules.rules
        }

        if let legacyCustomRules = try? JSONDecoder().decode([Rule].self, from: data) {
            return legacyCustomRules + defaultRules
        }

        return defaultRules
    }

    public static func saveRules(_ rules: [Rule], to defaults: UserDefaults = .standard) {
        let storedRules = StoredRules(version: storedRulesVersion, rules: rules)
        guard let data = try? JSONEncoder().encode(storedRules) else { return }
        defaults.set(String(decoding: data, as: UTF8.self), forKey: rulesDefaultsKey)
    }

    public func canonicalize(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        var output = text
        for spec in replacementSpecs() {
            output = Self.replacingMatches(in: output, spec: spec)
        }
        output = Self.replacingCommandTokens(in: output)
        return output
    }
}

private extension TranscriptCanonicalizer {
    struct StoredRules: Codable {
        var version: Int
        var rules: [Rule]
    }

    struct ReplacementSpec {
        var canonical: String
        var alias: String
        var contexts: [String]
        var ruleOrder: Int
    }

    func replacementSpecs() -> [ReplacementSpec] {
        rules.enumerated().flatMap { ruleOrder, rule in
            Self.allAliases(for: rule)
                .map {
                    ReplacementSpec(
                        canonical: rule.canonical,
                        alias: $0,
                        contexts: rule.contexts,
                        ruleOrder: ruleOrder
                    )
                }
        }
        .sorted { lhs, rhs in
            if lhs.alias.count == rhs.alias.count {
                return lhs.ruleOrder < rhs.ruleOrder
            }
            return lhs.alias.count > rhs.alias.count
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

    static func replacingMatches(in text: String, spec: ReplacementSpec) -> String {
        guard let regex = regex(forAlias: spec.alias) else { return text }

        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let matches = regex.matches(in: text, range: fullRange)
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
            .joined(separator: #"(?:[\s\-\.]+)"#)
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

    static func replacingCommandTokens(in text: String) -> String {
        var output = text
        output = replacing(
            pattern: #"(?<![A-Za-z0-9])dash\s+dash\s+([A-Za-z][A-Za-z0-9_-]*)"#,
            in: output,
            withTemplate: #"--$1"#
        )
        output = replacing(
            pattern: #"(?<![A-Za-z0-9])dash\s+dash(?![A-Za-z0-9])"#,
            in: output,
            withTemplate: "--"
        )
        output = replacing(
            pattern: #"(?<![A-Za-z0-9])slash\s+goal(?![A-Za-z0-9])"#,
            in: output,
            withTemplate: "/goal"
        )
        output = replacing(
            pattern: #"(?<![A-Za-z0-9])dollar\s+home(?![A-Za-z0-9])"#,
            in: output,
            withTemplate: "$HOME"
        )
        return output
    }

    static func replacing(pattern: String, in text: String, withTemplate template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    static func normalizedPhrase(_ phrase: String) -> String {
        phrase
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: " ")
    }
}
