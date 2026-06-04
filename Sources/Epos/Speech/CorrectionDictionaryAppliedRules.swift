import Foundation

public extension CorrectionDictionary {
    func appliedRecordIDs(in text: String) -> [String] {
        var output = text
        var appliedIDs: [String] = []
        var seenIDs: Set<String> = []

        for spec in appliedRuleSpecs() {
            let result = Self.replacingMatches(in: output, spec: spec)
            output = result.output
            if result.applied, seenIDs.insert(spec.recordID).inserted {
                appliedIDs.append(spec.recordID)
            }
        }

        return appliedIDs
    }
}

private extension CorrectionDictionary {
    struct AppliedRuleSpec {
        var recordID: String
        var canonical: String
        var regex: NSRegularExpression
        var contexts: [String]
    }

    func appliedRuleSpecs() -> [AppliedRuleSpec] {
        records.enumerated()
            .flatMap { recordOrder, record in
                CorrectionRuleCompiler.compile(records: [record]).flatMap { rule in
                    rule.aliases.map { alias in
                        (
                            recordID: record.id,
                            canonical: rule.canonical,
                            alias: alias,
                            contexts: rule.contexts,
                            recordOrder: recordOrder
                        )
                    }
                }
            }
            .sorted { lhs, rhs in
                if lhs.alias.count == rhs.alias.count {
                    return lhs.recordOrder < rhs.recordOrder
                }
                return lhs.alias.count > rhs.alias.count
            }
            .compactMap { spec in
                Self.regex(forAlias: spec.alias).map { regex in
                    AppliedRuleSpec(
                        recordID: spec.recordID,
                        canonical: spec.canonical,
                        regex: regex,
                        contexts: spec.contexts
                    )
                }
            }
    }

    static func replacingMatches(
        in text: String,
        spec: AppliedRuleSpec
    ) -> (output: String, applied: Bool) {
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let matches = spec.regex.matches(in: text, range: fullRange)
        guard !matches.isEmpty else { return (text, false) }

        var output = ""
        var cursor = 0
        var applied = false

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
            applied = true
        }

        guard applied else { return (text, false) }

        output += nsText.substring(from: cursor)
        return (output, true)
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

    static func normalizedPhrase(_ phrase: String) -> String {
        phrase
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: " ")
    }
}
