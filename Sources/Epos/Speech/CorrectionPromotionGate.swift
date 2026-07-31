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
    case lockedBaselineUnavailable
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

/// The outcome of replaying a candidate against the locked baseline. Kept separate from
/// the full assessment because it is the half that depends on the dictionary rather than
/// on evidence, so it can be re-run at the moment a promotion is committed.
public struct CorrectionLockedBaselineCheck: Equatable, Sendable {
    public var regressions: [String]
    public var blockers: [CorrectionPromotionBlocker]

    public var passes: Bool {
        blockers.isEmpty
    }
}

public enum CorrectionPromotionGate {
    /// `activeRecords` and `lockedBaseline` are deliberately not defaulted: a caller that
    /// forgets them would score the candidate against the built-in dictionary and skip
    /// the corpus check entirely, which is how the locked-baseline blocker became
    /// unreachable in the app.
    public static func assess(
        record: CorrectionRecord,
        evidence: [CorrectionEvidence],
        activeRecords: [CorrectionRecord],
        lockedBaseline: CorrectionLockedBaseline,
        minimumPositiveEvidenceCount: Int = 2
    ) -> CorrectionPromotionAssessment {
        let matches = evidenceMatches(for: record, evidence: evidence)
        let distinctPositive = distinctEvidence(matches.positive)
        let distinctNegative = distinctEvidence(matches.negative)
        let distinctConflicting = distinctEvidence(matches.conflicting)
        let phraseRisk = phraseRisk(for: record)
        let scopeRisk = scopeRisk(positiveEvidence: distinctPositive, conflictingEvidence: distinctConflicting)
        let lockedCheck = lockedBaselineCheck(
            record: record,
            activeRecords: activeRecords,
            lockedBaseline: lockedBaseline
        )
        let blockers = blockers(
            record: record,
            positiveEvidenceCount: distinctPositive.count,
            negativeEvidenceCount: distinctNegative.count,
            conflictingEvidenceCount: distinctConflicting.count,
            phraseRisk: phraseRisk,
            scopeRisk: scopeRisk,
            lockedBaselineBlockers: lockedCheck.blockers,
            minimumPositiveEvidenceCount: max(1, minimumPositiveEvidenceCount)
        )

        return CorrectionPromotionAssessment(
            record: record,
            positiveEvidenceIDs: distinctPositive.map(\.id),
            negativeEvidenceIDs: distinctNegative.map(\.id),
            conflictingEvidenceIDs: distinctConflicting.map(\.id),
            lockedBaselineRegressions: lockedCheck.regressions,
            phraseRisk: phraseRisk,
            scopeRisk: scopeRisk,
            blockers: blockers
        )
    }

    /// Replays the candidate over the locked baseline against a given dictionary.
    /// An assessment is scored when the suggestion list is built; the dictionary can
    /// change before the user clicks Accept, so the committing side re-runs this.
    public static func lockedBaselineCheck(
        record: CorrectionRecord,
        activeRecords: [CorrectionRecord],
        lockedBaseline: CorrectionLockedBaseline
    ) -> CorrectionLockedBaselineCheck {
        guard case .confirmed(let texts) = lockedBaseline else {
            return CorrectionLockedBaselineCheck(regressions: [], blockers: [.lockedBaselineUnavailable])
        }

        let regressions = lockedBaselineRegressions(
            record: record,
            activeRecords: activeRecords,
            lockedBaselineTexts: texts
        )
        return CorrectionLockedBaselineCheck(
            regressions: regressions,
            blockers: regressions.isEmpty ? [] : [.lockedBaselineRegression]
        )
    }

    private static func evidenceMatches(
        for record: CorrectionRecord,
        evidence: [CorrectionEvidence]
    ) -> (positive: [CorrectionEvidence], negative: [CorrectionEvidence], conflicting: [CorrectionEvidence]) {
        let aliases = Set(record.aliases.map(CorrectionMatchContext.normalizedPhrase))
        let canonical = CorrectionMatchContext.normalizedPhrase(record.canonical)

        var positive: [CorrectionEvidence] = []
        var negative: [CorrectionEvidence] = []
        var conflicting: [CorrectionEvidence] = []

        for item in evidence {
            guard let edited = item.userEditedTranscript else { continue }

            if CorrectionMatchContext.normalizedPhrase(edited)
                == CorrectionMatchContext.normalizedPhrase(item.finalInsertedTranscript),
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
            let words = CorrectionPhraseDiff.words(in: CorrectionMatchContext.normalizedPhrase(alias))
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
        lockedBaselineBlockers: [CorrectionPromotionBlocker],
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
        blockers.append(contentsOf: lockedBaselineBlockers)

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
