import Foundation
@testable import Epos

enum OllamaRawCandidateEvalSupport {
    static func evaluate(
        raw: String,
        canonicalizedRaw: String,
        deterministicOutput: String,
        session: any PolishSession,
        canonicalize: (String) -> String
    ) async -> OllamaRawCandidateEvalResult {
        let started = Date()
        do {
            let candidate = try await session.polish(raw)
            let elapsedSeconds = Date().timeIntervalSince(started)
            let canonicalizedCandidate = canonicalize(candidate)
            let retention = TranscriptPolisher.polishRetentionEvaluation(
                raw: canonicalizedRaw,
                polished: canonicalizedCandidate
            )
            let gate = strictGateDecision(
                canonicalizedRaw: canonicalizedRaw,
                deterministicOutput: deterministicOutput,
                canonicalizedCandidate: canonicalizedCandidate,
                retention: retention
            )
            return OllamaRawCandidateEvalResult(
                candidateOutcome: "success",
                candidate: candidate,
                canonicalizedCandidate: canonicalizedCandidate,
                elapsedSeconds: elapsedSeconds,
                candidateCharacterCount: candidate.count,
                canonicalizedCandidateCharacterCount: canonicalizedCandidate.count,
                candidateChangedFromRaw: candidate != raw,
                candidateChangedFromCanonicalizedRaw: canonicalizedCandidate != canonicalizedRaw,
                retainedFillerInCandidate: PolishEvalScoring.retainsFiller(candidate),
                strictGuardRetainsContent: retention.retainsContent,
                strictGateOutcome: gate.outcome,
                strictGateOutput: gate.output,
                strictGateOutputChangedFromCanonicalizedRaw: gate.output != canonicalizedRaw,
                strictGuardRejectionReason: retention.rejection?.reason.rawValue,
                strictGuardRejectionDiff: retention.rejection?.diff,
                errorDescription: nil
            )
        } catch is PolishInputTooLargeError {
            return failedResult(
                outcome: "tooLong",
                elapsedSeconds: Date().timeIntervalSince(started),
                errorDescription: "input too large"
            )
        } catch {
            return failedResult(
                outcome: "failed",
                elapsedSeconds: Date().timeIntervalSince(started),
                errorDescription: String(describing: error)
            )
        }
    }

    private static func strictGateDecision(
        canonicalizedRaw: String,
        deterministicOutput: String,
        canonicalizedCandidate: String,
        retention: PolishRetentionEvaluation
    ) -> (outcome: String, output: String) {
        if canonicalizedCandidate == canonicalizedRaw {
            if let deterministic = deterministicGateOutput(
                canonicalizedRaw: canonicalizedRaw,
                deterministicOutput: deterministicOutput
            ) {
                return ("deterministicCleanup", deterministic)
            }
            return ("sameText", canonicalizedRaw)
        }

        if retention.retainsContent {
            return ("applied", canonicalizedCandidate)
        }

        if let deterministic = deterministicGateOutput(
            canonicalizedRaw: canonicalizedRaw,
            deterministicOutput: deterministicOutput
        ) {
            return ("deterministicCleanup", deterministic)
        }
        return ("guardRejected", canonicalizedRaw)
    }

    private static func deterministicGateOutput(
        canonicalizedRaw: String,
        deterministicOutput: String
    ) -> String? {
        guard deterministicOutput != canonicalizedRaw else { return nil }
        guard TranscriptPolisher.polishRetainsContent(
            raw: canonicalizedRaw,
            polished: deterministicOutput
        ) else {
            return nil
        }
        return deterministicOutput
    }

    private static func failedResult(
        outcome: String,
        elapsedSeconds: Double,
        errorDescription: String
    ) -> OllamaRawCandidateEvalResult {
        OllamaRawCandidateEvalResult(
            candidateOutcome: outcome,
            candidate: nil,
            canonicalizedCandidate: nil,
            elapsedSeconds: elapsedSeconds,
            candidateCharacterCount: nil,
            canonicalizedCandidateCharacterCount: nil,
            candidateChangedFromRaw: nil,
            candidateChangedFromCanonicalizedRaw: nil,
            retainedFillerInCandidate: nil,
            strictGuardRetainsContent: nil,
            strictGateOutcome: nil,
            strictGateOutput: nil,
            strictGateOutputChangedFromCanonicalizedRaw: nil,
            strictGuardRejectionReason: nil,
            strictGuardRejectionDiff: nil,
            errorDescription: errorDescription
        )
    }
}

struct OllamaRawCandidateEvalResult: Codable, Equatable {
    let candidateOutcome: String
    let candidate: String?
    let canonicalizedCandidate: String?
    let elapsedSeconds: Double
    let candidateCharacterCount: Int?
    let canonicalizedCandidateCharacterCount: Int?
    let candidateChangedFromRaw: Bool?
    let candidateChangedFromCanonicalizedRaw: Bool?
    let retainedFillerInCandidate: Bool?
    let strictGuardRetainsContent: Bool?
    let strictGateOutcome: String?
    let strictGateOutput: String?
    let strictGateOutputChangedFromCanonicalizedRaw: Bool?
    let strictGuardRejectionReason: String?
    let strictGuardRejectionDiff: String?
    let errorDescription: String?
}
