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
    public var isReadOnly: Bool { dictionary.isReadOnly }

    public var resolvedSuggestionRecordIDs: Set<String> {
        Set(dictionary.records.compactMap { record in
            guard record.source == .suggested, record.status != .suggested else { return nil }
            return record.id
        })
    }

    public func canonicalize(_ text: String) -> String {
        canonicalizer.canonicalize(text)
    }

    /// Persist editor-owned records without flattening stable record identity and
    /// person lexicons through the runtime `Rule` representation.
    public func saveEditorRecords(_ records: [CorrectionRecord]) {
        guard !isReadOnly else { return }
        let visibleRecordIDs = Set(dictionary.records.compactMap { record -> String? in
            guard record.status == .active,
                  !CorrectionRuleCompiler.compile(records: [record]).isEmpty else {
                return nil
            }
            return record.id
        })
        let editedIDs = Set(records.map(\.id))
        let hiddenRecords = dictionary.records.filter {
            !visibleRecordIDs.contains($0.id) && !editedIDs.contains($0.id)
        }
        let savedRecords = records + hiddenRecords

        guard CorrectionDictionary.saveRecords(savedRecords, to: defaults) else { return }
        dictionary = CorrectionDictionary(records: savedRecords)
        canonicalizer = TranscriptCanonicalizer(
            rules: CorrectionRuleCompiler.compile(records: savedRecords)
        )
    }

    @discardableResult
    public func acceptPromotion(_ assessment: CorrectionPromotionAssessment) -> Bool {
        guard !isReadOnly else { return false }
        guard let promotedRecord = assessment.promotedRecord else { return false }
        if let existing = dictionary.records.first(where: { $0.id == assessment.record.id }),
           existing.source == .suggested,
           existing.status != .suggested {
            return false
        }

        if hasEquivalentActiveRecord(to: promotedRecord) {
            var resolvedMarker = assessment.record
            resolvedMarker.status = .disabled
            upsertRecord(resolvedMarker)
            return true
        }

        upsertRecord(promotedRecord)
        return true
    }

    @discardableResult
    public func rejectSuggestion(_ assessment: CorrectionPromotionAssessment) -> Bool {
        guard !isReadOnly else { return false }
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

        guard CorrectionDictionary.saveRecords(dictionary.records, to: defaults) else { return }
        canonicalizer = TranscriptCanonicalizer(
            rules: CorrectionRuleCompiler.compile(records: dictionary.records)
        )
    }

    private func hasEquivalentActiveRecord(to record: CorrectionRecord) -> Bool {
        let rules = CorrectionRuleCompiler.compile(records: [record])
        guard !rules.isEmpty else { return false }
        return dictionary.records.contains { candidate in
            candidate.id != record.id &&
                candidate.status == .active &&
                CorrectionRuleCompiler.compile(records: [candidate]) == rules
        }
    }

}
