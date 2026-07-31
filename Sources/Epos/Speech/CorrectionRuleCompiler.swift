import Foundation

/// A compiled canonicalizer rule carrying the record it came from. Compilation is not
/// one rule per record — an inactive, non-compiling, or empty-alias record emits none,
/// and a person lexicon with ambiguous aliases emits two — so anything that needs to get
/// back from a rule to its record must carry the record, never recover it by position.
struct CompiledCorrectionRule: Equatable, Sendable {
    let rule: TranscriptCanonicalizer.Rule
    let record: CorrectionRecord
}

public enum CorrectionRuleCompiler {
    public static func compile(records: [CorrectionRecord]) -> [TranscriptCanonicalizer.Rule] {
        compileWithSources(records: records).map(\.rule)
    }

    static func compileWithSources(records: [CorrectionRecord]) -> [CompiledCorrectionRule] {
        records.flatMap { record -> [CompiledCorrectionRule] in
            guard record.status == .active, record.kind.compilesToCanonicalizer else { return [] }

            let canonical = record.canonical.trimmingCharacters(in: .whitespacesAndNewlines)
            let aliases = record.aliases.trimmingNonEmpty()
            let ambiguousAliases = record.ambiguousAliases.trimmingNonEmpty()
            let contexts = record.contexts.trimmingNonEmpty()
            guard !canonical.isEmpty else { return [] }

            var rules: [CompiledCorrectionRule] = []
            if !aliases.isEmpty {
                rules.append(
                    CompiledCorrectionRule(
                        rule: TranscriptCanonicalizer.Rule(
                            canonical: canonical,
                            aliases: aliases,
                            contexts: contexts
                        ),
                        record: record
                    )
                )
            }

            if record.kind == .lexicon,
               record.lexiconClass == .person,
               !ambiguousAliases.isEmpty {
                rules.append(
                    CompiledCorrectionRule(
                        rule: TranscriptCanonicalizer.Rule(
                            canonical: canonical,
                            aliases: ambiguousAliases,
                            contexts: contexts,
                            matchStrategy: .personNameSlot
                        ),
                        record: record
                    )
                )
            }

            return rules
        }
    }
}

private extension CorrectionRecord.Kind {
    var compilesToCanonicalizer: Bool {
        switch self {
        case .lexicon, .replacement, .spokenCommand:
            return true
        case .snippet, .formattingPolicy:
            return false
        }
    }
}

private extension [String] {
    func trimmingNonEmpty() -> [String] {
        map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
