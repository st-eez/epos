import Foundation

/// Loads Apple Speech contextual strings from a user-editable runtime config file.
public struct SpeechContext: Sendable {
    public static let maxPhraseCount = 100

    private static let log = SteezFlowLogger(category: "speech-context")

    private let fileURL: URL?

    public init() {
        self.fileURL = Self.defaultFileURL()
    }

    public init(fileURL: URL?) {
        self.fileURL = fileURL
    }

    public func load() -> [String] {
        let started = Date()
        guard let fileURL else {
            Self.log.error("speech context path unavailable")
            return []
        }

        do {
            try ensureFileExists(at: fileURL)
            let contents = try String(contentsOf: fileURL, encoding: .utf8)
            let phrases = Self.parse(contents)
            let elapsedMs = Int(Date().timeIntervalSince(started) * 1_000)
            Self.log.info("speech context loaded count=\(phrases.count) elapsedMs=\(elapsedMs)")
            return phrases
        } catch {
            Self.log.error("speech context load failed: \(String(describing: error))")
            return []
        }
    }

    static func parse(_ contents: String, limit: Int = maxPhraseCount) -> [String] {
        var phrases: [String] = []
        var seen: Set<String> = []

        for line in contents.components(separatedBy: .newlines) {
            let phrase = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !phrase.isEmpty, !phrase.hasPrefix("#") else { continue }
            guard seen.insert(phrase).inserted else { continue }
            phrases.append(phrase)
            if phrases.count == limit {
                break
            }
        }

        return phrases
    }

    private func ensureFileExists(at fileURL: URL) throws {
        let fileManager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        guard !fileManager.fileExists(atPath: fileURL.path) else { return }

        let template = """
        # SteezFlow speech context
        # Add one phrase per line. Blank lines and # comments are ignored.
        # Keep this list short; Apple recommends about 100 contextual strings.
        """
        try template.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    static func defaultFileURL(fileManager: FileManager = .default) -> URL? {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return appSupport
            .appendingPathComponent("SteezFlow", isDirectory: true)
            .appendingPathComponent("speech-context.txt")
    }
}
