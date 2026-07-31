import XCTest
@testable import Epos

/// macOS stops delivering `flagsChanged` to global monitors while secure input is
/// active (password fields, the lock screen, `sudo`). A release pressed inside that
/// window never arrives, and pure edge tracking then believes fn is held forever:
/// the mic stays hot and the next real press is swallowed by the edge guard. These
/// pin the hardware-state backstop that ends such a hold.
@MainActor
final class FnHotkeyStuckKeyTests: XCTestCase {
    private final class KeyState {
        var isDown = false
    }

    private final class Counter {
        var presses = 0
        var releases = 0
    }

    private let key = KeyState()
    private let counter = Counter()

    private func makeHotkey() -> FnHotkey {
        let hotkey = FnHotkey(
            hardwareStateReader: { [key] in key.isDown },
            reconcileInterval: .milliseconds(5)
        )
        hotkey.onPress = { [counter] in counter.presses += 1 }
        hotkey.onRelease = { [counter] in counter.releases += 1 }
        return hotkey
    }

    /// Poll until `condition` holds or the budget runs out, so the test never
    /// depends on how many reconcile ticks happen to fit in a fixed sleep.
    private func waitUntil(
        _ condition: () -> Bool,
        timeout: Duration = .seconds(2)
    ) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func testHardwareStateEndsAHoldWhoseReleaseEventNeverArrived() async {
        let hotkey = makeHotkey()
        key.isDown = true
        hotkey.handleFlagsChanged(pressed: true)
        XCTAssertEqual(counter.presses, 1)
        XCTAssertEqual(counter.releases, 0)

        // Secure input swallowed the release: the only evidence is the hardware read.
        key.isDown = false
        await waitUntil { [counter] in counter.releases == 1 }

        XCTAssertEqual(counter.releases, 1)
    }

    /// The reconciled release and a real release that shows up afterwards must not
    /// both finalize the recording.
    func testALateRealReleaseAfterReconciliationDoesNotReleaseTwice() async {
        let hotkey = makeHotkey()
        key.isDown = true
        hotkey.handleFlagsChanged(pressed: true)
        key.isDown = false
        await waitUntil { [counter] in counter.releases == 1 }

        hotkey.handleFlagsChanged(pressed: false)

        XCTAssertEqual(counter.releases, 1)
    }

    /// The point of ending the stuck hold: the next press is a fresh edge again
    /// instead of being swallowed as a repeat of the one that never ended.
    func testPressAfterAReconciledReleaseStartsANewHold() async {
        let hotkey = makeHotkey()
        key.isDown = true
        hotkey.handleFlagsChanged(pressed: true)
        key.isDown = false
        await waitUntil { [counter] in counter.releases == 1 }

        key.isDown = true
        hotkey.handleFlagsChanged(pressed: true)

        XCTAssertEqual(counter.presses, 2)
    }

    /// A held key must survive many reconcile ticks: this is a backstop, not a
    /// second source of releases.
    func testAHeldKeyIsNeverReleasedByReconciliation() async {
        let hotkey = makeHotkey()
        key.isDown = true
        hotkey.handleFlagsChanged(pressed: true)

        try? await Task.sleep(for: .milliseconds(60))

        XCTAssertEqual(counter.releases, 0)
        hotkey.handleFlagsChanged(pressed: false)
        XCTAssertEqual(counter.releases, 1)
    }

    /// Nothing keeps polling once the hold is over.
    func testReconciliationStopsAfterARealRelease() async {
        let hotkey = makeHotkey()
        key.isDown = true
        hotkey.handleFlagsChanged(pressed: true)
        key.isDown = false
        hotkey.handleFlagsChanged(pressed: false)

        try? await Task.sleep(for: .milliseconds(60))

        XCTAssertEqual(counter.releases, 1)
    }
}
