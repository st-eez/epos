import XCTest
@testable import SteezFlow

final class SmokeTests: XCTestCase {
    @MainActor
    func testCoordinatorStartsIdle() {
        let coordinator = AppCoordinator()
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(coordinator.partialTranscript, "")
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
