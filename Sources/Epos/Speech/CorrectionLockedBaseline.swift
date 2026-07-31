import Foundation

/// The reference transcripts a promoted correction must leave untouched.
///
/// `scripts/correct` refuses a candidate that regresses the frozen corpus. The in-app
/// Accept button has to clear the same bar, so it evaluates the candidate against the
/// human-confirmed rows of that corpus: a rule that rewrites text a human confirmed as
/// correct moves away from the reference by construction, which is a word-error
/// regression on the exact rows `scripts/correct` scores.
///
/// The check the app cannot reproduce is the other half of that bar — proving a holdout
/// *win* needs the recognizer re-run over the saved audio, which only the signed eval
/// arm does. In-app promotion is therefore a strict subset: everything it accepts still
/// has to survive `scripts/correct` before it counts as an accuracy claim.
///
/// `unavailable` is not "no rows to check". A missing or malformed corpus means the
/// check could not run, and the gate blocks rather than promoting unverified.
public enum CorrectionLockedBaseline: Equatable, Sendable {
    case confirmed([String])
    case unavailable(String)
}

public extension CorrectionLockedBaseline {
    /// Legacy manifest ordinals `1...35` are the human-confirmed rows of the frozen
    /// migration (`specs/evaluation-corpus.md`); ordinals `36...114` were inferred from
    /// recognizer output and are not human truth. The manifest carries the ordinal as
    /// its line order, so the confirmed rows are its first 35 lines.
    static let humanConfirmedLegacyRowCount = 35

    /// Reads the frozen corpus from its one authoritative location. Fails closed with a
    /// reason — never an empty success — when the corpus is absent or does not have the
    /// shape the frozen migration promises. The reason names only files and counts, so
    /// logging it cannot leak transcript text.
    static func load(recordingsDirectory: URL? = nil) -> CorrectionLockedBaseline {
        let result = loading(recordingsDirectory: recordingsDirectory)
        if case .unavailable(let reason) = result {
            EposLogger(category: "corrections").error("locked baseline unavailable: \(reason)")
        }
        return result
    }

    private static func loading(recordingsDirectory: URL?) -> CorrectionLockedBaseline {
        guard let directory = recordingsDirectory ?? defaultRecordingsDirectory() else {
            return .unavailable("no application support directory")
        }

        let legacy = confirmedTranscripts(
            in: directory.appendingPathComponent("ground-truth.jsonl"),
            named: "ground-truth.jsonl"
        )
        guard case .confirmed(let legacyTexts) = legacy else { return legacy }
        guard legacyTexts.count >= humanConfirmedLegacyRowCount else {
            return .unavailable(
                "ground-truth.jsonl has \(legacyTexts.count) rows, "
                    + "expected at least \(humanConfirmedLegacyRowCount)"
            )
        }

        let holdout = confirmedTranscripts(
            in: directory.appendingPathComponent("holdout-confirmations.jsonl"),
            named: "holdout-confirmations.jsonl"
        )
        guard case .confirmed(let holdoutTexts) = holdout else { return holdout }

        return .confirmed(
            Array(legacyTexts.prefix(humanConfirmedLegacyRowCount)) + holdoutTexts
        )
    }

    private static func confirmedTranscripts(in url: URL, named name: String) -> CorrectionLockedBaseline {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return .unavailable("\(name) is missing or unreadable")
        }

        let decoder = JSONDecoder()
        var transcripts: [String] = []
        for line in contents.split(whereSeparator: \.isNewline) {
            guard let row = try? decoder.decode(ConfirmedRow.self, from: Data(line.utf8)) else {
                return .unavailable("\(name) has a malformed row")
            }
            let transcript = row.humanIntendedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcript.isEmpty else {
                return .unavailable("\(name) has an empty transcript")
            }
            transcripts.append(transcript)
        }

        guard !transcripts.isEmpty else {
            return .unavailable("\(name) is empty")
        }
        return .confirmed(transcripts)
    }

    private static func defaultRecordingsDirectory() -> URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Epos/recordings", isDirectory: true)
    }
}

private struct ConfirmedRow: Decodable {
    let humanIntendedTranscript: String
}
