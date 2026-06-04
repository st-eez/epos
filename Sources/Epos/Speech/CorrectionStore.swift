import Foundation

/// Single in-memory source of truth for correction rules, shared by the coordinator
/// (which canonicalizes each final transcript) and the Corrections editor (which mutates
/// the rules). Backed by `UserDefaults` but loaded once — replacing the prior design where
/// the coordinator re-decoded rules from defaults on every insertion and the editor reached it
/// only through that global side channel.
@MainActor
public final class CorrectionStore: ObservableObject {
    @Published public private(set) var canonicalizer: TranscriptCanonicalizer
    public private(set) var dictionary: CorrectionDictionary
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.dictionary = CorrectionDictionary.load(from: defaults)
        self.canonicalizer = TranscriptCanonicalizer(
            rules: CorrectionRuleCompiler.compile(records: dictionary.records)
        )
    }

    public var rules: [TranscriptCanonicalizer.Rule] { canonicalizer.rules }

    public var resolvedSuggestionRecordIDs: Set<String> {
        Set(dictionary.records.compactMap { record in
            guard record.source == .suggested, record.status != .suggested else { return nil }
            return record.id
        })
    }

    public func canonicalize(_ text: String) -> String {
        canonicalizer.canonicalize(text)
    }

    /// Persist `rules` and refresh the live canonicalizer so the next insertion uses them.
    public func save(_ rules: [TranscriptCanonicalizer.Rule]) {
        let records = recordsPreservingResolvedSuggestions(from: rules)
        TranscriptCanonicalizer.saveRules(rules, to: defaults)
        CorrectionDictionary.saveRecords(records, to: defaults)
        dictionary = CorrectionDictionary(records: records)
        canonicalizer = TranscriptCanonicalizer(
            rules: CorrectionRuleCompiler.compile(records: dictionary.records)
        )
    }

    @discardableResult
    public func acceptPromotion(_ assessment: CorrectionPromotionAssessment) -> Bool {
        guard let promotedRecord = assessment.promotedRecord else { return false }
        if let existing = dictionary.records.first(where: { $0.id == assessment.record.id }),
           existing.source == .suggested,
           existing.status != .suggested {
            return false
        }

        upsertRecord(promotedRecord)
        return true
    }

    @discardableResult
    public func rejectSuggestion(_ assessment: CorrectionPromotionAssessment) -> Bool {
        guard assessment.record.status == .suggested else { return false }
        if let existing = dictionary.records.first(where: { $0.id == assessment.record.id }),
           existing.status == .active {
            return false
        }

        var rejectedRecord = assessment.record
        rejectedRecord.status = .rejected
        upsertRecord(rejectedRecord)
        return true
    }

    private func upsertRecord(_ record: CorrectionRecord) {
        if let index = dictionary.records.firstIndex(where: { $0.id == record.id }) {
            dictionary.records[index] = record
        } else {
            dictionary.records.append(record)
        }

        CorrectionDictionary.saveRecords(dictionary.records, to: defaults)
        canonicalizer = TranscriptCanonicalizer(
            rules: CorrectionRuleCompiler.compile(records: dictionary.records)
        )
    }

    private func recordsPreservingResolvedSuggestions(
        from rules: [TranscriptCanonicalizer.Rule]
    ) -> [CorrectionRecord] {
        var records = CorrectionDictionary.records(from: rules)
        let resolvedSuggestions = dictionary.records.filter { record in
            record.source == .suggested && record.status != .suggested
        }

        for suggestion in resolvedSuggestions {
            if let index = records.firstIndex(where: { $0.id == suggestion.id }) {
                records[index] = suggestion
                continue
            }

            if let rule = CorrectionRuleCompiler.compile(records: [suggestion]).first,
               let equivalentIndex = records.firstIndex(where: { candidate in
                   candidate.source != .builtIn &&
                       CorrectionRuleCompiler.compile(records: [candidate]).first == rule
               }) {
                records[equivalentIndex] = suggestion
                continue
            }

            records.append(suggestion)
        }

        return records
    }
}
