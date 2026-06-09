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

    @discardableResult
    public func record(_ item: CorrectionEvidence) -> String {
        evidence.append(item)
        if evidence.count > maxEvidenceCount {
            evidence = Array(evidence.suffix(maxEvidenceCount))
        }
        save()
        return item.id
    }

    @discardableResult
    public func recordUserEdit(evidenceID: String, userEditedTranscript: String) -> Bool {
        guard let index = evidence.firstIndex(where: { $0.id == evidenceID }),
              evidence[index].finalInsertedTranscript != userEditedTranscript else {
            return false
        }

        evidence[index].userEditedTranscript = userEditedTranscript
        save()
        return true
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

/// Boundary validation for AX read-backs before they are stored as user edits.
/// The observe-window timer can read the target field while it is cleared, while
/// focus has moved, or while the user is mid-edit; storing those reads pollutes
/// the evidence store (bug-hunt 2026-06-09 P2 #3/#4). The gate is deliberately
/// conservative: false-rejecting a real correction only delays alias promotion
/// (recurrence >= 2 is required anyway), while false-accepting writes garbage.
public enum ObservedUserEditFilter {
    public static func validatedEdit(observed: String, final: String) -> String? {
        // Splitting on Unicode whitespace (which includes U+00A0 NBSP, seen in
        // real record 7dae3556) normalizes whitespace so it can't defeat the
        // prefix test below.
        let observedWords = whitespaceSeparatedWords(in: observed)

        // An observed text that trims to empty means the field was cleared,
        // focus moved, or the target is AX-opaque — "not read", not "edited
        // to empty". Storing it would destroy the nil "no edit observed" signal.
        guard !observedWords.isEmpty else { return nil }

        let finalWords = whitespaceSeparatedWords(in: final)

        // A read whose words are a leading prefix of the final's words is a
        // deletion-in-progress (or a whitespace-only echo), not a correction.
        if observedWords.count <= finalWords.count,
           Array(finalWords.prefix(observedWords.count)) == observedWords {
            return nil
        }

        // A read with fewer than half the final's words is far more likely a
        // mid-edit snapshot than a correction: corrections observed in real
        // evidence swap or fuse words roughly in place, while the one real
        // mid-edit capture (7 of 16 words, with a typo that defeats the strict
        // prefix test) lost over half the text. Half is the loosest threshold
        // that rejects that record while keeping spoken-punctuation
        // corrections like "are you sure question mark" -> "are you sure?".
        if observedWords.count * 2 < finalWords.count {
            return nil
        }

        return observed
    }

    private static func whitespaceSeparatedWords(in text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
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
