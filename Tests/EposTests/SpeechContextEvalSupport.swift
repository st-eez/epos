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

struct SpeechContextEvalRow: Codable {
    let file: String
    let localeIdentifier: String
    let audioDurationSeconds: Double
    let humanIntendedTranscript: String?
    let baselineVariant: String
    let variant: String
    let contextTermCount: Int
    let applicationMode: SpeechContextApplicationMode
    let includeAlternatives: Bool
    let contextReadbackCount: Int
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
    let bestAlternativeTranscript: String?
    let bestAlternativeTranscriptScore: TranscriptWordErrorScore?
    let bestAlternativeTranscriptConfidenceMean: Double?
    let bestCanonicalizedAlternativeTranscript: String?
    let bestCanonicalizedAlternativeTranscriptScore: TranscriptWordErrorScore?
    let bestCanonicalizedAlternativeTranscriptConfidenceMean: Double?
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
}
