import Foundation
import XCTest
@testable import Epos

final class LatencyTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock().now

    var now: ContinuousClock.Instant { lock.withLock { instant } }

    func advance(_ duration: Duration) {
        lock.withLock { instant = instant.advanced(by: duration) }
    }
}

final class LatencyTestLog {
    let clock = LatencyTestClock()
    let sink: DiagnosticLogSink
    let timing: RecordingLatencyDiagnostics
    private let directory: URL

    init() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("EposTiming-\(UUID())")
        sink = DiagnosticLogSink(configuration: .init(enabled: true), directory: directory)
        let clock = clock
        timing = RecordingLatencyDiagnostics(recordingID: "timed", diagnostics: sink, now: { clock.now })
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func rows() throws -> [[String: String]] {
        sink.flush()
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let lines = try files.map { try String(contentsOf: $0, encoding: .utf8).components(separatedBy: "\n") }
        return lines.joined()
            .filter { $0.contains("recording timing ") }
            .map { line in
                Dictionary(uniqueKeysWithValues: line.split(separator: " ").compactMap { token in
                    let pair = token.split(separator: "=", maxSplits: 1).map(String.init)
                    return pair.count == 2 ? (pair[0], pair[1]) : nil
                })
            }
    }

    func row(_ stage: RecordingLatencyDiagnostics.Stage, attempt: Int = 1) throws -> [String: String] {
        try XCTUnwrap(rows().first { $0["stage"] == stage.rawValue && $0["attempt"] == String(attempt) })
    }
}
