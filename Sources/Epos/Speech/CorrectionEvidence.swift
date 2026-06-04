import Foundation

public struct CorrectionEvidence: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var observedAt: Date
    public var recordingID: String?
    public var rawTranscript: String
    public var canonicalizedTranscript: String
    public var finalInsertedTranscript: String
    public var userEditedTranscript: String?
    public var applicationBundleIdentifier: String?
    public var windowTitle: String?
    public var urlString: String?
    public var appliedRuleIDs: [String]
    public var polishOutcome: String
    public var engineOutcome: String?
    public var guardRejectionReason: String?

    public init(
        id: String,
        observedAt: Date,
        recordingID: String?,
        rawTranscript: String,
        canonicalizedTranscript: String,
        finalInsertedTranscript: String,
        userEditedTranscript: String?,
        applicationBundleIdentifier: String? = nil,
        windowTitle: String? = nil,
        urlString: String? = nil,
        appliedRuleIDs: [String],
        polishOutcome: String,
        engineOutcome: String?,
        guardRejectionReason: String?
    ) {
        self.id = id
        self.observedAt = observedAt
        self.recordingID = recordingID
        self.rawTranscript = rawTranscript
        self.canonicalizedTranscript = canonicalizedTranscript
        self.finalInsertedTranscript = finalInsertedTranscript
        self.userEditedTranscript = userEditedTranscript
        self.applicationBundleIdentifier = applicationBundleIdentifier
        self.windowTitle = windowTitle
        self.urlString = urlString
        self.appliedRuleIDs = appliedRuleIDs
        self.polishOutcome = polishOutcome
        self.engineOutcome = engineOutcome
        self.guardRejectionReason = guardRejectionReason
    }
}

public final class CorrectionEvidenceStore {
    public static let evidenceDefaultsKey = "settings.correctionEvidence.recordsJSON"
    private static let storedEvidenceVersion = 1

    public private(set) var evidence: [CorrectionEvidence]

    private let defaults: UserDefaults
    private let maxEvidenceCount: Int

    public init(defaults: UserDefaults = .standard, maxEvidenceCount: Int = 200) {
        self.defaults = defaults
        self.maxEvidenceCount = max(1, maxEvidenceCount)
        self.evidence = Self.loadEvidence(from: defaults)
    }

    public var suggestedRecords: [CorrectionRecord] {
        CorrectionCandidateSuggester.suggestedRecords(from: evidence)
    }

    public var promotionAssessments: [CorrectionPromotionAssessment] {
        suggestedRecords.map { record in
            CorrectionPromotionGate.assess(record: record, evidence: evidence)
        }
    }

    public func record(_ item: CorrectionEvidence) {
        evidence.append(item)
        if evidence.count > maxEvidenceCount {
            evidence = Array(evidence.suffix(maxEvidenceCount))
        }
        save()
    }

    private func save() {
        let storedEvidence = StoredEvidence(version: Self.storedEvidenceVersion, evidence: evidence)
        guard let data = try? JSONEncoder().encode(storedEvidence) else { return }
        defaults.set(String(decoding: data, as: UTF8.self), forKey: Self.evidenceDefaultsKey)
    }

    private static func loadEvidence(from defaults: UserDefaults) -> [CorrectionEvidence] {
        guard let rawEvidence = defaults.string(forKey: evidenceDefaultsKey),
              let data = rawEvidence.data(using: .utf8),
              let storedEvidence = try? JSONDecoder().decode(StoredEvidence.self, from: data) else {
            return []
        }
        return storedEvidence.evidence
    }
}

private extension CorrectionEvidenceStore {
    struct StoredEvidence: Codable {
        var version: Int
        var evidence: [CorrectionEvidence]
    }
}

public enum CorrectionCandidateSuggester {
    public static func suggestedRecords(from evidence: [CorrectionEvidence]) -> [CorrectionRecord] {
        var suggestions: [CorrectionRecord] = []
        var seen: Set<String> = []

        for item in evidence {
            guard let edited = item.userEditedTranscript,
                  let candidate = CorrectionPhraseDiff.replacement(
                    from: item.finalInsertedTranscript,
                    to: edited
                  ) else {
                continue
            }

            guard seen.insert(candidate.key).inserted else { continue }

            suggestions.append(CorrectionRecord(
                id: "suggested.\(candidate.aliasSlug).to-\(candidate.canonicalSlug)",
                kind: .replacement,
                canonical: candidate.canonical,
                aliases: [candidate.alias],
                source: .suggested,
                status: .suggested
            ))
        }

        return suggestions
    }
}

extension PolishOutcome {
    var evidenceName: String {
        switch self {
        case .disabled: "disabled"
        case .unavailable: "unavailable"
        case .timedOut: "timed-out"
        case .tooLong: "too-long"
        case .sameText: "same-text"
        case .guardRejected: "guard-rejected"
        case .deterministicCleanup: "deterministic-cleanup"
        case .engineFailed: "engine-failed"
        case .abandoned: "abandoned"
        case .suppressedByInsertion: "suppressed-by-insertion"
        case .applied: "applied"
        }
    }
}
