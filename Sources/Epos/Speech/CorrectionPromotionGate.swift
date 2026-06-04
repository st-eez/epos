import Foundation

public enum CorrectionPromotionRisk: String, Equatable, Sendable {
    case low
    case medium
    case high
}

public enum CorrectionPromotionBlocker: String, Equatable, Sendable {
    case notSuggestedRecord
    case insufficientRecurrence
    case negativeExamples
    case conflictingSuggestions
    case highPhraseRisk
    case highScopeRisk
    case lockedBaselineRegression
}

public struct CorrectionPromotionAssessment: Equatable, Sendable {
    public var record: CorrectionRecord
    public var positiveEvidenceIDs: [String]
    public var negativeEvidenceIDs: [String]
    public var conflictingEvidenceIDs: [String]
    public var lockedBaselineRegressions: [String]
    public var phraseRisk: CorrectionPromotionRisk
    public var scopeRisk: CorrectionPromotionRisk
    public var blockers: [CorrectionPromotionBlocker]

    public var canPromote: Bool {
        blockers.isEmpty
    }

    public var promotedRecord: CorrectionRecord? {
        guard canPromote else { return nil }

        var promoted = record
        promoted.status = .active
        return promoted
    }
}

public enum CorrectionPromotionGate {
    public static func assess(
        record: CorrectionRecord,
        evidence: [CorrectionEvidence],
        activeRecords: [CorrectionRecord] = CorrectionDictionary.defaultRecords,
        lockedBaselineTexts: [String] = [],
        minimumPositiveEvidenceCount: Int = 2
    ) -> CorrectionPromotionAssessment {
        let matches = evidenceMatches(for: record, evidence: evidence)
        let distinctPositive = distinctEvidence(matches.positive)
        let distinctNegative = distinctEvidence(matches.negative)
        let distinctConflicting = distinctEvidence(matches.conflicting)
        let phraseRisk = phraseRisk(for: record)
        let scopeRisk = scopeRisk(positiveEvidence: distinctPositive, conflictingEvidence: distinctConflicting)
        let lockedRegressions = lockedBaselineRegressions(
            record: record,
            activeRecords: activeRecords,
            lockedBaselineTexts: lockedBaselineTexts
        )
        let blockers = blockers(
            record: record,
            positiveEvidenceCount: distinctPositive.count,
            negativeEvidenceCount: distinctNegative.count,
            conflictingEvidenceCount: distinctConflicting.count,
            phraseRisk: phraseRisk,
            scopeRisk: scopeRisk,
            lockedBaselineRegressionCount: lockedRegressions.count,
            minimumPositiveEvidenceCount: max(1, minimumPositiveEvidenceCount)
        )

        return CorrectionPromotionAssessment(
            record: record,
            positiveEvidenceIDs: distinctPositive.map(\.id),
            negativeEvidenceIDs: distinctNegative.map(\.id),
            conflictingEvidenceIDs: distinctConflicting.map(\.id),
            lockedBaselineRegressions: lockedRegressions,
            phraseRisk: phraseRisk,
            scopeRisk: scopeRisk,
            blockers: blockers
        )
    }

    private static func evidenceMatches(
        for record: CorrectionRecord,
        evidence: [CorrectionEvidence]
    ) -> (positive: [CorrectionEvidence], negative: [CorrectionEvidence], conflicting: [CorrectionEvidence]) {
        let aliases = Set(record.aliases.map(CorrectionPhraseDiff.normalizedPhrase))
        let canonical = CorrectionPhraseDiff.normalizedPhrase(record.canonical)

        var positive: [CorrectionEvidence] = []
        var negative: [CorrectionEvidence] = []
        var conflicting: [CorrectionEvidence] = []

        for item in evidence {
            guard let edited = item.userEditedTranscript else { continue }

            if CorrectionPhraseDiff.normalizedPhrase(edited) == CorrectionPhraseDiff.normalizedPhrase(item.finalInsertedTranscript),
               record.aliases.contains(where: { CorrectionPhraseDiff.containsPhrase($0, in: item.finalInsertedTranscript) }) {
                negative.append(item)
                continue
            }

            guard let replacement = CorrectionPhraseDiff.replacement(from: item.finalInsertedTranscript, to: edited),
                  aliases.contains(replacement.normalizedAlias) else {
                continue
            }

            if replacement.normalizedCanonical == canonical {
                positive.append(item)
            } else {
                conflicting.append(item)
            }
        }

        return (positive, negative, conflicting)
    }

    private static func phraseRisk(for record: CorrectionRecord) -> CorrectionPromotionRisk {
        guard !record.aliases.isEmpty else { return .high }

        let aliasRisks = record.aliases.map { alias -> CorrectionPromotionRisk in
            let words = CorrectionPhraseDiff.words(in: CorrectionPhraseDiff.normalizedPhrase(alias))
            guard let firstWord = words.first else { return .high }
            if words.count == 1 && (firstWord.count <= 3 || ambiguousSingleWords.contains(firstWord)) {
                return .high
            }
            if words.count == 1 {
                return .medium
            }
            return .low
        }

        if aliasRisks.contains(.high) { return .high }
        if aliasRisks.contains(.medium) { return .medium }
        return .low
    }

    private static func scopeRisk(
        positiveEvidence: [CorrectionEvidence],
        conflictingEvidence: [CorrectionEvidence]
    ) -> CorrectionPromotionRisk {
        if !conflictingEvidence.isEmpty { return .high }

        let bundleIDs = Set(positiveEvidence.compactMap { evidence -> String? in
            let bundleID = evidence.applicationBundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
            return bundleID?.isEmpty == false ? bundleID : nil
        })
        if bundleIDs.count == 1 { return .medium }
        return .low
    }

    private static func lockedBaselineRegressions(
        record: CorrectionRecord,
        activeRecords: [CorrectionRecord],
        lockedBaselineTexts: [String]
    ) -> [String] {
        guard !lockedBaselineTexts.isEmpty else { return [] }

        let baselineCanonicalizer = TranscriptCanonicalizer(
            rules: CorrectionRuleCompiler.compile(records: activeRecords)
        )
        var promoted = record
        promoted.status = .active
        let promotedCanonicalizer = TranscriptCanonicalizer(
            rules: CorrectionRuleCompiler.compile(records: activeRecords + [promoted])
        )

        return lockedBaselineTexts.filter { text in
            baselineCanonicalizer.canonicalize(text) != promotedCanonicalizer.canonicalize(text)
        }
    }

    private static func blockers(
        record: CorrectionRecord,
        positiveEvidenceCount: Int,
        negativeEvidenceCount: Int,
        conflictingEvidenceCount: Int,
        phraseRisk: CorrectionPromotionRisk,
        scopeRisk: CorrectionPromotionRisk,
        lockedBaselineRegressionCount: Int,
        minimumPositiveEvidenceCount: Int
    ) -> [CorrectionPromotionBlocker] {
        var blockers: [CorrectionPromotionBlocker] = []

        if record.status != .suggested {
            blockers.append(.notSuggestedRecord)
        }
        if positiveEvidenceCount < minimumPositiveEvidenceCount {
            blockers.append(.insufficientRecurrence)
        }
        if negativeEvidenceCount > 0 {
            blockers.append(.negativeExamples)
        }
        if conflictingEvidenceCount > 0 {
            blockers.append(.conflictingSuggestions)
        }
        if phraseRisk == .high {
            blockers.append(.highPhraseRisk)
        }
        if scopeRisk == .high {
            blockers.append(.highScopeRisk)
        }
        if lockedBaselineRegressionCount > 0 {
            blockers.append(.lockedBaselineRegression)
        }

        return blockers
    }

    private static func distinctEvidence(_ evidence: [CorrectionEvidence]) -> [CorrectionEvidence] {
        var seen: Set<String> = []
        return evidence.filter { item in
            seen.insert(evidenceIdentity(item)).inserted
        }
    }

    private static func evidenceIdentity(_ evidence: CorrectionEvidence) -> String {
        let recordingID = evidence.recordingID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let recordingID, !recordingID.isEmpty {
            return "recording:\(recordingID)"
        }

        return "evidence:\(evidence.id)"
    }

    private static let ambiguousSingleWords: Set<String> = [
        "a",
        "an",
        "and",
        "as",
        "at",
        "be",
        "by",
        "for",
        "in",
        "is",
        "it",
        "of",
        "on",
        "or",
        "so",
        "the",
        "to"
    ]
}
