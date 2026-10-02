#if DEBUG
import Foundation

enum AnalyzerPreparationEvalReport {
    static func render(rows: [AnalyzerPreparationEvalRow], output: URL) -> String {
        var lines = [
            "Analyzer preparation evaluation. Saved audio paced at its audio rate.",
            "First trial is ordinal 1; Speech service coldness is unknown.",
            "Advanced preparation reports work before the hold separately.",
        ]
        for arm in AnalyzerPreparationArm.allCases {
            let armRows = rows.filter { $0.arm == arm }
            let metrics = armRows.compactMap(\.metrics)
            let errors = armRows.reduce(0) { $0 + $1.productionOutputScore.wordErrors }
            let words = armRows.reduce(0) { $0 + $1.productionOutputScore.referenceWordCount }
            let failures = armRows.filter { $0.error != nil || $0.transcript.isEmpty }.count
            let baseline = Dictionary(uniqueKeysWithValues: rows.filter { $0.arm == .unprepared }.map {
                ("\($0.repeatIndex)/\($0.file)", $0)
            })
            let pairedFirstResultDeltas = armRows.compactMap { row -> Double? in
                guard let baselineValue = baseline["\(row.repeatIndex)/\(row.file)"]?
                    .metrics?.holdToFirstResultMilliseconds,
                      let armValue = row.metrics?.holdToFirstResultMilliseconds else { return nil }
                return armValue - baselineValue
            }
            lines.append(
                "\(arm.rawValue): rows=\(armRows.count) failed/empty=\(failures) "
                    + "outputWER=\(formatted(Double(errors) / Double(max(words, 1)))) "
                    + "median ms prepare=\(median(metrics.map(\.preparationMilliseconds))) "
                    + "setupBeforeHold=\(median(metrics.map(\.setupBeforeHoldMilliseconds))) "
                    + "idleSeconds=\(median(metrics.map(\.idleSeconds))) "
                    + "start=\(median(metrics.map(\.analyzerStartMilliseconds))) "
                    + "holdToFirstResult=\(median(metrics.compactMap(\.holdToFirstResultMilliseconds))) "
                    + "inputToFirstResult=\(median(metrics.compactMap(\.inputToFirstResultMilliseconds))) "
                    + "releaseToFinal=\(median(metrics.map(\.releaseToFinalMilliseconds))) "
                    + "readyRSSMiB=\(median(metrics.compactMap { $0.rssAtReadinessBytes.map(mib) })) "
                    + "idleRSSMiB=\(median(metrics.compactMap { $0.rssAfterIdleBytes.map(mib) }))"
            )
            let differences = armRows.filter {
                baseline["\($0.repeatIndex)/\($0.file)"]?.productionOutput != $0.productionOutput
            }.count
            lines.append("  output differences from matching unprepared trials=\(differences)")
            lines.append("  paired median first-result delta from unprepared ms=\(median(pairedFirstResultDeltas))")
        }
        lines.append("RSS samples belong to the evaluation process and include its buffers and framework state.")
        lines.append("output: \(output.path)")
        return lines.joined(separator: "\n")
    }

    private static func mib(_ bytes: UInt64) -> Double {
        Double(bytes) / 1_048_576
    }

    private static func median(_ values: [Double]) -> String {
        guard !values.isEmpty else { return "n/a" }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return formatted(sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle])
    }

    private static func formatted(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}
#endif
