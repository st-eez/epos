import Foundation

struct CorrectionSuggestionReviewItem: Identifiable, Equatable {
    let assessment: CorrectionPromotionAssessment
    let evidenceExample: CorrectionEvidence?

    var id: String { assessment.record.id }
    var heardPhrase: String { assessment.record.aliases.joined(separator: ", ") }
    var replacementText: String { assessment.record.canonical }
    var positiveEvidenceIDs: [String] { assessment.positiveEvidenceIDs }
    var positiveEvidenceCount: Int { assessment.positiveEvidenceIDs.count }
    var canAccept: Bool { assessment.canPromote }
    var blockerNames: [String] { assessment.blockers.map(\.rawValue) }
    var phraseRiskName: String { assessment.phraseRisk.rawValue }
    var scopeRiskName: String { assessment.scopeRisk.rawValue }
    var evidenceExampleText: String? {
        guard let evidenceExample,
              let userEditedTranscript = evidenceExample.userEditedTranscript else {
            return nil
        }

        return "\(Self.preview(evidenceExample.finalInsertedTranscript)) -> \(Self.preview(userEditedTranscript))"
    }
    var evidenceContextText: String? {
        guard let evidenceExample else { return nil }
        return [evidenceExample.applicationBundleIdentifier, evidenceExample.windowTitle]
            .compactMap(Self.nonEmptyValue)
            .joined(separator: " - ")
            .nilIfEmpty
    }

    static func items(
        assessments: [CorrectionPromotionAssessment],
        evidence: [CorrectionEvidence],
        resolvedRecordIDs: Set<String>
    ) -> [CorrectionSuggestionReviewItem] {
        assessments.compactMap { assessment in
            guard !resolvedRecordIDs.contains(assessment.record.id) else { return nil }
            return CorrectionSuggestionReviewItem(
                assessment: assessment,
                evidenceExample: evidenceExample(for: assessment, evidence: evidence)
            )
        }
    }

    @MainActor
    static func items(
        evidenceStore: CorrectionEvidenceStore,
        store: CorrectionStore
    ) -> [CorrectionSuggestionReviewItem] {
        items(
            assessments: evidenceStore.promotionAssessments,
            evidence: evidenceStore.evidence,
            resolvedRecordIDs: store.resolvedSuggestionRecordIDs
        )
    }

    private static func evidenceExample(
        for assessment: CorrectionPromotionAssessment,
        evidence: [CorrectionEvidence]
    ) -> CorrectionEvidence? {
        guard let evidenceID = assessment.positiveEvidenceIDs.first else { return nil }
        return evidence.first { $0.id == evidenceID }
    }

    private static func preview(_ text: String, limit: Int = 90) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(max(0, limit - 3))) + "..."
    }

    private static func nonEmptyValue(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
