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
                  let candidate = phraseReplacement(from: item.finalInsertedTranscript, to: edited) else {
                continue
            }

            let key = "\(normalizedPhrase(candidate.alias))->\(normalizedPhrase(candidate.canonical))"
            guard seen.insert(key).inserted else { continue }

            suggestions.append(CorrectionRecord(
                id: "suggested.\(slug(candidate.alias)).to-\(slug(candidate.canonical))",
                kind: .replacement,
                canonical: candidate.canonical,
                aliases: [candidate.alias],
                source: .suggested,
                status: .suggested
            ))
        }

        return suggestions
    }

    private static func phraseReplacement(
        from observed: String,
        to edited: String
    ) -> (alias: String, canonical: String)? {
        let observedWords = words(in: observed)
        let editedWords = words(in: edited)
        guard !observedWords.isEmpty, !editedWords.isEmpty else { return nil }
        guard observedWords != editedWords else { return nil }

        var prefixCount = 0
        while prefixCount < observedWords.count,
              prefixCount < editedWords.count,
              observedWords[prefixCount] == editedWords[prefixCount] {
            prefixCount += 1
        }

        var suffixCount = 0
        while suffixCount < observedWords.count - prefixCount,
              suffixCount < editedWords.count - prefixCount,
              observedWords[observedWords.count - 1 - suffixCount] == editedWords[editedWords.count - 1 - suffixCount] {
            suffixCount += 1
        }

        let observedEnd = observedWords.count - suffixCount
        let editedEnd = editedWords.count - suffixCount
        let alias = observedWords[prefixCount..<observedEnd].joined(separator: " ")
        let canonical = editedWords[prefixCount..<editedEnd].joined(separator: " ")
        guard !alias.isEmpty, !canonical.isEmpty else { return nil }
        guard normalizedPhrase(alias) != normalizedPhrase(canonical) else { return nil }
        return (alias: alias, canonical: canonical)
    }

    private static func words(in text: String) -> [String] {
        text.split { $0.isWhitespace }.map(String.init)
    }

    private static func normalizedPhrase(_ phrase: String) -> String {
        phrase
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: " ")
    }

    private static func slug(_ phrase: String) -> String {
        let slug = normalizedPhrase(phrase).replacingOccurrences(of: " ", with: "-")
        return slug.isEmpty ? "replacement" : slug
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
