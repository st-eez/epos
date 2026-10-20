import AppKit
import CryptoKit
import XCTest
@testable import Epos

@MainActor
final class NativePreviewSchedulingTests: XCTestCase {
    func testNativePreviewScheduling() async throws {
        guard let path = ProcessInfo.processInfo.environment["EPOS_NATIVE_SCHEDULING_CONFIG"] else {
            throw XCTSkip("Set EPOS_NATIVE_SCHEDULING_CONFIG for an owned foreground Ghostty fixture")
        }
        _ = NSApplication.shared
        let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("run-started"),
                                                withIntermediateDirectories: false)
        try require(config.nonce.hasPrefix("EPOS-SESSION-"), "invalid fixture nonce")
        try require(config.targetPID > 0 && config.companionPID > 0, "invalid process identity")
        try require(NSRunningApplication.runningApplications(withBundleIdentifier: "com.steez.Epos").isEmpty,
                    "stop Epos before using its companion from a standalone driver")
        try require(NSRunningApplication(processIdentifier: config.companionPID)?.bundleIdentifier
                    == PreviewKeyboardSource.companionIdentifier, "wrong companion process")
        try verifyFixture(config, directory: directory, expected: Data())
        _ = try target(config)
        let source = try XCTUnwrap(PreviewKeyboardSource(), "existing input-source consent required")
        defer { source.release() }
        try Data("ready\n".utf8).write(to: directory.appendingPathComponent("source-ready"))
        try await waitForFile("start", in: directory)
        var expected = Data("x".utf8)
        try verifyFixture(config, directory: directory, expected: expected)
        let output = directory.appendingPathComponent("native-replays.jsonl")
        try Data().write(to: output, options: .atomic)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        for pair in 0..<6 {
            for interval in pair.isMultiple(of: 2) ? [100, 0] : [0, 100] {
                let result = try await trial(config, pair: pair, interval: interval, visual: false, directory: directory)
                expected.append(Data("EPOS final token".utf8))
                try await waitForDelivery(config, directory: directory, expected: expected)
                try handle.write(contentsOf: JSONEncoder().encode(result))
                try handle.write(contentsOf: Data("\n".utf8))
            }
        }
        let visual = try await trial(config, pair: 6, interval: 0, visual: true, directory: directory)
        expected.append(Data("EPOS final token".utf8))
        try await waitForDelivery(config, directory: directory, expected: expected)
        try JSONEncoder().encode(visual).write(to: directory.appendingPathComponent("visual.json"))
        try Data("complete\n".utf8).write(to: directory.appendingPathComponent("complete"))
    }

    private func trial(
        _ config: Configuration, pair: Int, interval: Int, visual: Bool, directory: URL
    ) async throws -> Trial {
        let observer = try target(config)
        let acquisition = try XCTUnwrap(PreviewKeyboardSource())
        defer { acquisition.release() }
        let lastMarkStarted = expectation(description: "final native draft request started")
        let transport = TimedNativeTransport { lastMarkStarted.fulfill() }
        let session = InlinePreviewSession(
            transport: transport, bundleIdentifier: "com.mitchellh.ghostty",
            acquisitionArgument: acquisition.acquisitionArgument,
            throttle: .milliseconds(interval),
            validateTarget: {
                NSWorkspace.shared.frontmostApplication?.processIdentifier == config.targetPID
                    && !observer.focusChangedSinceStart()
            }
        )
        do {
            await session.begin()
            let began = await session.report()
            try require(began.began && began.failure == nil, "native begin failed: \(began.logLine)")
            let initialUsage = try usage(config)
            let started = ContinuousClock.now
            await transport.startTiming(at: started)
            var publications: [Publication] = []
            var offsets: [Double] = []
            for burst in 0..<8 {
                for offset in [0, 1, 3] { offsets.append(Double(burst * 180 + offset)) }
            }
            for (index, offset) in offsets.enumerated() {
                try await ContinuousClock().sleep(until: started.advanced(by: .milliseconds(offset)), tolerance: .zero)
                let prefix = pair % 3 == 1 ? String(repeating: "synthetic native preview ", count: 80) : "EPOS native preview "
                let text = prefix + String(index)
                publications.append(Publication(text: text, scheduledMilliseconds: offset,
                                                milliseconds: milliseconds(since: started)))
                await session.mark(text)
            }
            try await ContinuousClock().sleep(until: started.advanced(by: .milliseconds(1_400)), tolerance: .zero)
            publications.append(Publication(text: "EPOS final token", scheduledMilliseconds: 1_400,
                                            milliseconds: milliseconds(since: started)))
            await session.mark("EPOS final token")
            if pair % 3 != 2 {
                try await ContinuousClock().sleep(until: started.advanced(by: .milliseconds(1_550)), tolerance: .zero)
            }
            await fulfillment(of: [lastMarkStarted], timeout: 0.5)
            if visual {
                try Data("preview\n".utf8).write(to: directory.appendingPathComponent("visual-ready"))
                try await waitForFile("finish-visual", in: directory)
            }
            let pendingCall = await transport.currentLine != nil
            let released = milliseconds(since: started)
            try require(NSWorkspace.shared.frontmostApplication?.processIdentifier == config.targetPID
                        && !observer.focusChangedSinceStart(), "fixture focus changed before commit")
            let prepared = await session.prepareFinalCommit()
            try require(prepared, "native final preparation refused")
            let outcome = await session.commitFinalTranscript("EPOS final token")
            let completed = milliseconds(since: started)
            try require(outcome == .committed, "native commit failed: \(outcome)")
            let finalUsage = try usage(config)
            await session.discard()
            await session.awaitDrainCompletion()
            let report = await session.report()
            try require(report.failure == nil && report.committed, "native session failed: \(report.logLine)")
            let commands = await transport.commands
            try require(commands.filter { $0.line.hasPrefix("commit ") }.count == 1, "duplicate final command")
            try require(commands.allSatisfy { $0.reply.hasPrefix("ok") }, "native command refused")
            return Trial(pair: pair, throttleMilliseconds: interval, publications: publications, commands: commands,
                         releaseMilliseconds: released, completionMilliseconds: completed,
                         nativeUsageBefore: initialUsage, nativeUsageAfter: finalUsage,
                         transportCallPendingAtRelease: pendingCall)
        } catch {
            await session.discard()
            await session.awaitDrainCompletion()
            try? JSONEncoder().encode(await transport.commands)
                .write(to: directory.appendingPathComponent("failed-commands.json"))
            throw error
        }
    }

    private func target(_ config: Configuration) throws -> AXInsertionTargetObserver {
        try require(NSWorkspace.shared.frontmostApplication?.processIdentifier == config.targetPID, "owned fixture is not frontmost")
        let observer = AXInsertionTargetObserver()
        observer.captureBaseline()
        try require(observer.hasCapturedTarget()
                    && observer.targetApplicationBundleIdentifier() == "com.mitchellh.ghostty"
                    && observer.targetWindowTitle() == config.nonce, "captured target does not match owned fixture")
        return observer
    }

    private func verifyFixture(_ config: Configuration, directory: URL, expected: Data) throws {
        let url = directory.appendingPathComponent("terminal.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let modified = try XCTUnwrap(attributes[.modificationDate] as? Date)
        try require((0...2).contains(Date().timeIntervalSince(modified)), "stale terminal fixture")
        let state = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        try require(state.running && state.nonce == config.nonce && state.pid == config.fixturePID, "wrong terminal fixture")
        let digest = SHA256.hash(data: expected).map { String(format: "%02x", $0) }.joined()
        try require(state.byteCount == expected.count && state.sha256 == digest, "terminal bytes differ from expected native delivery")
    }

    private func waitForDelivery(_ config: Configuration, directory: URL, expected: Data) async throws {
        let deadline = ContinuousClock.now + .seconds(1)
        while true {
            do { try verifyFixture(config, directory: directory, expected: expected); return }
            catch {
                if ContinuousClock.now >= deadline { throw error }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    private func waitForFile(_ name: String, in directory: URL) async throws {
        let deadline = ContinuousClock.now + .seconds(60)
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) {
            try require(ContinuousClock.now < deadline, "timed out waiting for \(name)")
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func usage(_ config: Configuration) throws -> [String: Usage] {
        try ["ghostty": Usage(pid: config.targetPID), "companion": Usage(pid: config.companionPID)]
    }

    private func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw CheckFailed(message: message) }
    }

    private struct CheckFailed: Error { let message: String }
    private struct Configuration: Decodable {
        let targetPID: Int32
        let companionPID: Int32
        let fixturePID: Int32
        let nonce: String
    }
    private struct Fixture: Decodable {
        let pid: Int32
        let nonce: String
        let running: Bool
        let byteCount: Int
        let sha256: String
    }
    private struct Publication: Encodable {
        let text: String
        let scheduledMilliseconds: Double
        let milliseconds: Double
    }
    private struct Trial: Encodable {
        let pair: Int
        let throttleMilliseconds: Int
        let publications: [Publication]
        let commands: [NativeCommand]
        let releaseMilliseconds: Double
        let completionMilliseconds: Double
        let nativeUsageBefore: [String: Usage]
        let nativeUsageAfter: [String: Usage]
        let transportCallPendingAtRelease: Bool
    }
    private struct Usage: Encodable {
        let userTime: UInt64
        let systemTime: UInt64
        let timebaseNumerator: UInt32
        let timebaseDenominator: UInt32
        let residentBytes: UInt64
        let processStart: UInt64
        init(pid: Int32) throws {
            var info = rusage_info_v4()
            let status = withUnsafeMutablePointer(to: &info) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4,
                               UnsafeMutableRawPointer($0).assumingMemoryBound(to: rusage_info_t?.self))
            }
            guard status == 0 else { throw CheckFailed(message: "native process usage unavailable") }
            userTime = info.ri_user_time
            systemTime = info.ri_system_time
            var timebase = mach_timebase_info_data_t()
            guard mach_timebase_info(&timebase) == KERN_SUCCESS else {
                throw CheckFailed(message: "native timebase unavailable")
            }
            timebaseNumerator = timebase.numer
            timebaseDenominator = timebase.denom
            residentBytes = info.ri_resident_size
            processStart = info.ri_proc_start_abstime
        }
    }
}

private struct NativeCommand: Encodable {
    let line: String
    let reply: String
    let sentMilliseconds: Double
    let milliseconds: Double
}

private actor TimedNativeTransport: InlinePreviewTransport {
    private let transport = UnixSocketInlinePreviewTransport()
    private let finalMarkStarted: @Sendable () -> Void
    private var started = ContinuousClock.now
    private(set) var commands: [NativeCommand] = []
    private(set) var currentLine: String?
    init(finalMarkStarted: @escaping @Sendable () -> Void) { self.finalMarkStarted = finalMarkStarted }
    func startTiming(at instant: ContinuousClock.Instant) { started = instant; commands = [] }
    func open() async throws { try await transport.open() }
    func close() async { await transport.close() }
    func send(_ line: String) async throws -> String { try await send(line, replyTimeout: 0.5) }
    func send(_ line: String, replyTimeout: TimeInterval) async throws -> String {
        let sent = milliseconds(since: started)
        currentLine = line
        defer { currentLine = nil }
        if line == "mark EPOS final token" { finalMarkStarted() }
        let reply = try await transport.send(line, replyTimeout: replyTimeout)
        commands.append(NativeCommand(line: line, reply: reply, sentMilliseconds: sent,
                                      milliseconds: milliseconds(since: started)))
        return reply
    }
}

private func milliseconds(since instant: ContinuousClock.Instant) -> Double {
    let duration = instant.duration(to: .now).components
    return Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15
}
