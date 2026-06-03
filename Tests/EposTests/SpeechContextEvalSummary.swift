import Foundation

struct SpeechContextEvalSummary {
    private var variantSummaries: [String: VariantSummary] = [:]

    mutating func add(_ row: SpeechContextEvalRow) {
        variantSummaries[row.variant, default: VariantSummary()].add(row)
    }

    func report(
        recordingCount: Int,
        variantCount: Int,
        groundTruthSourceURL: URL?,
        outputURL: URL,
        rows: [SpeechContextEvalRow]
    ) -> String {
        var lines = ["", "Speech context eval"]
        for row in rows {
            append(row: row, to: &lines)
        }
        lines.append("")
        lines.append("recordings: \(recordingCount)")
        lines.append("variants: \(variantCount)")
        if let groundTruthSourceURL {
            lines.append("ground truth: \(groundTruthSourceURL.path)")
        }
        for variant in variantSummaries.keys.sorted() {
            guard let summary = variantSummaries[variant] else { continue }
            lines.append(summary.report(variant: variant))
        }
        lines.append("output: \(outputURL.path)")
        return lines.joined(separator: "\n")
    }

    private func append(row: SpeechContextEvalRow, to lines: inout [String]) {
        let tagText = tags(for: row).isEmpty ? "same" : tags(for: row).joined(separator: " ")
        lines.append(
            "[\(row.file)] \(row.variant) <\(tagText)> " +
                "audio=\(Self.formatSeconds(row.audioDurationSeconds))s " +
                "latencyDelta=\(Self.formatSignedSeconds(row.elapsedDeltaSeconds))s"
        )
        lines.append("  base: \(row.baselineText)")
        lines.append("  ctx:  \(row.variantText)")
        if let rawBase = row.baselineTranscriptScore,
           let rawVariant = row.variantTranscriptScore,
           let canBase = row.baselineCanonicalizedTranscriptScore,
           let canVariant = row.variantCanonicalizedTranscriptScore {
            lines.append(
                "  WER raw base/ctx: \(Self.formatScore(rawBase.wordErrorRate))/" +
                    "\(Self.formatScore(rawVariant.wordErrorRate)) " +
                    "can base/ctx: \(Self.formatScore(canBase.wordErrorRate))/" +
                    "\(Self.formatScore(canVariant.wordErrorRate))"
            )
        }
        lines.append(
            "  context: \(row.applicationMode.rawValue) terms=\(row.contextTermCount) " +
                "readback=\(row.contextReadbackCount) alternatives=\(row.variantAlternatives.count) " +
                "candidates=\(row.variantAlternativeTranscriptCandidates.count)"
        )
        if let confidenceMean = row.variantConfidenceMean,
           let confidenceMinimum = row.variantConfidenceMinimum {
            lines.append(
                "  confidence mean/min: \(Self.formatScore(confidenceMean))/" +
                    "\(Self.formatScore(confidenceMinimum))"
            )
        }
        if row.canonicalizedChanged {
            lines.append("  base can: \(row.baselineCanonicalized)")
            lines.append("  ctx can:  \(row.variantCanonicalized)")
        }
        if row.vocabularyHitDelta != 0 {
            lines.append("  base hits: \(row.baselineVocabularyHits.joined(separator: ", "))")
            lines.append("  ctx hits:  \(row.variantVocabularyHits.joined(separator: ", "))")
        }
        if row.hasAlternatives {
            lines.append("  alternative fragments: \(row.variantAlternatives.joined(separator: " | "))")
        }
        if row.hasAlternativeTranscriptCandidates {
            lines.append(
                "  alternative transcript candidates: " +
                    row.variantAlternativeTranscriptCandidates.prefix(4).joined(separator: " | ")
            )
        }
        if let bestAlternativeTranscript = row.bestAlternativeTranscript,
           let score = row.bestAlternativeTranscriptScore {
            lines.append(
                "  best alternative transcript WER=\(Self.formatScore(score.wordErrorRate)): " +
                    "confidence=\(Self.formatOptionalScore(row.bestAlternativeTranscriptConfidenceMean)) " +
                    bestAlternativeTranscript
            )
        }
        if let bestCanonicalizedAlternativeTranscript = row.bestCanonicalizedAlternativeTranscript,
           let score = row.bestCanonicalizedAlternativeTranscriptScore {
            lines.append(
                "  best canonicalized alternative WER=\(Self.formatScore(score.wordErrorRate)): " +
                    "confidence=\(Self.formatOptionalScore(row.bestCanonicalizedAlternativeTranscriptConfidenceMean)) " +
                    bestCanonicalizedAlternativeTranscript
            )
        }
    }

    private func tags(for row: SpeechContextEvalRow) -> [String] {
        var tags: [String] = []
        if row.rawChanged { tags.append("RAW-CHANGED") }
        if row.canonicalizedChanged { tags.append("CANON-CHANGED") }
        if row.rawWERImproved { tags.append("RAW-WER-BETTER") }
        if row.rawWERWorsened { tags.append("RAW-WER-WORSE") }
        if row.canonicalizedWERImproved { tags.append("CAN-WER-BETTER") }
        if row.canonicalizedWERWorsened { tags.append("CAN-WER-WORSE") }
        if row.vocabularyHitDelta > 0 { tags.append("VOCAB-GAIN") }
        if row.vocabularyHitDelta < 0 { tags.append("VOCAB-LOSS") }
        if !row.contextReadbackMatches { tags.append("READBACK-MISMATCH") }
        if row.hasAlternatives { tags.append("ALTERNATIVES") }
        if row.hasDifferentAlternative { tags.append("ALT-DIFF") }
        if row.bestAlternativeImprovesVariant { tags.append("ALT-WER-BETTER") }
        if row.bestAlternativeMatchesIntended { tags.append("ALT-WER-ZERO") }
        if row.bestCanonicalizedAlternativeImprovesVariant { tags.append("ALT-CAN-WER-BETTER") }
        if row.bestCanonicalizedAlternativeMatchesIntended { tags.append("ALT-CAN-WER-ZERO") }
        return tags
    }

    private static func formatSeconds(_ seconds: Double) -> String {
        String(format: "%.3f", seconds)
    }

    private static func formatSignedSeconds(_ seconds: Double) -> String {
        String(format: "%+.3f", seconds)
    }

    private static func formatScore(_ score: Double) -> String {
        String(format: "%.3f", score)
    }

    private static func formatOptionalScore(_ score: Double?) -> String {
        score.map(formatScore(_:)) ?? "n/a"
    }

    private struct VariantSummary {
        var rows = 0
        var contextTermCount = 0
        var groundTruthRows = 0
        var rawChanged = 0
        var canonicalizedChanged = 0
        var rawWERBetter = 0
        var rawWERWorse = 0
        var canonicalizedWERBetter = 0
        var canonicalizedWERWorse = 0
        var vocabularyHitGains = 0
        var vocabularyHitLosses = 0
        var contextReadbackMismatches = 0
        var alternativesRows = 0
        var differentAlternativeRows = 0
        var alternativeTranscriptCandidateRows = 0
        var betterAlternativeRows = 0
        var perfectAlternativeRows = 0
        var betterCanonicalizedAlternativeRows = 0
        var perfectCanonicalizedAlternativeRows = 0
        var totalBaselineRawWER = 0.0
        var totalVariantRawWER = 0.0
        var totalBaselineCanonicalizedWER = 0.0
        var totalVariantCanonicalizedWER = 0.0
        var elapsedDeltaTotal = 0.0

        mutating func add(_ row: SpeechContextEvalRow) {
            rows += 1
            contextTermCount = row.contextTermCount
            elapsedDeltaTotal += row.elapsedDeltaSeconds
            if let baselineTranscriptScore = row.baselineTranscriptScore,
               let variantTranscriptScore = row.variantTranscriptScore,
               let baselineCanonicalizedTranscriptScore = row.baselineCanonicalizedTranscriptScore,
               let variantCanonicalizedTranscriptScore = row.variantCanonicalizedTranscriptScore {
                groundTruthRows += 1
                totalBaselineRawWER += baselineTranscriptScore.wordErrorRate
                totalVariantRawWER += variantTranscriptScore.wordErrorRate
                totalBaselineCanonicalizedWER += baselineCanonicalizedTranscriptScore.wordErrorRate
                totalVariantCanonicalizedWER += variantCanonicalizedTranscriptScore.wordErrorRate
            }
            if row.rawChanged { rawChanged += 1 }
            if row.canonicalizedChanged { canonicalizedChanged += 1 }
            if row.rawWERImproved { rawWERBetter += 1 }
            if row.rawWERWorsened { rawWERWorse += 1 }
            if row.canonicalizedWERImproved { canonicalizedWERBetter += 1 }
            if row.canonicalizedWERWorsened { canonicalizedWERWorse += 1 }
            if row.vocabularyHitDelta > 0 { vocabularyHitGains += 1 }
            if row.vocabularyHitDelta < 0 { vocabularyHitLosses += 1 }
            if !row.contextReadbackMatches { contextReadbackMismatches += 1 }
            if row.hasAlternatives { alternativesRows += 1 }
            if row.hasDifferentAlternative { differentAlternativeRows += 1 }
            if row.hasAlternativeTranscriptCandidates { alternativeTranscriptCandidateRows += 1 }
            if row.bestAlternativeImprovesVariant { betterAlternativeRows += 1 }
            if row.bestAlternativeMatchesIntended { perfectAlternativeRows += 1 }
            if row.bestCanonicalizedAlternativeImprovesVariant { betterCanonicalizedAlternativeRows += 1 }
            if row.bestCanonicalizedAlternativeMatchesIntended { perfectCanonicalizedAlternativeRows += 1 }
        }

        func report(variant: String) -> String {
            let meanDelta = rows == 0 ? 0 : elapsedDeltaTotal / Double(rows)
            var parts = [
                "\(variant): context terms=\(contextTermCount)",
                "raw changed=\(rawChanged) canonicalized changed=\(canonicalizedChanged) " +
                    "vocabulary hit gains/losses=\(vocabularyHitGains)/\(vocabularyHitLosses) " +
                    "readback mismatches=\(contextReadbackMismatches) " +
                    "alternatives/different=\(alternativesRows)/\(differentAlternativeRows) " +
                    "alternative candidates=\(alternativeTranscriptCandidateRows) " +
                    "mean latency delta=\(String(format: "%+.3f", meanDelta))s",
            ]
            if groundTruthRows > 0 {
                parts.append(
                    "ground truth rows=\(groundTruthRows) " +
                        "mean WER raw base/ctx=\(formatMean(totalBaselineRawWER, groundTruthRows))/" +
                        "\(formatMean(totalVariantRawWER, groundTruthRows)) " +
                        "can base/ctx=\(formatMean(totalBaselineCanonicalizedWER, groundTruthRows))/" +
                        "\(formatMean(totalVariantCanonicalizedWER, groundTruthRows)) " +
                        "raw WER better/worse=\(rawWERBetter)/\(rawWERWorse) " +
                        "can WER better/worse=\(canonicalizedWERBetter)/\(canonicalizedWERWorse) " +
                        "best alternatives better/perfect=\(betterAlternativeRows)/\(perfectAlternativeRows) " +
                        "best canonicalized alternatives better/perfect=" +
                        "\(betterCanonicalizedAlternativeRows)/\(perfectCanonicalizedAlternativeRows)"
                )
            }
            return parts.joined(separator: " ")
        }

        private func formatMean(_ total: Double, _ count: Int) -> String {
            String(format: "%.3f", total / Double(count))
        }
    }
}
