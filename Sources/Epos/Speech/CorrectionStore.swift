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

    public func canonicalize(_ text: String) -> String {
        canonicalizer.canonicalize(text)
    }

    /// Persist `rules` and refresh the live canonicalizer so the next insertion uses them.
    public func save(_ rules: [TranscriptCanonicalizer.Rule]) {
        let records = CorrectionDictionary.records(from: rules)
        TranscriptCanonicalizer.saveRules(rules, to: defaults)
        dictionary = CorrectionDictionary(records: records)
        canonicalizer = TranscriptCanonicalizer(
            rules: CorrectionRuleCompiler.compile(records: dictionary.records)
        )
    }

    @discardableResult
    public func acceptPromotion(_ assessment: CorrectionPromotionAssessment) -> Bool {
        guard let promotedRecord = assessment.promotedRecord else { return false }

        if let index = dictionary.records.firstIndex(where: { $0.id == promotedRecord.id }) {
            dictionary.records[index] = promotedRecord
        } else {
            dictionary.records.append(promotedRecord)
        }

        CorrectionDictionary.saveRecords(dictionary.records, to: defaults)
        canonicalizer = TranscriptCanonicalizer(
            rules: CorrectionRuleCompiler.compile(records: dictionary.records)
        )
        return true
    }
}
