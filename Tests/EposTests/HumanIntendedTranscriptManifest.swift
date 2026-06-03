import Foundation

struct HumanIntendedTranscriptManifest {
    let sourceURL: URL?
    private let transcriptsByFile: [String: String]

    init(sourceURL: URL?, transcriptsByFile: [String: String]) {
        self.sourceURL = sourceURL
        self.transcriptsByFile = transcriptsByFile
    }

    static func load(from url: URL) throws -> HumanIntendedTranscriptManifest {
        let body = try String(contentsOf: url, encoding: .utf8)
        let decoder = JSONDecoder()
        var transcripts: [String: String] = [:]

        for (offset, rawLine) in body.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let row = try decodeRow(line: line, lineNumber: offset + 1, url: url, decoder: decoder)
            let file = row.file.trimmingCharacters(in: .whitespacesAndNewlines)
            let transcript = row.humanIntendedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !file.isEmpty, !transcript.isEmpty else {
                throw SavedRecordingEvalError.groundTruthManifestDecodeFailed(
                    url.path,
                    offset + 1,
                    "file and humanIntendedTranscript must be non-empty"
                )
            }
            guard transcripts[file] == nil else {
                throw SavedRecordingEvalError.duplicateGroundTruthTranscript(file)
            }
            transcripts[file] = transcript
        }

        return HumanIntendedTranscriptManifest(sourceURL: url, transcriptsByFile: transcripts)
    }

    func transcript(for recording: URL) -> String? {
        transcriptsByFile[recording.lastPathComponent]
    }

    private static func decodeRow(
        line: String,
        lineNumber: Int,
        url: URL,
        decoder: JSONDecoder
    ) throws -> HumanIntendedTranscriptManifestRow {
        guard let data = line.data(using: .utf8) else {
            throw SavedRecordingEvalError.groundTruthManifestDecodeFailed(
                url.path,
                lineNumber,
                "line is not valid UTF-8"
            )
        }
        do {
            return try decoder.decode(HumanIntendedTranscriptManifestRow.self, from: data)
        } catch {
            throw SavedRecordingEvalError.groundTruthManifestDecodeFailed(
                url.path,
                lineNumber,
                String(describing: error)
            )
        }
    }
}

private struct HumanIntendedTranscriptManifestRow: Decodable {
    let file: String
    let humanIntendedTranscript: String
}
