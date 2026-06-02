import Foundation
import OSLog

public enum DiagnosticLogLevel: String, Sendable {
    case debug
    case info
    case error
    case fault
}

public struct DiagnosticLogConfiguration: Equatable, Sendable {
    public var enabled: Bool
    public var maxFileBytes: UInt64
    public var maxFileCount: Int
    public var maxMessageCharacters: Int

    public init(
        enabled: Bool = true,
        maxFileBytes: UInt64 = 10_000_000,
        maxFileCount: Int = 14,
        maxMessageCharacters: Int = 20_000
    ) {
        self.enabled = enabled
        self.maxFileBytes = maxFileBytes
        self.maxFileCount = maxFileCount
        self.maxMessageCharacters = maxMessageCharacters
    }

    public static func load(
        from environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> DiagnosticLogConfiguration {
        DiagnosticLogConfiguration(
            enabled: environment["EPOS_DIAGNOSTIC_LOGS"] != "0",
            maxFileBytes: positiveUInt64(
                environment["EPOS_DIAGNOSTIC_MAX_FILE_BYTES"],
                defaultValue: 10_000_000
            ),
            maxFileCount: positiveInt(
                environment["EPOS_DIAGNOSTIC_MAX_FILE_COUNT"],
                defaultValue: 14
            ),
            maxMessageCharacters: positiveInt(
                environment["EPOS_DIAGNOSTIC_MAX_MESSAGE_CHARS"],
                defaultValue: 20_000
            )
        )
    }

    private static func positiveUInt64(_ raw: String?, defaultValue: UInt64) -> UInt64 {
        guard let raw, let value = UInt64(raw), value > 0 else { return defaultValue }
        return value
    }

    private static func positiveInt(_ raw: String?, defaultValue: Int) -> Int {
        guard let raw, let value = Int(raw), value > 0 else { return defaultValue }
        return value
    }
}

final class RecordingLogContextStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var activeRecordingID: String?

    func activate(_ recordingID: String) {
        lock.withLock {
            activeRecordingID = recordingID
        }
    }

    func clear(_ recordingID: String?) {
        lock.withLock {
            guard recordingID == nil || activeRecordingID == recordingID else { return }
            activeRecordingID = nil
        }
    }

    func current() -> String? {
        lock.withLock { activeRecordingID }
    }
}

public enum RecordingID {
    public static func make() -> String {
        String(UUID().uuidString.prefix(8)).lowercased()
    }
}

enum RecordingLogContext {
    private static let storage = RecordingLogContextStorage()

    static func makeRecordingID() -> String {
        RecordingID.make()
    }

    static func activate(_ recordingID: String) {
        storage.activate(sanitize(recordingID))
    }

    static func clear(_ recordingID: String? = nil) {
        storage.clear(recordingID.map(sanitize))
    }

    static var currentRecordingID: String? {
        storage.current()
    }

    private static func sanitize(_ recordingID: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = recordingID.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "_"
        }
        let sanitized = String(String(scalars).prefix(64))
        return sanitized.isEmpty ? "unknown" : sanitized
    }
}

/// Lightweight app-owned diagnostic log sink. This intentionally writes direct
/// app events to disk instead of polling Apple's unified log store.
public final class DiagnosticLogSink: @unchecked Sendable {
    public static let shared = DiagnosticLogSink()

    private let configuration: DiagnosticLogConfiguration
    private let directory: URL?
    private let queue = DispatchQueue(label: "com.steez.Epos.diagnostic-log", qos: .utility)
    private let fileManager: FileManager

    public convenience init(configuration: DiagnosticLogConfiguration = .load()) {
        self.init(configuration: configuration, directory: nil)
    }

    init(
        configuration: DiagnosticLogConfiguration,
        directory: URL?,
        fileManager: FileManager = .default
    ) {
        self.configuration = configuration
        self.directory = directory
        self.fileManager = fileManager
    }

    public func append(
        level: DiagnosticLogLevel,
        category: String,
        message: String,
        date: Date = Date()
    ) {
        guard configuration.enabled else { return }
        queue.async {
            guard let directory = self.resolveDirectory() else { return }
            _ = try? self.fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            guard let url = self.logFileURL(in: directory, date: date) else { return }
            self.appendLine(
                self.format(level: level, category: category, message: message, date: date),
                to: url
            )
            self.pruneFiles(in: directory)
        }
    }

    func flush() {
        queue.sync {}
    }

    private func resolveDirectory() -> URL? {
        if let directory {
            return directory
        }
        guard let cachesDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        return cachesDir.appendingPathComponent("Epos/logs", isDirectory: true)
    }

    private func logFileURL(in directory: URL, date: Date) -> URL? {
        let day = Self.dayString(from: date)
        for index in 0..<100 {
            let suffix = index == 0 ? "" : "-\(index)"
            let url = directory.appendingPathComponent("\(day)\(suffix).log")
            guard fileManager.fileExists(atPath: url.path) else {
                return url
            }
            let size = Self.fileSize(url, fileManager: fileManager)
            if size < configuration.maxFileBytes {
                return url
            }
        }
        return nil
    }

    private func appendLine(_ line: String, to url: URL) {
        if !fileManager.fileExists(atPath: url.path) {
            _ = fileManager.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url),
              let data = (line + "\n").data(using: .utf8) else {
            return
        }
        defer { _ = try? handle.close() }
        _ = try? handle.seekToEnd()
        _ = try? handle.write(contentsOf: data)
    }

    private func pruneFiles(in directory: URL) {
        guard configuration.maxFileCount > 0,
              let files = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
              ) else {
            return
        }
        let logFiles = files
            .filter { $0.pathExtension == "log" }
            .sorted { lhs, rhs in
                Self.modifiedDate(lhs) > Self.modifiedDate(rhs)
            }
        for url in logFiles.dropFirst(configuration.maxFileCount) {
            _ = try? fileManager.removeItem(at: url)
        }
    }

    private func format(
        level: DiagnosticLogLevel,
        category: String,
        message: String,
        date: Date
    ) -> String {
        [
            Self.timestampString(from: date),
            level.rawValue,
            sanitize(category),
            sanitize(message)
        ].joined(separator: "\t")
    }

    private func sanitize(_ text: String) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        if collapsed.count <= configuration.maxMessageCharacters {
            return collapsed
        }
        return String(collapsed.prefix(configuration.maxMessageCharacters))
    }

    private static func fileSize(_ url: URL, fileManager: FileManager) -> UInt64 {
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else {
            return 0
        }
        return size.uint64Value
    }

    private static func modifiedDate(_ url: URL) -> Date {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate ?? .distantPast
    }

    private static func dayString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func timestampString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

public struct EposLogger: Sendable {
    private static let subsystem = "com.steez.Epos"

    private let category: String
    private let system: Logger
    private let diagnostics: DiagnosticLogSink

    public init(category: String, diagnostics: DiagnosticLogSink = .shared) {
        self.category = category
        self.system = Logger(subsystem: Self.subsystem, category: category)
        self.diagnostics = diagnostics
    }

    public func debug(_ message: @autoclosure () -> String, recordingID: String? = nil) {
        let text = scoped(message(), recordingID: recordingID)
        system.debug("\(text, privacy: .public)")
        diagnostics.append(level: .debug, category: category, message: text)
    }

    public func info(_ message: @autoclosure () -> String, recordingID: String? = nil) {
        let text = scoped(message(), recordingID: recordingID)
        system.info("\(text, privacy: .public)")
        diagnostics.append(level: .info, category: category, message: text)
    }

    public func error(_ message: @autoclosure () -> String, recordingID: String? = nil) {
        let text = scoped(message(), recordingID: recordingID)
        system.error("\(text, privacy: .public)")
        diagnostics.append(level: .error, category: category, message: text)
    }

    public func fault(_ message: @autoclosure () -> String, recordingID: String? = nil) {
        let text = scoped(message(), recordingID: recordingID)
        system.fault("\(text, privacy: .public)")
        diagnostics.append(level: .fault, category: category, message: text)
    }

    private func scoped(_ message: String, recordingID: String?) -> String {
        guard !message.hasPrefix("recordingID=") else { return message }
        guard let recordingID = recordingID ?? RecordingLogContext.currentRecordingID else {
            return message
        }
        return "recordingID=\(recordingID) \(message)"
    }
}
