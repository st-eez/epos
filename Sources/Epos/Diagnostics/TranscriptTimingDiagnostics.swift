import Foundation

enum TranscriptDiagnosticTextPolicy {
    static let environmentKey = "EPOS_DIAGNOSTIC_TRANSCRIPT_TEXT"

    static func load(
        from environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment[environmentKey] == "1"
    }
}

enum TranscriptTimingEventKind: String {
    case partial
    case final
}

struct TranscriptTimingDiagnostics {
    private let includeTranscriptText: Bool
    private var startedAt: Date?
    private var sequence = 0

    init(includeTranscriptText: Bool = TranscriptDiagnosticTextPolicy.load()) {
        self.includeTranscriptText = includeTranscriptText
    }

    mutating func start(now: Date = Date()) {
        startedAt = now
        sequence = 0
    }

    mutating func finish() {
        startedAt = nil
        sequence = 0
    }

    /// `displayText` is the coordinator's streamed display — the cleaned transform
    /// the one final write also applies. It is passed in rather than reconstructed:
    /// `finalText + partialText` stopped being what the user sees when the display
    /// started streaming cleaned text, and a `displayText=` field carrying the raw
    /// concatenation makes the log lie about exactly the divergence it exists to
    /// investigate. The raw assembly is still recoverable from the two raw fields.
    mutating func eventMessage(
        kind: TranscriptTimingEventKind,
        eventText: String,
        finalText: String,
        partialText: String,
        displayText: String,
        now: Date = Date()
    ) -> String {
        sequence += 1
        let elapsedMs = startedAt.map { Int((now.timeIntervalSince($0) * 1_000).rounded()) } ?? -1

        var fields = [
            "transcript timing",
            "seq=\(sequence)",
            "kind=\(kind.rawValue)",
            "elapsedMs=\(max(-1, elapsedMs))",
            "eventChars=\(Self.characterCount(eventText))",
            "finalChars=\(Self.characterCount(finalText))",
            "partialChars=\(Self.characterCount(partialText))",
            "displayChars=\(Self.characterCount(displayText))"
        ]
        if includeTranscriptText {
            fields.append(contentsOf: [
                "eventText=\(Self.quoted(eventText))",
                "finalText=\(Self.quoted(finalText))",
                "partialText=\(Self.quoted(partialText))",
                "displayText=\(Self.quoted(displayText))"
            ])
        }
        return fields.joined(separator: " ")
    }

    private static func characterCount(_ text: String) -> Int {
        text.utf16.count
    }

    private static func quoted(_ text: String) -> String {
        String(reflecting: text)
    }
}
