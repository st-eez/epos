import Foundation

struct DogfoodPipelineEvalSummary {
    private var canonicalizerChanged = 0
    private var changedFromCanonicalizedRaw = 0
    private var retainedFillerRaw = 0
    private var retainedFillerOutput = 0
    private var outcomes: [String: Int] = [:]
    private var engineOutcomes: [String: Int] = [:]
    private var totalPrewarmWaitSeconds = 0.0
    private var shadowRelaxedRows = 0
    private var shadowRelaxedOutputChangedFromProduction = 0
    private var shadowRelaxedCandidateOrOutputChangedFromProduction = 0
    private var shadowRelaxedOutputChangedFromCanonicalizedRaw = 0
    private var shadowRelaxedOutcomes: [String: Int] = [:]
    private var shadowRelaxedEngineOutcomes: [String: Int] = [:]
    private var shadowRelaxedGuardRejections: [String: Int] = [:]
    private var shadowRelaxedRawCandidateChangedFromProduction = 0
    private var groundTruthRows = 0
    private var totalRawWER = 0.0
    private var totalCanonicalizedRawWER = 0.0
    private var totalOutputWER = 0.0
    private var totalRawAccuracy = 0.0
    private var totalCanonicalizedRawAccuracy = 0.0
    private var totalOutputAccuracy = 0.0

    mutating func add(_ row: DogfoodPipelineEvalRow) {
        if row.rawChangedByCanonicalizer {
            canonicalizerChanged += 1
        }
        if row.outputChangedFromCanonicalizedRaw {
            changedFromCanonicalizedRaw += 1
        }
        if row.retainedFillerInRaw {
            retainedFillerRaw += 1
        }
        if row.retainedFillerInOutput {
            retainedFillerOutput += 1
        }
        outcomes[row.outcome, default: 0] += 1
        engineOutcomes[row.engineOutcome ?? "not-attempted", default: 0] += 1
        totalPrewarmWaitSeconds += row.prewarmWaitSeconds
        if let shadowOutcome = row.shadowRelaxedOutcome {
            shadowRelaxedRows += 1
            shadowRelaxedOutcomes[shadowOutcome, default: 0] += 1
            shadowRelaxedEngineOutcomes[row.shadowRelaxedEngineOutcome ?? "not-attempted", default: 0] += 1
        }
        if row.shadowRelaxedOutputChangedFromProduction == true {
            shadowRelaxedOutputChangedFromProduction += 1
        }
        if row.shadowRelaxedCandidateOrOutputChangedFromProduction == true {
            shadowRelaxedCandidateOrOutputChangedFromProduction += 1
        }
        if row.shadowRelaxedOutputChangedFromCanonicalizedRaw == true {
            shadowRelaxedOutputChangedFromCanonicalizedRaw += 1
        }
        if let reason = row.shadowRelaxedGuardRejectionReason {
            shadowRelaxedGuardRejections[reason, default: 0] += 1
        }
        if let candidate = row.shadowRelaxedRawCandidate?.candidate,
           candidate != row.output {
            shadowRelaxedRawCandidateChangedFromProduction += 1
        }
        if let rawScore = row.rawTranscriptScore,
           let canonicalizedRawScore = row.canonicalizedRawTranscriptScore,
           let outputScore = row.outputTranscriptScore {
            groundTruthRows += 1
            totalRawWER += rawScore.wordErrorRate
            totalCanonicalizedRawWER += canonicalizedRawScore.wordErrorRate
            totalOutputWER += outputScore.wordErrorRate
            totalRawAccuracy += rawScore.wordAccuracy
            totalCanonicalizedRawAccuracy += canonicalizedRawScore.wordAccuracy
            totalOutputAccuracy += outputScore.wordAccuracy
        }
    }

    func report(
        recordingCount: Int,
        knownTermCount: Int,
        polishPromptStyle: String?,
        groundTruthSourceURL: URL?,
        outputURL: URL,
        rows: [DogfoodPipelineEvalRow]
    ) -> String {
        var lines = ["", "Dogfood pipeline eval"]
        for row in rows {
            appendRow(row, to: &lines)
        }
        appendSummary(
            recordingCount: recordingCount,
            knownTermCount: knownTermCount,
            polishPromptStyle: polishPromptStyle,
            groundTruthSourceURL: groundTruthSourceURL,
            outputURL: outputURL,
            to: &lines
        )
        return lines.joined(separator: "\n")
    }

    private func appendRow(_ row: DogfoodPipelineEvalRow, to lines: inout [String]) {
        lines.append(Self.rowHeader(row))
        if let humanIntendedTranscript = row.humanIntendedTranscript {
            lines.append("  intended: \(humanIntendedTranscript)")
        }
        lines.append("  raw: \(row.rawTranscript)")
        if row.rawChangedByCanonicalizer {
            lines.append("  can: \(row.canonicalizedRaw)")
        }
        lines.append("  out: \(row.output)")
        if let rawScore = row.rawTranscriptScore,
           let canonicalizedRawScore = row.canonicalizedRawTranscriptScore,
           let outputScore = row.outputTranscriptScore {
            lines.append(
                "  WER raw/can/out: \(Self.formatScore(rawScore.wordErrorRate))/" +
                    "\(Self.formatScore(canonicalizedRawScore.wordErrorRate))/" +
                    "\(Self.formatScore(outputScore.wordErrorRate))"
            )
        }
        appendProductionDiagnostics(row, to: &lines)
        appendShadowDiagnostics(row, to: &lines)
    }

    private func appendProductionDiagnostics(_ row: DogfoodPipelineEvalRow, to lines: inout [String]) {
        if let candidate = row.guardRejectionCandidate {
            lines.append("  candidate: \(candidate)")
        }
        if let reason = row.guardRejectionReason, let diff = row.guardRejectionDiff {
            lines.append("  rejection: \(reason) \(diff)")
        }
    }

    private func appendShadowDiagnostics(_ row: DogfoodPipelineEvalRow, to lines: inout [String]) {
        if let shadowOutput = row.shadowRelaxedOutput {
            lines.append("  relaxed strict-gate out: \(shadowOutput)")
        }
        if let rawCandidate = row.shadowRelaxedRawCandidate?.candidate {
            lines.append("  relaxed raw candidate: \(rawCandidate)")
        }
        if let canonicalizedCandidate = row.shadowRelaxedRawCandidate?.canonicalizedCandidate,
           canonicalizedCandidate != row.shadowRelaxedRawCandidate?.candidate {
            lines.append("  relaxed canonicalized candidate: \(canonicalizedCandidate)")
        }
        if let shadowCandidate = row.shadowRelaxedGuardRejectionCandidate {
            lines.append("  relaxed rejected candidate: \(shadowCandidate)")
        }
        if let reason = row.shadowRelaxedGuardRejectionReason,
           let diff = row.shadowRelaxedGuardRejectionDiff {
            lines.append("  relaxed rejection: \(reason) \(diff)")
        }
    }

    private func appendSummary(
        recordingCount: Int,
        knownTermCount: Int,
        polishPromptStyle: String?,
        groundTruthSourceURL: URL?,
        outputURL: URL,
        to lines: inout [String]
    ) {
        lines.append("")
        lines.append("recordings: \(recordingCount)")
        lines.append("known terms: \(knownTermCount)")
        if let polishPromptStyle {
            lines.append("polish prompt style: \(polishPromptStyle)")
        }
        appendGroundTruthSummary(recordingCount: recordingCount, sourceURL: groundTruthSourceURL, to: &lines)
        lines.append("canonicalizer changed raw: \(canonicalizerChanged)")
        lines.append("polish changed canonicalized raw: \(changedFromCanonicalizedRaw)")
        lines.append("retained filler raw/output: \(retainedFillerRaw)/\(retainedFillerOutput)")
        lines.append("outcomes: \(Self.outcomeSummary(outcomes))")
        lines.append("engine outcomes: \(Self.outcomeSummary(engineOutcomes))")
        lines.append("prewarm wait total: \(Self.formatSeconds(totalPrewarmWaitSeconds))s")
        appendShadowSummary(to: &lines)
        lines.append("output: \(outputURL.path)")
    }

    private func appendGroundTruthSummary(
        recordingCount: Int,
        sourceURL: URL?,
        to lines: inout [String]
    ) {
        if let sourceURL {
            lines.append("ground truth: \(sourceURL.path)")
        }
        guard groundTruthRows > 0 else { return }
        lines.append("ground truth rows: \(groundTruthRows)/\(recordingCount)")
        lines.append(
            "mean WER raw/can/out: \(Self.formatMean(totalRawWER, groundTruthRows))/" +
                "\(Self.formatMean(totalCanonicalizedRawWER, groundTruthRows))/" +
                "\(Self.formatMean(totalOutputWER, groundTruthRows))"
        )
        lines.append(
            "mean accuracy raw/can/out: \(Self.formatMean(totalRawAccuracy, groundTruthRows))/" +
                "\(Self.formatMean(totalCanonicalizedRawAccuracy, groundTruthRows))/" +
                "\(Self.formatMean(totalOutputAccuracy, groundTruthRows))"
        )
    }

    private func appendShadowSummary(to lines: inout [String]) {
        guard shadowRelaxedRows > 0 else { return }
        lines.append("shadow relaxed rows: \(shadowRelaxedRows)")
        lines.append("shadow relaxed output changed production: \(shadowRelaxedOutputChangedFromProduction)")
        lines.append("shadow relaxed raw candidate changed production: \(shadowRelaxedRawCandidateChangedFromProduction)")
        lines.append(
            "shadow relaxed candidate/output changed production: " +
                "\(shadowRelaxedCandidateOrOutputChangedFromProduction)"
        )
        lines.append("shadow relaxed output changed canonicalized raw: \(shadowRelaxedOutputChangedFromCanonicalizedRaw)")
        lines.append("shadow relaxed outcomes: \(Self.outcomeSummary(shadowRelaxedOutcomes))")
        lines.append("shadow relaxed engine outcomes: \(Self.outcomeSummary(shadowRelaxedEngineOutcomes))")
        lines.append("shadow relaxed guard rejections: \(Self.outcomeSummary(shadowRelaxedGuardRejections))")
    }

    private static func rowHeader(_ row: DogfoodPipelineEvalRow) -> String {
        var tags = ["<\(row.outcome)>", "engine=<\(row.engineOutcome ?? "not-attempted")>"]
        if row.rawChangedByCanonicalizer { tags.append("CANON") }
        if row.outputChangedFromCanonicalizedRaw { tags.append("POLISHED") }
        if row.retainedFillerInOutput { tags.append("FILLER-LEFT") }
        if row.shadowRelaxedCandidateOrOutputChangedFromProduction == true { tags.append("RELAXED-DIFF") }
        let audio = Self.formatSeconds(row.audioDurationSeconds)
        let transcribe = Self.formatSeconds(row.transcribeSeconds)
        let polish = Self.formatSeconds(row.polishSeconds)
        return "[\(row.file)] \(tags.joined(separator: " ")) audio=\(audio)s transcribe=\(transcribe)s polish=\(polish)s"
    }

    private static func outcomeSummary(_ outcomes: [String: Int]) -> String {
        outcomes
            .keys
            .sorted()
            .map { "\($0)=\(outcomes[$0, default: 0])" }
            .joined(separator: ", ")
    }

    private static func formatSeconds(_ seconds: Double) -> String {
        String(format: "%.3f", seconds)
    }

    private static func formatMean(_ total: Double, _ count: Int) -> String {
        guard count > 0 else { return "n/a" }
        return formatScore(total / Double(count))
    }

    private static func formatScore(_ score: Double) -> String {
        String(format: "%.3f", score)
    }
}
