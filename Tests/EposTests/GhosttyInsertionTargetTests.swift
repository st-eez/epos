import XCTest
@testable import Epos

@MainActor
final class GhosttyInsertionTargetTests: XCTestCase {
    private static let transcript = "Final dictation."

    func testTerminalRedrawAfterFirstMarkRefusalAllowsOneGuardedFallback() async {
        let observer = ContextPolicyObserver()
        let backend = RecordingTextInsertionBackend()
        let insertion = makeInsertion(observer: observer, backend: backend)
        XCTAssertNil(insertion.baselineSelectedRange)
        XCTAssertFalse(observer.requiresTextContextValidation())

        let transport = FakeInlinePreviewTransport(markReply: "err preview requires an empty selection")
        let preview = await makePreview(transport: transport)
        observer.value = "terminal screen frame two"
        observer.range = .init(location: 0, length: 0)

        let route = await FinalTranscriptCommitRouter.attemptIMECommit(
            transcript: Self.transcript, preview: preview, insertion: insertion, settle: {}
        )
        XCTAssertNil(route, "a refused first mark makes the IME route ineligible")
        await preview.discard()
        let unsafeTarget = await preview.hasUnsafeTarget()
        XCTAssertFalse(unsafeTarget)
        XCTAssertEqual(insertion.insertFinalResult(Self.transcript), .accepted)
        XCTAssertEqual(insertion.insertFinalResult(Self.transcript), .backendRefused)
        XCTAssertEqual(backend.operations, [.insert(Self.transcript)])
        XCTAssertEqual(observer.valueReads, 0, "terminal output is not editable input context")

        let report = await preview.report()
        XCTAssertTrue(report.began)
        XCTAssertTrue(report.didAttemptMark)
        XCTAssertEqual(report.marksSent, 0)
        XCTAssertEqual(report.failure, "markRefused")
        let lines = await transport.lines
        XCTAssertFalse(lines.contains("cancel"))
        XCTAssertFalse(lines.contains { $0.hasPrefix("commit ") })
        let verification = await insertion.verifyDelivery(expected: Self.transcript, retryDelaysNanoseconds: [0])
        XCTAssertEqual(verification, .unavailable)
    }

    func testTerminalRedrawBeforeConclusiveCommitRefusalAllowsOneFallback() async {
        let observer = ContextPolicyObserver()
        let backend = RecordingTextInsertionBackend()
        let insertion = makeInsertion(observer: observer, backend: backend)
        let transport = FakeInlinePreviewTransport(commitReply: "err locked session gone")
        let preview = await makePreview(transport: transport)
        observer.value = "terminal screen frame two"

        let route = await FinalTranscriptCommitRouter.attemptIMECommit(
            transcript: Self.transcript, preview: preview, insertion: insertion, settle: {}
        )

        XCTAssertEqual(route, .completed(.accepted, viaIME: false))
        XCTAssertEqual(backend.operations, [.insert(Self.transcript)])
        XCTAssertEqual(insertion.insertFinalResult(Self.transcript), .backendRefused)
        let lines = await transport.lines
        XCTAssertEqual(lines.filter { $0.hasPrefix("commit ") }, ["commit \(Self.transcript)"])
        XCTAssertEqual(lines.filter { $0 == "cancel" }, ["cancel"])
        await preview.discard()
    }

    func testNativeAndUnconfirmedSurfacesKeepExactValueCaretAndSelectionValidation() {
        let targets: [(bundle: String?, role: String?, help: String?)] = [
            ("com.mitchellh.ghostty", "AXTextField", "Rename terminal"),
            ("com.mitchellh.ghostty", "AXTextField", "Search terminal"),
            ("com.mitchellh.ghostty", "AXTextField", "Terminal content area"),
            ("com.mitchellh.ghostty", "AXTextArea", "Other text area"),
            ("com.mitchellh.ghostty", "AXTextArea", nil),
            ("com.mitchellh.ghostty", "AXTextArea", " Terminal content area "),
            ("com.other.app", "AXTextArea", "Terminal content area"),
            (nil, "AXTextArea", "Terminal content area"),
            ("com.mitchellh.ghostty", nil, "Terminal content area"),
        ]
        for target in targets {
            for changedRange in [nil, InsertionTargetTextRange(location: 0, length: 0), .init(location: 0, length: 5)] {
                let observer = ContextPolicyObserver(
                    bundleIdentifier: target.bundle, role: target.role, help: target.help,
                    value: "draft", range: .init(location: 5, length: 0)
                )
                let backend = RecordingTextInsertionBackend()
                let insertion = makeInsertion(observer: observer, backend: backend)
                XCTAssertEqual(observer.baselineInsertionContext(), .init(prefix: "draft", suffix: ""))
                XCTAssertTrue(observer.requiresTextContextValidation())
                if let changedRange {
                    observer.range = changedRange
                } else {
                    observer.value = "other"
                }

                XCTAssertEqual(insertion.insertFinalResult(Self.transcript), .targetRefused)
                XCTAssertEqual(backend.operations, [])
                XCTAssertEqual(backend.cancelCount, 1)
            }
        }
    }

    func testContextBuilderPreservesUTF16SelectionAndRejectsInvalidRanges() {
        let observer = ContextPolicyObserver(
            bundleIdentifier: "com.mitchellh.ghostty", role: "AXTextField", help: "Search terminal",
            value: "a😀b", range: .init(location: 1, length: 2)
        )
        observer.captureBaseline()
        XCTAssertEqual(observer.baselineInsertionContext(), .init(prefix: "a", selectedText: "😀", suffix: "b"))
        for range in [
            InsertionTargetTextRange(location: -1, length: 0),
            .init(location: 0, length: -1),
            .init(location: 5, length: 0),
            .init(location: 1, length: 4),
            .init(location: 2, length: 0),
        ] {
            observer.range = range
            observer.captureBaseline()
            XCTAssertNil(observer.baselineInsertionContext())
        }
    }

    func testTerminalContextPolicyKeepsFocusRefusal() {
        let observer = ContextPolicyObserver()
        let backend = RecordingTextInsertionBackend()
        let insertion = makeInsertion(observer: observer, backend: backend)
        observer.focusChanged = true
        observer.value = "terminal screen frame two"

        XCTAssertEqual(insertion.insertFinalResult(Self.transcript), .targetRefused)
        XCTAssertEqual(backend.operations, [])
        XCTAssertEqual(backend.cancelCount, 1)
    }

    func testOpaqueSignatureRefusesAnotherTabOrNativeField() {
        let baseline = InsertionTargetFocusSignature(role: "AXTextArea", subrole: nil, identifier: "surface-one")
        for other in [
            InsertionTargetFocusSignature(role: "AXTextArea", subrole: nil, identifier: "surface-two"),
            InsertionTargetFocusSignature(role: "AXTextField", subrole: nil, identifier: "surface-one"),
            InsertionTargetFocusSignature(role: "AXTextArea", subrole: nil, identifier: nil),
        ] {
            XCTAssertFalse(InsertionTargetFocusSignature.provesSameTarget(from: baseline, to: other))
        }
        XCTAssertTrue(InsertionTargetFocusSignature.provesSameTarget(from: baseline, to: baseline))
    }

    func testTerminalContextPolicyKeepsForeignAndUnknownPreviewRefusals() async {
        for transport in [
            FakeInlinePreviewTransport(markReply: "err unsafe composition"),
            FakeInlinePreviewTransport(markError: .replyTimedOut),
            FakeInlinePreviewTransport(markError: .replyMalformed),
        ] {
            let observer = ContextPolicyObserver()
            let backend = RecordingTextInsertionBackend()
            let insertion = makeInsertion(observer: observer, backend: backend)
            let preview = await makePreview(transport: transport)
            observer.value = "terminal screen frame two"

            let route = await FinalTranscriptCommitRouter.attemptIMECommit(
                transcript: Self.transcript, preview: preview, insertion: insertion, settle: {}
            )
            XCTAssertEqual(route, .completed(.targetRefused, viaIME: false))
            XCTAssertEqual(backend.operations, [])
            XCTAssertEqual(insertion.insertFinalResult(Self.transcript), .backendRefused)
            await preview.discard()
        }
    }

    private func makeInsertion(
        observer: ContextPolicyObserver,
        backend: RecordingTextInsertionBackend
    ) -> FinalTranscriptInsertionSession {
        FinalTranscriptInsertionSession(
            insertionSession: backend.startInsertionSession(), target: observer,
            isAccessibilityTrusted: { true }
        )
    }

    private func makePreview(transport: FakeInlinePreviewTransport) async -> InlinePreviewSession {
        let preview = InlinePreviewSession(
            transport: transport, bundleIdentifier: "com.mitchellh.ghostty", sleep: { _ in }
        )
        await preview.begin()
        await preview.mark("provisional dictation")
        let deadline = ContinuousClock().now.advanced(by: .seconds(3))
        while ContinuousClock().now < deadline {
            let report = await preview.report()
            if report.marksSent > 0 || report.failure != nil { return preview }
            await Task.yield()
        }
        XCTFail("preview mark did not finish")
        return preview
    }
}

/// Feeds the same context builder used by live AX capture, without reading or
/// mutating the developer's focused application.
private final class ContextPolicyObserver: InsertionTargetObserver {
    private let bundleIdentifier: String?
    private let role: String?
    private let help: String?
    private var context: InsertionTargetContext?
    var value: String
    var range: InsertionTargetTextRange
    var focusChanged = false
    private(set) var valueReads = 0

    init(
        bundleIdentifier: String? = "com.mitchellh.ghostty",
        role: String? = "AXTextArea",
        help: String? = "Terminal content area",
        value: String = "terminal screen frame one",
        range: InsertionTargetTextRange = .init(location: 0, length: 0)
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.role = role
        self.help = help
        self.value = value
        self.range = range
    }

    func captureBaseline() {
        context = AXInsertionTargetObserver.context(
            in: value, selectedRange: range, applicationBundleIdentifier: bundleIdentifier,
            role: role, help: help
        )
    }

    func hasCapturedTarget() -> Bool { true }
    func focusChangedSinceStart() -> Bool { focusChanged }
    func observedValue() -> String? {
        valueReads += 1
        return value
    }
    func observedSelectedRange() -> InsertionTargetTextRange? { range }
    func requiresTextContextValidation() -> Bool { context != nil }
    func baselineInsertionContext() -> InsertionTargetContext? { context }
    func targetApplicationBundleIdentifier() -> String? { bundleIdentifier }
    func targetWindowTitle() -> String? { nil }
}
