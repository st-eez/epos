import Foundation

struct CorrectionDraft: Identifiable, Equatable {
    var id = UUID()
    var aliasesText: String
    var canonical: String
    var contextsText: String
    var matchStrategy: TranscriptCanonicalizer.Rule.MatchStrategy = .literal

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
        TranscriptCanonicalizer.Rule(
            canonical: trimmedCanonical,
            aliases: aliases,
            contexts: contexts,
            matchStrategy: matchStrategy
        )
    }

    static func empty() -> CorrectionDraft {
        CorrectionDraft(aliasesText: "", canonical: "", contextsText: "")
    }

    static func fromRules(_ rules: [TranscriptCanonicalizer.Rule]) -> [CorrectionDraft] {
        rules.map { rule in
            CorrectionDraft(
                aliasesText: rule.aliases.joined(separator: ", "),
                canonical: rule.canonical,
                contextsText: rule.contexts.joined(separator: ", "),
                matchStrategy: rule.matchStrategy
            )
        }
    }

    /// Drafts present in `loaded` but absent (by content) from `existing` — the
    /// rows a just-accepted suggestion added to the store. Lets the editor merge
    /// an accepted suggestion into both `rows` and `savedRows` without a full
    /// reload, which would discard the user's unsaved edits and reorders.
    static func newDrafts(
        in loaded: [CorrectionDraft],
        notIn existing: [CorrectionDraft]
    ) -> [CorrectionDraft] {
        loaded.filter { draft in !existing.contains(draft) }
    }

    private static func parseList(_ text: String) -> [String] {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func == (lhs: CorrectionDraft, rhs: CorrectionDraft) -> Bool {
        lhs.aliasesText == rhs.aliasesText &&
            lhs.canonical == rhs.canonical &&
            lhs.contextsText == rhs.contextsText &&
            lhs.matchStrategy == rhs.matchStrategy
    }
}
