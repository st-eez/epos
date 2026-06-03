import Foundation

struct SpeechContextEvalVariant {
    let name: String
    let contextualStrings: [String]
}

struct SpeechContextVariantResult {
    let variant: String
    let contextTermCount: Int
    let contextualStrings: [String]
    let text: String
    let canonicalizedText: String
    let vocabularyHits: [String]
    let elapsedSeconds: Double
}

struct SpeechContextEvalRow: Codable {
    let file: String
    let localeIdentifier: String
    let audioDurationSeconds: Double
    let baselineVariant: String
    let variant: String
    let contextTermCount: Int
    let baselineText: String
    let variantText: String
    let baselineCanonicalized: String
    let variantCanonicalized: String
    let baselineVocabularyHits: [String]
    let variantVocabularyHits: [String]
    let baselineElapsedSeconds: Double
    let variantElapsedSeconds: Double

    var rawChanged: Bool { baselineText != variantText }
    var canonicalizedChanged: Bool { baselineCanonicalized != variantCanonicalized }
    var vocabularyHitDelta: Int { variantVocabularyHits.count - baselineVocabularyHits.count }
    var elapsedDeltaSeconds: Double { variantElapsedSeconds - baselineElapsedSeconds }
}

struct SpeechContextEvalSummary {
    private var variantSummaries: [String: VariantSummary] = [:]

    mutating func add(_ row: SpeechContextEvalRow) {
        variantSummaries[row.variant, default: VariantSummary()].add(row)
    }

    func report(
        recordingCount: Int,
        variantCount: Int,
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
        if row.canonicalizedChanged {
            lines.append("  base can: \(row.baselineCanonicalized)")
            lines.append("  ctx can:  \(row.variantCanonicalized)")
        }
        if row.vocabularyHitDelta != 0 {
            lines.append("  base hits: \(row.baselineVocabularyHits.joined(separator: ", "))")
            lines.append("  ctx hits:  \(row.variantVocabularyHits.joined(separator: ", "))")
        }
    }

    private func tags(for row: SpeechContextEvalRow) -> [String] {
        var tags: [String] = []
        if row.rawChanged { tags.append("RAW-CHANGED") }
        if row.canonicalizedChanged { tags.append("CANON-CHANGED") }
        if row.vocabularyHitDelta > 0 { tags.append("VOCAB-GAIN") }
        if row.vocabularyHitDelta < 0 { tags.append("VOCAB-LOSS") }
        return tags
    }

    private static func formatSeconds(_ seconds: Double) -> String {
        String(format: "%.3f", seconds)
    }

    private static func formatSignedSeconds(_ seconds: Double) -> String {
        String(format: "%+.3f", seconds)
    }

    private struct VariantSummary {
        var rows = 0
        var contextTermCount = 0
        var rawChanged = 0
        var canonicalizedChanged = 0
        var vocabularyHitGains = 0
        var vocabularyHitLosses = 0
        var elapsedDeltaTotal = 0.0

        mutating func add(_ row: SpeechContextEvalRow) {
            rows += 1
            contextTermCount = row.contextTermCount
            elapsedDeltaTotal += row.elapsedDeltaSeconds
            if row.rawChanged { rawChanged += 1 }
            if row.canonicalizedChanged { canonicalizedChanged += 1 }
            if row.vocabularyHitDelta > 0 { vocabularyHitGains += 1 }
            if row.vocabularyHitDelta < 0 { vocabularyHitLosses += 1 }
        }

        func report(variant: String) -> String {
            let meanDelta = rows == 0 ? 0 : elapsedDeltaTotal / Double(rows)
            return "\(variant): context terms=\(contextTermCount) " +
                "raw changed=\(rawChanged) canonicalized changed=\(canonicalizedChanged) " +
                "vocabulary hit gains/losses=\(vocabularyHitGains)/\(vocabularyHitLosses) " +
                "mean latency delta=\(String(format: "%+.3f", meanDelta))s"
        }
    }
}
