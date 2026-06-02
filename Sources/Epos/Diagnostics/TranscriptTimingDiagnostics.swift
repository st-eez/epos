import Foundation

enum TranscriptTimingEventKind: String {
    case partial
    case final
}

struct TranscriptTimingDiagnostics {
    private var startedAt: Date?
    private var sequence = 0

    mutating func start(now: Date = Date()) {
        startedAt = now
        sequence = 0
    }

    mutating func finish() {
        startedAt = nil
        sequence = 0
    }

    mutating func eventMessage(
        kind: TranscriptTimingEventKind,
        eventText: String,
        finalText: String,
        partialText: String,
        now: Date = Date()
    ) -> String {
        sequence += 1
        let elapsedMs = startedAt.map { Int((now.timeIntervalSince($0) * 1_000).rounded()) } ?? -1
        let finalChars = Self.characterCount(finalText)
        let partialChars = Self.characterCount(partialText)

        return [
            "transcript timing",
            "seq=\(sequence)",
            "kind=\(kind.rawValue)",
            "elapsedMs=\(max(-1, elapsedMs))",
            "eventChars=\(Self.characterCount(eventText))",
            "finalChars=\(finalChars)",
            "partialChars=\(partialChars)",
            "displayChars=\(finalChars + partialChars)",
            "eventText=\(Self.quoted(eventText))",
            "finalText=\(Self.quoted(finalText))",
            "partialText=\(Self.quoted(partialText))",
            "displayText=\(Self.quoted(finalText + partialText))"
        ].joined(separator: " ")
    }

    private static func characterCount(_ text: String) -> Int {
        text.utf16.count
    }

    private static func quoted(_ text: String) -> String {
        String(reflecting: text)
    }
}
