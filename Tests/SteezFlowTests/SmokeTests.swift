import XCTest
@testable import SteezFlow

final class SmokeTests: XCTestCase {
    @MainActor
    func testCoordinatorStartsIdle() {
        // autoStart: false so the global NSEvent monitor isn't installed during tests.
        let coordinator = AppCoordinator(autoStart: false)
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(coordinator.finalText, "")
        XCTAssertEqual(coordinator.partial, "")
        XCTAssertEqual(coordinator.displayText, "")
    }

    func testPermissionsSnapshotReturns() {
        let snapshot = PermissionsGate().snapshot()
        _ = snapshot.microphone
        _ = snapshot.speech
        _ = snapshot.accessibility
    }

    func testTranscriberInstantiates() {
        let transcriber = Transcriber(locale: Locale(identifier: "en-US"))
        XCTAssertEqual(transcriber.locale.identifier, "en-US")
    }

    func testInjectorPasteEmptyStringNoop() {
        TextInjector().paste("")
    }
}
