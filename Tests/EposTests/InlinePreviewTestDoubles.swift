import Foundation
@testable import Epos

actor FakeInlinePreviewTransport: InlinePreviewTransport {
    enum Failure: Error { case denied }

    private let openThrows: Bool
    private let beginReply: String
    private let beginError: InlinePreviewTransportError?
    private let markThrows: Bool
    private let markReply: String
    private let markError: InlinePreviewTransportError?
    private let markReplyAfterFirst: String?
    private let cancelReply: String
    private let cancelError: InlinePreviewTransportError?
    /// Marks beyond this count throw, for degradation mid- or post-recording.
    private let failMarksAfter: Int?
    private let commitReply: String
    private let commitError: InlinePreviewTransportError?

    private(set) var lines: [String] = []
    private(set) var openCount = 0
    private(set) var closeCount = 0
    private(set) var replyTimeouts: [TimeInterval] = []
    private var marksSeen = 0

    init(
        openThrows: Bool = false,
        beginReply: String = "ok locked",
        beginError: InlinePreviewTransportError? = nil,
        markThrows: Bool = false,
        markReply: String = "ok marked",
        markError: InlinePreviewTransportError? = nil,
        markReplyAfterFirst: String? = nil,
        cancelReply: String = "ok",
        cancelError: InlinePreviewTransportError? = nil,
        failMarksAfter: Int? = nil,
        commitReply: String = "ok committed 1",
        commitError: InlinePreviewTransportError? = nil
    ) {
        self.openThrows = openThrows
        self.beginReply = beginReply
        self.beginError = beginError
        self.markThrows = markThrows
        self.markReply = markReply
        self.markError = markError
        self.markReplyAfterFirst = markReplyAfterFirst
        self.cancelReply = cancelReply
        self.cancelError = cancelError
        self.failMarksAfter = failMarksAfter
        self.commitReply = commitReply
        self.commitError = commitError
    }

    func open() async throws {
        openCount += 1
        if openThrows { throw Failure.denied }
    }

    func send(_ line: String) async throws -> String {
        lines.append(line)
        if line.hasPrefix("begin") {
            if let beginError { throw beginError }
            return beginReply
        }
        if line == "cancel" {
            if let cancelError { throw cancelError }
            return cancelReply
        }
        if line.hasPrefix("mark") {
            marksSeen += 1
            if let markError { throw markError }
            if markThrows { throw Failure.denied }
            if let failMarksAfter, marksSeen > failMarksAfter { throw Failure.denied }
            if marksSeen > 1, let markReplyAfterFirst { return markReplyAfterFirst }
            return markReply
        }
        if line.hasPrefix("commit") {
            if let commitError { throw commitError }
            return commitReply
        }
        return "ok"
    }

    func send(_ line: String, replyTimeout: TimeInterval) async throws -> String {
        replyTimeouts.append(replyTimeout)
        return try await send(line)
    }

    func close() async {
        closeCount += 1
    }
}

/// Records keystroke writes, so "zero keystrokes on the IME path" is provable.
final class RecordingInsertionBackend: TextInsertionBackend {
    private(set) var inserted: [String] = []

    func startInsertionSession() -> any TextInsertionSession { Session(backend: self) }

    private final class Session: TextInsertionSession {
        private let backend: RecordingInsertionBackend

        init(backend: RecordingInsertionBackend) { self.backend = backend }

        func insert(_ text: String) -> Bool {
            backend.inserted.append(text)
            return true
        }

        func finish() {}
        func cancel() {}
    }
}

/// Opaque but stable fn-press target: the guard's focus/frame checks pass and
/// the value guard is inert, as on Electron targets.
final class StableOpaqueObserver: InsertionTargetObserver {
    func captureBaseline() {}
    func hasCapturedTarget() -> Bool { true }
    func focusChangedSinceStart() -> Bool { false }
    func observedValue() -> String? { nil }
    func observedSelectedRange() -> InsertionTargetTextRange? { nil }
    func requiresTextContextValidation() -> Bool { false }
    func baselineInsertionContext() -> InsertionTargetContext? { nil }
    func targetApplicationBundleIdentifier() -> String? { "com.test.app" }
    func targetWindowTitle() -> String? { nil }
}

