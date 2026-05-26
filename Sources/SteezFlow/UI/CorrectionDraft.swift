import Foundation

struct CorrectionDraft: Identifiable, Equatable {
    var id = UUID()
    var aliasesText: String
    var canonical: String
    var contextsText: String

    var trimmedCanonical: String {
        canonical.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var aliases: [String] {
        Self.parseList(aliasesText)
    }

    var contexts: [String] {
        Self.parseList(contextsText)
    }

    var isValid: Bool {
        !trimmedCanonical.isEmpty && !aliases.isEmpty
    }

    var rule: TranscriptCanonicalizer.Rule {
        TranscriptCanonicalizer.Rule(canonical: trimmedCanonical, aliases: aliases, contexts: contexts)
    }

    static func empty() -> CorrectionDraft {
        CorrectionDraft(aliasesText: "", canonical: "", contextsText: "")
    }

    static func fromRules(_ rules: [TranscriptCanonicalizer.Rule]) -> [CorrectionDraft] {
        rules.map { rule in
            CorrectionDraft(
                aliasesText: rule.aliases.joined(separator: ", "),
                canonical: rule.canonical,
                contextsText: rule.contexts.joined(separator: ", ")
            )
        }
    }

    private static func parseList(_ text: String) -> [String] {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func == (lhs: CorrectionDraft, rhs: CorrectionDraft) -> Bool {
        lhs.aliasesText == rhs.aliasesText &&
            lhs.canonical == rhs.canonical &&
            lhs.contextsText == rhs.contextsText
    }
}
