#if DEBUG
import Foundation

struct ApplePresetEvalRow: Codable {
    let arm: ApplePresetArm
    let configuration: String
    let locale: String
    let file: String
    let audioSHA256: String
    let audioDurationSeconds: Double
    let humanIntendedTranscript: String
    let referenceDesignation: ReferenceDesignation
    let transcript: String
    let transcriptScore: WordErrorScore
    let productionOutput: String
    let productionOutputTranscriptScore: WordErrorScore
    let elapsedSeconds: Double
    let rtfX: Double?
    let error: String?
    let correctionDictionaryFingerprint: String?
    let contextualStrings: [String]?
    let contextReadback: [String]?
    let evalProvenance: ApplePresetEvalProvenance?

    var isEmpty: Bool {
        transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum ApplePresetEvalReport {
    static func render(
        rows: [ApplePresetEvalRow],
        enabledArms: [ApplePresetArm],
        unavailable: [ApplePresetArm: String],
        expectedRowsPerArm: Int,
        outputURL: URL,
        summaryURL: URL
    ) -> String {
        let baseline = Dictionary(
            uniqueKeysWithValues: rows
                .filter { $0.arm == .baseline }
                .map { ($0.file, $0) }
        )
        let hasContextMetadata = rows.contains { $0.contextualStrings != nil }
        var lines = [
            "Apple on-device transcriber preset eval:",
            "  recordings: \(expectedRowsPerArm)",
            "  arm order: rotated once per recording",
            "  baseline context: " + (hasContextMetadata
                ? "canonical vocabulary from the frozen persisted dictionary" : "unrecorded in legacy artifact"),
            "  control context: " + (hasContextMetadata ? "none" : "unrecorded in legacy artifact"),
        ]
        if let row = rows.first, let provenance = row.evalProvenance {
            lines.append("  dictionary SHA-256: \(row.correctionDictionaryFingerprint ?? "unknown")")
            lines.append("  corpus SHA-256: \(provenance.corpusSHA256)")
            lines.append("  source revision: \(provenance.sourceRevision ?? "unknown")")
            lines.append("  source tree dirty: \(provenance.sourceTreeDirty.map(String.init) ?? "unknown")")
            lines.append(
                "  build: \(provenance.buildConfiguration ?? "unknown") "
                    + "optimization=\(provenance.compilerOptimization ?? "unknown") "
                    + "sdk=\(provenance.sdk ?? "unknown")"
            )
            lines.append("  runtime: \(provenance.osVersion) \(provenance.architecture)")
            lines.append("  executable SHA-256: \(provenance.executableSHA256)")
        }
        for arm in enabledArms {
            let armRows = rows.filter { $0.arm == arm }
            let rawErrors = armRows.reduce(0) { $0 + $1.transcriptScore.wordErrors }
            let outputErrors = armRows.reduce(0) {
                $0 + $1.productionOutputTranscriptScore.wordErrors
            }
            let totalWords = armRows.reduce(0) { $0 + $1.transcriptScore.referenceWordCount }
            let rawExact = armRows.filter { $0.transcriptScore.wordErrors == 0 }.count
            let outputExact = armRows.filter {
                $0.productionOutputTranscriptScore.wordErrors == 0
            }.count
            let failed = armRows.filter { $0.error != nil }.count
            let empty = armRows.filter(\.isEmpty).count
            let audio = armRows.reduce(0) { $0 + $1.audioDurationSeconds }
            let elapsed = armRows.reduce(0) { $0 + $1.elapsedSeconds }
            let comparison = compare(armRows, baseline: baseline)
            let matchedContext = armRows.filter { row in
                guard let expected = row.contextualStrings, let actual = row.contextReadback else { return false }
                return expected == actual
            }.count
            lines.append(
                "  \(arm.rawValue): rows=\(armRows.count)/\(expectedRowsPerArm) "
                    + "rawWER=\(format(Double(rawErrors) / Double(max(totalWords, 1)), 6)) "
                    + "outputWER=\(format(Double(outputErrors) / Double(max(totalWords, 1)), 6)) "
                    + "exactRaw/output=\(rawExact)/\(outputExact) "
                    + "failed=\(failed) empty=\(empty) "
                    + "contextReadbackMatched=\(matchedContext) "
                    + "outputWins/losses/ties-vs-current="
                    + "\(comparison.wins)/\(comparison.losses)/\(comparison.ties) "
                    + "RTFx=\(elapsed > 0 ? format(audio / elapsed, 2) : "n/a")"
            )
            for row in armRows where row.error != nil || row.isEmpty {
                lines.append("    \(row.file): \(row.error ?? "empty transcript")")
            }
        }
        for arm in ApplePresetArm.allCases {
            if let reason = unavailable[arm] {
                lines.append("  \(arm.rawValue): unavailable (\(reason))")
            }
        }
        lines.append("  output: \(outputURL.path)")
        lines.append("  summary: \(summaryURL.path)")
        return lines.joined(separator: "\n")
    }

    private static func compare(
        _ rows: [ApplePresetEvalRow],
        baseline: [String: ApplePresetEvalRow]
    ) -> (wins: Int, losses: Int, ties: Int) {
        var result = (wins: 0, losses: 0, ties: 0)
        for row in rows {
            guard let baselineRow = baseline[row.file] else { continue }
            let delta = row.productionOutputTranscriptScore.wordErrors
                - baselineRow.productionOutputTranscriptScore.wordErrors
            if delta < 0 {
                result.wins += 1
            } else if delta > 0 {
                result.losses += 1
            } else {
                result.ties += 1
            }
        }
        return result
    }

    private static func format(_ value: Double, _ digits: Int) -> String {
        String(format: "%.\(digits)f", value)
    }
}
#endif
