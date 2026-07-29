import Foundation

struct CorrectionDraft: Identifiable, Equatable {
    var id = UUID()
    var recordID: String?
    var recordKind: CorrectionRecord.Kind = .replacement
    var recordLexiconClass: CorrectionRecord.LexiconClass = .generic
    var recordSource: CorrectionRecord.Source = .manual
    var recordStatus: CorrectionRecord.Status = .active
    var aliasesText: String
    var safeAliasesText: String = ""
    var canonical: String
    var contextsText: String
    var matchStrategy: TranscriptCanonicalizer.Rule.MatchStrategy = .literal

    var trimmedCanonical: String {
        canonical.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var aliases: [String] {
        Self.parseList(aliasesText)
    }

    var safeAliases: [String] {
        Self.parseList(safeAliasesText)
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
            aliases: matchStrategy == .literal ? safeAliases + aliases : aliases,
            contexts: contexts,
            matchStrategy: matchStrategy
        )
    }

    var record: CorrectionRecord {
        let isPerson = matchStrategy == .personNameSlot
        return CorrectionRecord(
            id: recordID ?? "manual.editor.\(id.uuidString.lowercased())",
            kind: isPerson ? .lexicon : recordKind,
            canonical: trimmedCanonical,
            aliases: isPerson ? safeAliases : safeAliases + aliases,
            ambiguousAliases: isPerson ? aliases : [],
            contexts: contexts,
            lexiconClass: isPerson ? .person : recordLexiconClass,
            source: recordSource,
            status: recordStatus
        )
    }

    static func empty() -> CorrectionDraft {
        CorrectionDraft(aliasesText: "", canonical: "", contextsText: "")
    }

    static func fromRules(_ rules: [TranscriptCanonicalizer.Rule]) -> [CorrectionDraft] {
        rules.map { rule in
            CorrectionDraft(
                aliasesText: formatList(rule.aliases),
                canonical: rule.canonical,
                contextsText: formatList(rule.contexts),
                matchStrategy: rule.matchStrategy
            )
        }
    }

    static func fromRecords(_ records: [CorrectionRecord]) -> [CorrectionDraft] {
        records.compactMap { record in
            guard record.status == .active,
                  !CorrectionRuleCompiler.compile(records: [record]).isEmpty else {
                return nil
            }

            let isPerson = record.kind == .lexicon &&
                record.lexiconClass == .person &&
                !record.ambiguousAliases.isEmpty
            return CorrectionDraft(
                recordID: record.id,
                recordKind: record.kind,
                recordLexiconClass: record.lexiconClass,
                recordSource: record.source,
                recordStatus: record.status,
                aliasesText: formatList(isPerson ? record.ambiguousAliases : record.aliases),
                safeAliasesText: isPerson ? formatList(record.aliases) : "",
                canonical: record.canonical,
                contextsText: formatList(record.contexts),
                matchStrategy: isPerson ? .personNameSlot : .literal
            )
        }
    }

    /// Drafts present in `loaded` but absent (by record identity) from `existing` — the
    /// rows a just-accepted suggestion added to the store. Lets the editor merge
    /// an accepted suggestion into both `rows` and `savedRows` without a full
    /// reload, which would discard the user's unsaved edits and reorders.
    static func newDrafts(
        in loaded: [CorrectionDraft],
        notIn existing: [CorrectionDraft]
    ) -> [CorrectionDraft] {
        let existingRecordIDs = Set(existing.compactMap(\.recordID))
        return loaded.filter { draft in
            if let recordID = draft.recordID {
                return !existingRecordIDs.contains(recordID)
            }
            return !existing.contains(draft)
        }
    }

    func adoptingRecordIdentity(from stored: CorrectionDraft) -> CorrectionDraft {
        var result = self
        result.recordID = stored.recordID
        result.recordKind = stored.recordKind
        result.recordLexiconClass = stored.recordLexiconClass
        result.recordSource = stored.recordSource
        result.recordStatus = stored.recordStatus
        return result
    }

    private static func parseList(_ text: String) -> [String] {
        var values: [String] = []
        var current = ""
        var isEscaping = false

        func appendCurrent() {
            let value = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                values.append(value)
            }
            current = ""
        }

        for character in text {
            if isEscaping {
                if character != "\\" && character != "," {
                    current.append("\\")
                }
                current.append(character)
                isEscaping = false
            } else if character == "\\" {
                isEscaping = true
            } else if character == "," {
                appendCurrent()
            } else {
                current.append(character)
            }
        }
        if isEscaping {
            current.append("\\")
        }
        appendCurrent()
        return values
    }

    private static func formatList(_ values: [String]) -> String {
        values.map { value in
            value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: ",", with: "\\,")
        }
        .joined(separator: ", ")
    }

    static func == (lhs: CorrectionDraft, rhs: CorrectionDraft) -> Bool {
        lhs.aliasesText == rhs.aliasesText &&
            lhs.safeAliasesText == rhs.safeAliasesText &&
            lhs.canonical == rhs.canonical &&
            lhs.contextsText == rhs.contextsText &&
            lhs.matchStrategy == rhs.matchStrategy
    }
}
