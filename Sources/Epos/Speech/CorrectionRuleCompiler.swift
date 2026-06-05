import Foundation

public enum CorrectionRuleCompiler {
    public static func compile(records: [CorrectionRecord]) -> [TranscriptCanonicalizer.Rule] {
        records.flatMap { record -> [TranscriptCanonicalizer.Rule] in
            guard record.status == .active, record.kind.compilesToCanonicalizer else { return [] }

            let canonical = record.canonical.trimmingCharacters(in: .whitespacesAndNewlines)
            let aliases = record.aliases.trimmingNonEmpty()
            let ambiguousAliases = record.ambiguousAliases.trimmingNonEmpty()
            let contexts = record.contexts.trimmingNonEmpty()
            guard !canonical.isEmpty else { return [] }

            var rules: [TranscriptCanonicalizer.Rule] = []
            if !aliases.isEmpty {
                rules.append(
                    TranscriptCanonicalizer.Rule(
                        canonical: canonical,
                        aliases: aliases,
                        contexts: contexts
                    )
                )
            }

            if record.kind == .lexicon,
               record.lexiconClass == .person,
               !ambiguousAliases.isEmpty {
                rules.append(
                    TranscriptCanonicalizer.Rule(
                        canonical: canonical,
                        aliases: ambiguousAliases,
                        contexts: contexts,
                        matchStrategy: .personNameSlot
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
