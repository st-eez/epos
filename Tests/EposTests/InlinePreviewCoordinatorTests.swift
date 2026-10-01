import XCTest
@testable import Epos

final class InlinePreviewCoordinatorTests: XCTestCase {
    @MainActor
    func testSelectedTextRecordingRejectsPriorPreviewCallbacks() async throws {
        try await rejectsPriorCallbacks(selection: InsertionTargetTextRange(location: 0, length: 4))
    }

    @MainActor
    func testDisabledPreviewRecordingRejectsPriorPreviewCallbacks() async throws {
        try await rejectsPriorCallbacks(enabled: false)
    }

    @MainActor
    func testUnidentifiedTargetRecordingRejectsPriorPreviewCallbacks() async throws {
        try await rejectsPriorCallbacks(bundleIdentifier: nil)
    }

    @MainActor
    private func rejectsPriorCallbacks(
        selection: InsertionTargetTextRange? = nil,
        enabled: Bool = true,
        bundleIdentifier: String? = "com.test.app"
    ) async throws {
        let toggle = PreviewToggle()
        let staleCallback = expectation(description: "prior preview changed the new recording's HUD")
        staleCallback.isInverted = true
        let began = expectation(description: "prior preview began connecting")
        let transport = SuspendedBeginTransport(began: began)
        let coordinator = InlinePreviewCoordinator(
            isEnabled: { toggle.enabled },
            log: EposLogger(category: "coordinator"),
            onMarkingActivityChange: { _ in staleCallback.fulfill() },
            onFirstMarkRendered: { staleCallback.fulfill() }
        )
        let prior = try XCTUnwrap(coordinator.makeSession(
            bundleIdentifier: "com.test.app", transport: transport
        ))
        let connecting = Task { await prior.begin() }
        await fulfillment(of: [began], timeout: 1)

        toggle.enabled = enabled
        coordinator.start(bundleIdentifier: bundleIdentifier, selectedRange: selection)
        XCTAssertFalse(coordinator.isActive)
        await transport.release()
        await connecting.value
        await prior.discard()
        await fulfillment(of: [staleCallback], timeout: 0.1)
    }
}

@MainActor
private final class PreviewToggle {
    var enabled = true
}

private actor SuspendedBeginTransport: InlinePreviewTransport {
    private let began: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?

    init(began: XCTestExpectation) { self.began = began }

    func open() async throws {}

    func send(_ line: String) async throws -> String {
        if line.hasPrefix("begin ") {
            await withCheckedContinuation {
                continuation = $0
                began.fulfill()
            }
        }
        return "ok"
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }

    func close() async {}
}
