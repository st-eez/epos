import XCTest
@testable import Epos

/// The inline-preview spike drives an out-of-process input method, so the
/// contracts that matter are ordering and containment: preview text is coalesced,
/// the composition is always discarded before the authoritative write, and every
/// failure mode ends as HUD-only silence rather than a stalled dictation. The real
/// socket is never touched here; `FakeInlinePreviewTransport` is the seam.
final class InlinePreviewSessionTests: XCTestCase {
    private static let target = "com.test.app"
    private static let begin = "begin com.test.app"

    // MARK: - Doubles

    private actor FakeInlinePreviewTransport: InlinePreviewTransport {
        enum Failure: Error { case denied }

        private let openThrows: Bool
        private let beginReply: String
        private let markThrows: Bool

        private(set) var lines: [String] = []
        private(set) var openCount = 0
        private(set) var closeCount = 0

        init(openThrows: Bool = false, beginReply: String = "ok locked", markThrows: Bool = false) {
            self.openThrows = openThrows
            self.beginReply = beginReply
            self.markThrows = markThrows
        }

        func open() async throws {
            openCount += 1
            if openThrows { throw Failure.denied }
        }

        func send(_ line: String) async throws -> String {
            lines.append(line)
            if line.hasPrefix("begin") { return beginReply }
            if line.hasPrefix("mark") {
                if markThrows { throw Failure.denied }
                return "ok marked"
            }
            return "ok"
        }

        func close() async {
            closeCount += 1
        }
    }

    private final class SilentInsertionSession: TextInsertionSession {
        func insert(_ text: String) -> Bool { true }
        func finish() {}
        func cancel() {}
    }

    private final class SilentInsertionBackend: TextInsertionBackend {
        func startInsertionSession() -> any TextInsertionSession { SilentInsertionSession() }
    }

    /// Stand-in for the throttle interval, so a burst is coalesced deterministically
    /// instead of against wall-clock timing.
    private actor Gate {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var credits = 0

        func wait() async {
            if credits > 0 {
                credits -= 1
                return
            }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            if waiters.isEmpty {
                credits += 1
            } else {
                waiters.removeFirst().resume()
            }
        }
    }

    private func makeSession(
        transport: FakeInlinePreviewTransport,
        gate: Gate
    ) -> InlinePreviewSession {
        InlinePreviewSession(
            transport: transport,
            bundleIdentifier: Self.target,
            throttle: .milliseconds(100),
            sleep: { _ in await gate.wait() }
        )
    }

    private func waitForLines(
        _ expected: [String],
        from transport: FakeInlinePreviewTransport,
        timeout: TimeInterval = 3,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        var observed: [String] = []
        while Date() < deadline {
            observed = await transport.lines
            if observed == expected { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(observed, expected, file: file, line: line)
    }

    // MARK: - Throttling

    func testBurstOfPartialsCollapsesToTheNewestTextPerInterval() async {
        let transport = FakeInlinePreviewTransport()
        let gate = Gate()
        let session = makeSession(transport: transport, gate: gate)

        await session.begin()
        await session.mark("one")
        await waitForLines([Self.begin, "mark one"], from: transport)

        // Both arrive inside the throttle window; only the newest may be sent.
        await session.mark("one two")
        await session.mark("one two three")
        await gate.open()

        await waitForLines([Self.begin, "mark one", "mark one two three"], from: transport)
        let report = await session.report()
        XCTAssertEqual(report.marksSent, 2)
        XCTAssertNil(report.failure)
        await gate.open()
    }

    func testRepeatedIdenticalDisplayTextIsNotResent() async {
        let transport = FakeInlinePreviewTransport()
        let gate = Gate()
        let session = makeSession(transport: transport, gate: gate)

        await session.begin()
        await session.mark("same")
        await waitForLines([Self.begin, "mark same"], from: transport)

        // A committed segment plus a cleared partial reproduces the previous
        // display text; re-marking it would churn the composition for nothing.
        await session.mark("same")
        await gate.open()
        await session.discard()

        await waitForLines([Self.begin, "mark same", "cancel", "end"], from: transport)
    }

    // MARK: - Discard ordering

    func testDiscardCancelsAndEndsAfterTheLastMarkAndIgnoresLaterMarks() async {
        let transport = FakeInlinePreviewTransport()
        let gate = Gate()
        let session = makeSession(transport: transport, gate: gate)

        await session.begin()
        await session.mark("hello there")
        await waitForLines([Self.begin, "mark hello there"], from: transport)

        await session.discard()
        // Releasing the throttle afterwards must not resurrect the composition.
        await gate.open()
        await session.mark("too late")

        await waitForLines([Self.begin, "mark hello there", "cancel", "end"], from: transport)
        let report = await session.report()
        XCTAssertTrue(report.began)
        XCTAssertEqual(report.marksSent, 1)
        XCTAssertTrue(report.cancelAcknowledged)
        let closes = await transport.closeCount
        XCTAssertEqual(closes, 1)

        await session.discard()
        await waitForLines([Self.begin, "mark hello there", "cancel", "end"], from: transport)
        let closesAfterSecondDiscard = await transport.closeCount
        XCTAssertEqual(closesAfterSecondDiscard, 1)
    }

    func testMarkWriteFailureStillCancelsBecauseTheCompositionMayBeOnScreen() async {
        let transport = FakeInlinePreviewTransport(markThrows: true)
        let gate = Gate()
        let session = makeSession(transport: transport, gate: gate)

        await session.begin()
        await session.mark("hello")
        await waitForLines([Self.begin, "mark hello"], from: transport)

        await session.discard()

        await waitForLines([Self.begin, "mark hello", "cancel", "end"], from: transport)
        let report = await session.report()
        XCTAssertEqual(report.marksSent, 0)
        XCTAssertEqual(report.failure, "markFailed")
    }

    // MARK: - Silent degradation

    func testProbeAbsentDegradesToHudOnlyWithoutSendingAnything() async {
        let transport = FakeInlinePreviewTransport(openThrows: true)
        let gate = Gate()
        let session = makeSession(transport: transport, gate: gate)

        await session.begin()
        await session.mark("hello")
        await session.discard()

        let sent = await transport.lines
        XCTAssertEqual(sent, [])
        let report = await session.report()
        XCTAssertFalse(report.began)
        XCTAssertEqual(report.failure, "connectFailed")
        XCTAssertFalse(report.cancelAcknowledged)
    }

    func testRefusedFocusLockMarksNothingAndNeedsNoCancel() async {
        let transport = FakeInlinePreviewTransport(beginReply: "err no client session for com.test.app")
        let gate = Gate()
        let session = makeSession(transport: transport, gate: gate)

        await session.begin()
        await session.mark("hello")
        await session.discard()

        let sent = await transport.lines
        XCTAssertEqual(sent, [Self.begin])
        let report = await session.report()
        XCTAssertFalse(report.began)
        XCTAssertEqual(report.marksSent, 0)
        XCTAssertEqual(report.failure, "beginRefused")
    }

    func testNewlinesNeverSplitTheProbeLineProtocol() async {
        let transport = FakeInlinePreviewTransport()
        let gate = Gate()
        let session = makeSession(transport: transport, gate: gate)

        await session.begin()
        await session.mark("first\nsecond")

        await waitForLines([Self.begin, "mark first second"], from: transport)
        await gate.open()
    }

    // MARK: - Launch gate

    func testPreviewIsOffUnlessTheEnvironmentOptsInExactly() {
        XCTAssertFalse(InlinePreviewPolicy.load(from: [:]))
        XCTAssertFalse(InlinePreviewPolicy.load(from: [InlinePreviewPolicy.environmentKey: "0"]))
        XCTAssertTrue(InlinePreviewPolicy.load(from: [InlinePreviewPolicy.environmentKey: "1"]))
    }

    @MainActor
    func testCoordinatorBuildsNoPreviewWhenDisabledOrTargetIsUnidentifiable() {
        let disabled = AppCoordinator(
            textInsertion: SilentInsertionBackend(),
            settings: Settings(),
            inlinePreviewEnabled: false,
            autoStart: false
        )
        XCTAssertNil(disabled.makeInlinePreviewSession(bundleIdentifier: Self.target))

        let enabled = AppCoordinator(
            textInsertion: SilentInsertionBackend(),
            settings: Settings(),
            inlinePreviewEnabled: true,
            autoStart: false
        )
        let unknownTarget: String? = nil
        XCTAssertNil(enabled.makeInlinePreviewSession(bundleIdentifier: unknownTarget))
        XCTAssertNotNil(enabled.makeInlinePreviewSession(bundleIdentifier: Self.target))
    }
}
