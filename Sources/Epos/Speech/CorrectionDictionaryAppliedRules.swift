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
        var matchStrategy: TranscriptCanonicalizer.Rule.MatchStrategy
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
                            matchStrategy: rule.matchStrategy,
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
                CorrectionMatchContext.regex(forAlias: spec.alias).map { regex in
                    AppliedRuleSpec(
                        recordID: spec.recordID,
                        canonical: spec.canonical,
                        regex: regex,
                        contexts: spec.contexts,
                        matchStrategy: spec.matchStrategy
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
            guard CorrectionMatchContext.allows(
                matchStrategy: spec.matchStrategy,
                contexts: spec.contexts,
                before: match.range,
                in: nsText
            ) else {
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
}
