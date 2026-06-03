import Foundation

struct DogfoodPipelineEvalRow: Codable {
    let file: String
    let localeIdentifier: String
    let audioDurationSeconds: Double
    let transcribeSeconds: Double
    let polishSeconds: Double
    let humanIntendedTranscript: String?
    let rawTranscript: String
    let rawTranscriptScore: TranscriptWordErrorScore?
    let canonicalizedRaw: String
    let canonicalizedRawTranscriptScore: TranscriptWordErrorScore?
    let output: String
    let outputTranscriptScore: TranscriptWordErrorScore?
    let outcome: String
    let engineOutcome: String?
    let polishPromptStyle: String?
    let prewarmWaitSeconds: Double
    let rawChangedByCanonicalizer: Bool
    let outputChangedFromRaw: Bool
    let outputChangedFromCanonicalizedRaw: Bool
    let retainedFillerInRaw: Bool
    let retainedFillerInOutput: Bool
    let rawCharacterCount: Int
    let outputCharacterCount: Int
    let guardRejectionReason: String?
    let guardRejectionCandidate: String?
    let guardRejectionCandidateCharacterCount: Int?
    let guardRejectionDiff: String?
    let shadowRelaxedOutput: String?
    let shadowRelaxedOutputTranscriptScore: TranscriptWordErrorScore?
    let shadowRelaxedOutcome: String?
    let shadowRelaxedEngineOutcome: String?
    let shadowRelaxedPolishSeconds: Double?
    let shadowRelaxedOutputChangedFromProduction: Bool?
    let shadowRelaxedOutputChangedFromCanonicalizedRaw: Bool?
    let shadowRelaxedCandidateOrOutputChangedFromProduction: Bool?
    let shadowRelaxedGuardRejectionReason: String?
    let shadowRelaxedGuardRejectionCandidate: String?
    let shadowRelaxedGuardRejectionCandidateCharacterCount: Int?
    let shadowRelaxedGuardRejectionDiff: String?
    let shadowRelaxedCandidateTranscriptScore: TranscriptWordErrorScore?
    let shadowRelaxedRawCandidate: OllamaRawCandidateEvalResult?
}
