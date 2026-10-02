import XCTest
@testable import Epos

/// Two contracts that hold in the SHIPPED app, where the inline-preview spike
/// (`EPOS_INLINE_PREVIEW`) is off: the screen-edge glow renders under its own
/// settings toggle, and the streamed display is the same transform the one final
/// write applies.
@MainActor
final class CoordinatorDisplayAndGlowTests: XCTestCase {
    private static let disfluentRaw = "the the uh build is broken"

    private func makeCoordinator(settings: Settings = Settings()) -> AppCoordinator {
        AppCoordinator(
            textInsertion: NoOpInsertionBackend(),
            settings: settings,
            inlinePreviewEnabled: false,
            autoStart: false
        )
    }

    // MARK: - Edge glow without the preview spike

    func testEdgeGlowLightsInProductionWhereThePreviewSpikeIsOff() {
        let coordinator = makeCoordinator()
        coordinator.state = .recording

        coordinator.presentIndicatorForRecordingStart()

        XCTAssertTrue(coordinator.edgeGlowVisible)
    }

    func testEdgeGlowStaysOffWhenTheSettingIsOff() {
        var settings = Settings()
        settings.edgeGlow.enabled = false
        let coordinator = makeCoordinator(settings: settings)
        coordinator.state = .recording

        coordinator.presentIndicatorForRecordingStart()

        XCTAssertFalse(coordinator.edgeGlowVisible)
    }

    func testGlowTogglesMidRecordingWithoutThePreviewSpike() throws {
        let suiteName = "EposTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = AppCoordinator(
            textInsertion: NoOpInsertionBackend(),
            settings: Settings(),
            settingsDefaults: defaults,
            inlinePreviewEnabled: false,
            autoStart: false
        )
        coordinator.state = .recording
        coordinator.presentIndicatorForRecordingStart()
        XCTAssertTrue(coordinator.edgeGlowVisible)

        var style = coordinator.edgeGlowStyle
        style.enabled = false
        coordinator.setEdgeGlowStyle(style)
        XCTAssertFalse(coordinator.edgeGlowVisible)

        style.enabled = true
        coordinator.setEdgeGlowStyle(style)
        XCTAssertTrue(coordinator.edgeGlowVisible)
    }

    func testEdgeGlowEndsAtReleaseWithoutThePreviewSpike() {
        let coordinator = makeCoordinator()
        coordinator.state = .recording
        coordinator.presentIndicatorForRecordingStart()
        XCTAssertTrue(coordinator.edgeGlowVisible)

        coordinator.finishRecording()

        XCTAssertFalse(coordinator.edgeGlowVisible)
    }

    // MARK: - Streamed display equals the final-write transform

    func testStreamedPartialIsCleanedNotRaw() {
        let coordinator = makeCoordinator()
        let cleaned = "the build is broken"

        coordinator.handlePartialTranscript(Self.disfluentRaw)

        XCTAssertEqual(coordinator.displayText, cleaned)
        XCTAssertEqual(coordinator.hudTranscriptPreview, cleaned)
        // Guard against a silent no-op: the whole point is that the user does not
        // watch the raw recognizer text and then see it rewritten by the write.
        XCTAssertNotEqual(coordinator.displayText, Self.disfluentRaw)
    }

    /// The display accumulates finals plus the in-progress partial and cleans the
    /// whole thing while retaining the raw recognizer segments for evidence.
    func testDisplayCleansAssembledFinalAndPartialText() {
        let coordinator = makeCoordinator()

        coordinator.handleFinalTranscriptSegment("the the uh build ")
        coordinator.handlePartialTranscript("is broken")

        XCTAssertEqual(coordinator.displayText, "the build is broken")
        // The raw accumulation stays raw: correction evidence and the final
        // transform both need the recognizer's own text.
        XCTAssertEqual(coordinator.finalText + coordinator.partial, Self.disfluentRaw)
    }
}

private final class NoOpInsertionBackend: TextInsertionBackend {
    func startInsertionSession() -> any TextInsertionSession {
        NoOpInsertionSession()
    }
}

private final class NoOpInsertionSession: TextInsertionSession {
    func insert(_ text: String) -> Bool { true }
    func finish() {}
    func cancel() {}
}
