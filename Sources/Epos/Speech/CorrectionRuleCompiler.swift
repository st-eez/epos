import Foundation

public enum CorrectionRuleCompiler {
    public static func compile(records: [CorrectionRecord]) -> [TranscriptCanonicalizer.Rule] {
        records.compactMap { record in
            guard record.status == .active, record.kind.compilesToCanonicalizer else { return nil }

            let canonical = record.canonical.trimmingCharacters(in: .whitespacesAndNewlines)
            let aliases = record.aliases.trimmingNonEmpty()
            guard !canonical.isEmpty, !aliases.isEmpty else { return nil }

            return TranscriptCanonicalizer.Rule(
                canonical: canonical,
                aliases: aliases,
                contexts: record.contexts.trimmingNonEmpty()
            )
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
