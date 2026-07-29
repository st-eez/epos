import Foundation

enum SpeechContextApplicationMode: String, Codable {
    case setContextBeforeStart
    case initializer
}

struct SpeechContextEvalVariant {
    let name: String
    let contextualStrings: [String]
    let applicationMode: SpeechContextApplicationMode
    let includeAlternatives: Bool

    init(
        name: String,
        contextualStrings: [String],
        applicationMode: SpeechContextApplicationMode = .setContextBeforeStart,
        includeAlternatives: Bool = false
    ) {
        self.name = name
        self.contextualStrings = contextualStrings
        self.applicationMode = applicationMode
        self.includeAlternatives = includeAlternatives
    }
}

struct SpeechContextVariantResult {
    let variant: String
    let contextTermCount: Int
    let contextualStrings: [String]
    let applicationMode: SpeechContextApplicationMode
    let includeAlternatives: Bool
    let contextReadback: [String]
    let text: String
    let canonicalizedText: String
    let vocabularyHits: [String]
    let alternatives: [String]
    let alternativeTranscripts: [String]
    let alternativeTranscriptCandidates: [SavedRecordingEvalSupport.AlternativeTranscriptCandidate]
    let confidenceMean: Double?
    let confidenceMinimum: Double?
    let elapsedSeconds: Double
}

struct AlternativeTranscriptRerankingEvalResult: Codable, Equatable {
    let rule: String
    let candidateCount: Int
    let selectedTranscript: String
    let selectedAlternativeTranscript: String?
    let selectedAlternativeConfidenceMean: Double?
    let topConfidenceMean: Double?
    let confidenceDelta: Double?
    let transcriptScore: TranscriptWordErrorScore?
    let canonicalizedTranscript: String
    let canonicalizedTranscriptScore: TranscriptWordErrorScore?

    var selectedAlternative: Bool {
        selectedAlternativeTranscript != nil
    }

    func scored(reference: String?, canonicalizedTranscript: String) -> AlternativeTranscriptRerankingEvalResult {
        AlternativeTranscriptRerankingEvalResult(
            rule: rule,
            candidateCount: candidateCount,
            selectedTranscript: selectedTranscript,
            selectedAlternativeTranscript: selectedAlternativeTranscript,
            selectedAlternativeConfidenceMean: selectedAlternativeConfidenceMean,
            topConfidenceMean: topConfidenceMean,
            confidenceDelta: confidenceDelta,
            transcriptScore: reference.map {
                PolishEvalScoring.wordErrorScore(reference: $0, hypothesis: selectedTranscript)
            },
            canonicalizedTranscript: canonicalizedTranscript,
            canonicalizedTranscriptScore: reference.map {
                PolishEvalScoring.wordErrorScore(reference: $0, hypothesis: canonicalizedTranscript)
            }
        )
    }
}

enum AlternativeTranscriptReranker {
    static let ruleName = "highestAlternativeMeanConfidence"

    static func rerank(
        topTranscript: String,
        topConfidenceMean: Double?,
        candidates: [SavedRecordingEvalSupport.AlternativeTranscriptCandidate]
    ) -> AlternativeTranscriptRerankingEvalResult {
        let trimmedTopTranscript = topTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let bestCandidate = bestCandidate(
            topTranscript: trimmedTopTranscript,
            candidates: candidates
        ) else {
            return AlternativeTranscriptRerankingEvalResult(
                rule: ruleName,
                candidateCount: candidates.count,
                selectedTranscript: trimmedTopTranscript,
                selectedAlternativeTranscript: nil,
                selectedAlternativeConfidenceMean: nil,
                topConfidenceMean: topConfidenceMean,
                confidenceDelta: nil,
                transcriptScore: nil,
                canonicalizedTranscript: trimmedTopTranscript,
                canonicalizedTranscriptScore: nil
            )
        }

        return AlternativeTranscriptRerankingEvalResult(
            rule: ruleName,
            candidateCount: candidates.count,
            selectedTranscript: bestCandidate.text,
            selectedAlternativeTranscript: bestCandidate.text,
            selectedAlternativeConfidenceMean: bestCandidate.confidenceMean,
            topConfidenceMean: topConfidenceMean,
            confidenceDelta: topConfidenceMean.map { bestCandidate.confidenceMean - $0 },
            transcriptScore: nil,
            canonicalizedTranscript: bestCandidate.text,
            canonicalizedTranscriptScore: nil
        )
    }

    private static func bestCandidate(
        topTranscript: String,
        candidates: [SavedRecordingEvalSupport.AlternativeTranscriptCandidate]
    ) -> (text: String, confidenceMean: Double, index: Int)? {
        let normalizedTopTranscript = normalized(topTranscript)
        var ranked: [(text: String, confidenceMean: Double, index: Int)] = []
        for (index, candidate) in candidates.enumerated() {
            let text = candidate.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            guard normalized(text) != normalizedTopTranscript else { continue }
            guard let confidenceMean = candidate.confidenceMean else { continue }
            ranked.append((text: text, confidenceMean: confidenceMean, index: index))
        }
        return ranked.sorted { lhs, rhs in
            if lhs.confidenceMean != rhs.confidenceMean {
                return lhs.confidenceMean > rhs.confidenceMean
            }
            if lhs.text.count != rhs.text.count {
                return lhs.text.count < rhs.text.count
            }
            return lhs.index < rhs.index
        }.first
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

struct SpeechContextEvalRow: Codable {
    let evalSchemaVersion: Int
    let file: String
    let audioSHA256: String
    let localeIdentifier: String
    let audioDurationSeconds: Double
    let humanIntendedTranscript: String?
    let baselineVariant: String
    let variant: String
    let contextTermCount: Int
    let applicationMode: SpeechContextApplicationMode
    let includeAlternatives: Bool
    let contextReadbackCount: Int
    let contextReadbackTerms: [String]
    let contextReadbackMatches: Bool
    let baselineText: String
    let variantText: String
    let baselineTranscriptScore: TranscriptWordErrorScore?
    let variantTranscriptScore: TranscriptWordErrorScore?
    let baselineCanonicalized: String
    let variantCanonicalized: String
    let baselineCanonicalizedTranscriptScore: TranscriptWordErrorScore?
    let variantCanonicalizedTranscriptScore: TranscriptWordErrorScore?
    let baselineVocabularyHits: [String]
    let variantVocabularyHits: [String]
    let variantAlternatives: [String]
    let variantAlternativeTranscriptCandidates: [String]
    let variantConfidenceMean: Double?
    let variantConfidenceMinimum: Double?
    let correctionDictionaryFingerprint: String
    let appliedCorrectionRecordIDs: [String]
    let bestAlternativeTranscript: String?
    let bestAlternativeTranscriptScore: TranscriptWordErrorScore?
    let bestAlternativeTranscriptConfidenceMean: Double?
    let bestCanonicalizedAlternativeTranscript: String?
    let bestCanonicalizedAlternativeTranscriptScore: TranscriptWordErrorScore?
    let bestCanonicalizedAlternativeTranscriptConfidenceMean: Double?
    let alternativeReranking: AlternativeTranscriptRerankingEvalResult?
    let baselineElapsedSeconds: Double
    let variantElapsedSeconds: Double

    var rawChanged: Bool { baselineText != variantText }
    var canonicalizedChanged: Bool { baselineCanonicalized != variantCanonicalized }
    var vocabularyHitDelta: Int { variantVocabularyHits.count - baselineVocabularyHits.count }
    var elapsedDeltaSeconds: Double { variantElapsedSeconds - baselineElapsedSeconds }
    var hasAlternatives: Bool { !variantAlternatives.isEmpty }
    var hasDifferentAlternative: Bool { variantAlternatives.contains { $0 != variantText } }
    var hasAlternativeTranscriptCandidates: Bool { !variantAlternativeTranscriptCandidates.isEmpty }
    var rawWERDelta: Double? {
        guard let baselineTranscriptScore, let variantTranscriptScore else { return nil }
        return variantTranscriptScore.wordErrorRate - baselineTranscriptScore.wordErrorRate
    }
    var canonicalizedWERDelta: Double? {
        guard let baselineCanonicalizedTranscriptScore, let variantCanonicalizedTranscriptScore else { return nil }
        return variantCanonicalizedTranscriptScore.wordErrorRate - baselineCanonicalizedTranscriptScore.wordErrorRate
    }
    var rawWERImproved: Bool { rawWERDelta.map { $0 < 0 } ?? false }
    var rawWERWorsened: Bool { rawWERDelta.map { $0 > 0 } ?? false }
    var canonicalizedWERImproved: Bool { canonicalizedWERDelta.map { $0 < 0 } ?? false }
    var canonicalizedWERWorsened: Bool { canonicalizedWERDelta.map { $0 > 0 } ?? false }
    var bestAlternativeImprovesVariant: Bool {
        guard let bestAlternativeTranscriptScore, let variantTranscriptScore else { return false }
        return bestAlternativeTranscriptScore.wordErrorRate < variantTranscriptScore.wordErrorRate
    }
    var bestAlternativeMatchesIntended: Bool {
        bestAlternativeTranscriptScore?.wordErrorRate == 0
    }
    var bestCanonicalizedAlternativeImprovesVariant: Bool {
        guard let bestCanonicalizedAlternativeTranscriptScore,
              let variantCanonicalizedTranscriptScore else { return false }
        return bestCanonicalizedAlternativeTranscriptScore.wordErrorRate <
            variantCanonicalizedTranscriptScore.wordErrorRate
    }
    var bestCanonicalizedAlternativeMatchesIntended: Bool {
        bestCanonicalizedAlternativeTranscriptScore?.wordErrorRate == 0
    }
    var rerankedAlternativeSelected: Bool { alternativeReranking?.selectedAlternative ?? false }
    var rerankedAlternativeImprovesVariant: Bool {
        guard let rerankedScore = alternativeReranking?.transcriptScore,
              let variantTranscriptScore else { return false }
        return rerankedScore.wordErrorRate < variantTranscriptScore.wordErrorRate
    }
    var rerankedAlternativeWorsensVariant: Bool {
        guard let rerankedScore = alternativeReranking?.transcriptScore,
              let variantTranscriptScore else { return false }
        return rerankedScore.wordErrorRate > variantTranscriptScore.wordErrorRate
    }
    var rerankedAlternativeMatchesIntended: Bool {
        alternativeReranking?.transcriptScore?.wordErrorRate == 0
    }
    var rerankedCanonicalizedAlternativeImprovesVariant: Bool {
        guard let rerankedScore = alternativeReranking?.canonicalizedTranscriptScore,
              let variantCanonicalizedTranscriptScore else { return false }
        return rerankedScore.wordErrorRate < variantCanonicalizedTranscriptScore.wordErrorRate
    }
    var rerankedCanonicalizedAlternativeWorsensVariant: Bool {
        guard let rerankedScore = alternativeReranking?.canonicalizedTranscriptScore,
              let variantCanonicalizedTranscriptScore else { return false }
        return rerankedScore.wordErrorRate > variantCanonicalizedTranscriptScore.wordErrorRate
    }
    var rerankedCanonicalizedAlternativeMatchesIntended: Bool {
        alternativeReranking?.canonicalizedTranscriptScore?.wordErrorRate == 0
    }
}
