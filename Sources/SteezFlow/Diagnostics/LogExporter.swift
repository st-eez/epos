import Foundation
import OSLog

/// Persists this process's unified-logging output for the `com.steez.SteezFlow`
/// subsystem to a dated file under `~/Library/Caches/SteezFlow/logs/`. Reads its
/// own entries via `OSLogStore(scope: .currentProcessIdentifier)` (no special
/// entitlement) and appends them on a ~2s poll loop.
///
/// This makes verbose logs durable and self-contained: they survive without the
/// fragile external `/usr/bin/log stream` redirect, which keeps getting wiped.
public final class LogExporter: @unchecked Sendable {
    private static let subsystem = "com.steez.SteezFlow"
    private static let log = Logger(subsystem: subsystem, category: "diag")

    private let lock = NSLock()
    private var started = false

    public init() {}

    /// Begin streaming subsystem entries to disk. Idempotent — repeat calls are
    /// no-ops. The baseline timestamp is captured synchronously so logs emitted
    /// immediately after this returns (e.g. bootstrap) are included.
    public func start() {
        let shouldStart: Bool = lock.withLock {
            if started { return false }
            started = true
            return true
        }
        guard shouldStart else { return }

        let baseline = Date()
        Task.detached(priority: .utility) {
            await Self.run(since: baseline)
        }
    }

    private static func run(since baseline: Date) async {
        var lastDate = baseline
        while !Task.isCancelled {
            lastDate = drain(since: lastDate)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    /// Read entries newer than `lastDate`, append them, and return the latest
    /// timestamp seen (or `lastDate` if nothing new / on failure).
    private static func drain(since lastDate: Date) -> Date {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let entries = try store.getEntries(at: store.position(date: lastDate))
            var newest = lastDate
            var lines: [String] = []
            for entry in entries {
                guard let log = entry as? OSLogEntryLog,
                      log.subsystem == subsystem,
                      log.date > lastDate else { continue }
                lines.append(format(log))
                if log.date > newest { newest = log.date }
            }
            if !lines.isEmpty {
                append(lines.joined(separator: "\n") + "\n")
            }
            return newest
        } catch {
            log.error("log export drain failed: \(String(describing: error), privacy: .public)")
            return lastDate
        }
    }

    private static func format(_ entry: OSLogEntryLog) -> String {
        let timestamp = ISO8601DateFormatter().string(from: entry.date)
        return "\(timestamp)\t\(levelName(entry.level))\t\(entry.category)\t\(entry.composedMessage)"
    }

    private static func levelName(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .undefined: return "undefined"
        case .debug: return "debug"
        case .info: return "info"
        case .notice: return "notice"
        case .error: return "error"
        case .fault: return "fault"
        @unknown default: return "unknown"
        }
    }

    /// Append `text` to today's dated log file, creating the `logs` directory and
    /// file as needed. Recomputed each batch so the file rolls over at midnight.
    private static func append(_ text: String) {
        guard let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            log.error("log export: caches directory unavailable")
            return
        }
        let dir = cachesDir.appendingPathComponent("SteezFlow/logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let url = dir.appendingPathComponent("\(formatter.string(from: Date())).log")

        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            log.error("log export: open for append failed")
            return
        }
        defer { try? handle.close() }
        guard let data = text.data(using: .utf8) else { return }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            log.error("log export write failed: \(String(describing: error), privacy: .public)")
        }
    }
}
