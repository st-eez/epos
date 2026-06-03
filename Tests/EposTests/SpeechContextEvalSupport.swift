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
    let elapsedSeconds: Double
}

struct SpeechContextEvalRow: Codable {
    let file: String
    let localeIdentifier: String
    let audioDurationSeconds: Double
    let baselineVariant: String
    let variant: String
    let contextTermCount: Int
    let applicationMode: SpeechContextApplicationMode
    let includeAlternatives: Bool
    let contextReadbackCount: Int
    let contextReadbackMatches: Bool
    let baselineText: String
    let variantText: String
    let baselineCanonicalized: String
    let variantCanonicalized: String
    let baselineVocabularyHits: [String]
    let variantVocabularyHits: [String]
    let variantAlternatives: [String]
    let baselineElapsedSeconds: Double
    let variantElapsedSeconds: Double

    var rawChanged: Bool { baselineText != variantText }
    var canonicalizedChanged: Bool { baselineCanonicalized != variantCanonicalized }
    var vocabularyHitDelta: Int { variantVocabularyHits.count - baselineVocabularyHits.count }
    var elapsedDeltaSeconds: Double { variantElapsedSeconds - baselineElapsedSeconds }
    var hasAlternatives: Bool { !variantAlternatives.isEmpty }
    var hasDifferentAlternative: Bool { variantAlternatives.contains { $0 != variantText } }
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
        lines.append(
            "  context: \(row.applicationMode.rawValue) terms=\(row.contextTermCount) " +
                "readback=\(row.contextReadbackCount) alternatives=\(row.variantAlternatives.count)"
        )
        if row.canonicalizedChanged {
            lines.append("  base can: \(row.baselineCanonicalized)")
            lines.append("  ctx can:  \(row.variantCanonicalized)")
        }
        if row.vocabularyHitDelta != 0 {
            lines.append("  base hits: \(row.baselineVocabularyHits.joined(separator: ", "))")
            lines.append("  ctx hits:  \(row.variantVocabularyHits.joined(separator: ", "))")
        }
        if row.hasAlternatives {
            lines.append("  alternatives: \(row.variantAlternatives.joined(separator: " | "))")
        }
    }

    private func tags(for row: SpeechContextEvalRow) -> [String] {
        var tags: [String] = []
        if row.rawChanged { tags.append("RAW-CHANGED") }
        if row.canonicalizedChanged { tags.append("CANON-CHANGED") }
        if row.vocabularyHitDelta > 0 { tags.append("VOCAB-GAIN") }
        if row.vocabularyHitDelta < 0 { tags.append("VOCAB-LOSS") }
        if !row.contextReadbackMatches { tags.append("READBACK-MISMATCH") }
        if row.hasAlternatives { tags.append("ALTERNATIVES") }
        if row.hasDifferentAlternative { tags.append("ALT-DIFF") }
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
        var contextReadbackMismatches = 0
        var alternativesRows = 0
        var differentAlternativeRows = 0
        var elapsedDeltaTotal = 0.0

        mutating func add(_ row: SpeechContextEvalRow) {
            rows += 1
            contextTermCount = row.contextTermCount
            elapsedDeltaTotal += row.elapsedDeltaSeconds
            if row.rawChanged { rawChanged += 1 }
            if row.canonicalizedChanged { canonicalizedChanged += 1 }
            if row.vocabularyHitDelta > 0 { vocabularyHitGains += 1 }
            if row.vocabularyHitDelta < 0 { vocabularyHitLosses += 1 }
            if !row.contextReadbackMatches { contextReadbackMismatches += 1 }
            if row.hasAlternatives { alternativesRows += 1 }
            if row.hasDifferentAlternative { differentAlternativeRows += 1 }
        }

        func report(variant: String) -> String {
            let meanDelta = rows == 0 ? 0 : elapsedDeltaTotal / Double(rows)
            return "\(variant): context terms=\(contextTermCount) " +
                "raw changed=\(rawChanged) canonicalized changed=\(canonicalizedChanged) " +
                "vocabulary hit gains/losses=\(vocabularyHitGains)/\(vocabularyHitLosses) " +
                "readback mismatches=\(contextReadbackMismatches) " +
                "alternatives/different=\(alternativesRows)/\(differentAlternativeRows) " +
                "mean latency delta=\(String(format: "%+.3f", meanDelta))s"
        }
    }
}
