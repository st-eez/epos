import Foundation

public extension CorrectionDictionary {
    func appliedRecordIDs(in text: String) -> [String] {
        CorrectionRuleMatcher.apply(appliedRuleSpecs(), to: text).appliedRecordIDs
    }
}

private extension CorrectionDictionary {
    func appliedRuleSpecs() -> [CorrectionRuleMatchSpec] {
        records.enumerated()
            .flatMap { recordOrder, record in
                CorrectionRuleCompiler.compile(records: [record]).enumerated().flatMap { ruleOrder, rule in
                    CorrectionMatchContext.uniqueAliases(rule.aliases).enumerated().map { aliasOrder, alias in
                        (
                            recordID: record.id,
                            canonical: rule.canonical,
                            alias: alias,
                            contexts: rule.contexts,
                            matchStrategy: rule.matchStrategy,
                            order: (recordOrder, ruleOrder, aliasOrder)
                        )
                    }
                }
            }
            .sorted { lhs, rhs in
                if lhs.alias.count == rhs.alias.count {
                    return lhs.order < rhs.order
                }
                return lhs.alias.count > rhs.alias.count
            }
            .compactMap { spec in
                CorrectionMatchContext.regex(forAlias: spec.alias).map { regex in
                    CorrectionRuleMatchSpec(
                        recordID: spec.recordID,
                        canonical: spec.canonical,
                        regex: regex,
                        contexts: spec.contexts,
                        matchStrategy: spec.matchStrategy
                    )
                }
            }
    }
}
