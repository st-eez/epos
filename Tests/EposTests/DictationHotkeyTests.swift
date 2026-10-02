import CoreGraphics
import XCTest
@testable import Epos

@MainActor
final class DictationHotkeyTests: XCTestCase {
    private final class State {
        var held = false
        var heldKeys: Set<UInt16> = []
        var presses = 0
        var releases = 0
        var enables = 0
    }

    private let state = State()
    private let control = CGEventFlags.maskControl.rawValue
    private let command = CGEventFlags.maskCommand.rawValue
    private let shift = CGEventFlags.maskShift.rawValue
    private let space: UInt16 = 49

    private func makeHotkey(
        shortcut: DictationShortcut = .functionKey,
        reconcileInterval: Duration = .seconds(60)
    ) -> DictationHotkey {
        let hotkey = DictationHotkey(
            shortcut: shortcut,
            hardwareStateReader: { [state] in state.held },
            reconcileInterval: reconcileInterval,
            keyStateReader: { [state] in state.heldKeys.contains($0) },
            installMonitor: { _ in NSNumber(value: 1) },
            removeMonitor: { _ in },
            enableMonitor: { [state] _ in state.enables += 1 }
        )
        hotkey.onPress = { [state] in state.presses += 1 }
        hotkey.onRelease = { [state] in state.releases += 1 }
        return hotkey
    }

    private func waitUntil(
        _ condition: () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "Expected hotkey callback within the wait budget", file: file, line: line)
    }

    private func flags(_ flags: UInt64) -> DictationKeyEvent {
        DictationKeyEvent(kind: .flagsChanged, modifierFlags: flags)
    }

    private func key(
        _ kind: DictationKeyEvent.Kind,
        code: UInt16 = 49,
        modifiers: UInt64 = CGEventFlags.maskControl.rawValue,
        repeat isRepeat: Bool = false
    ) -> DictationKeyEvent {
        DictationKeyEvent(kind: kind, modifierFlags: modifiers, keyCode: code, isRepeat: isRepeat)
    }

    func testFunctionKeyPressAndReleaseAreDeduplicatedAndDeliveredAfterTheTapReturns() async {
        let hotkey = makeHotkey()
        state.held = true
        XCTAssertFalse(hotkey.handleEvent(flags(DictationShortcut.functionFlag)))
        hotkey.handleEvent(flags(DictationShortcut.functionFlag))
        XCTAssertEqual(state.presses, 0, "Coordinator work must not run in the tap callback")
        await waitUntil { self.state.presses == 1 }
        state.held = false
        hotkey.handleEvent(flags(0))
        hotkey.handleEvent(flags(0))
        await waitUntil { self.state.releases == 1 }
        XCTAssertEqual(state.presses, 1)
        XCTAssertEqual(state.releases, 1)
    }

    func testModifierOnlyShortcutRequiresTheConfiguredSetAndEndsOnRequiredModifierRelease() async throws {
        let shortcut = try XCTUnwrap(DictationShortcut(modifierFlags: control | command))
        let hotkey = makeHotkey(shortcut: shortcut)
        state.held = true
        hotkey.handleEvent(flags(control))
        await Task.yield()
        XCTAssertEqual(state.presses, 0)
        hotkey.handleEvent(flags(control | command))
        await waitUntil { self.state.presses == 1 }
        hotkey.handleEvent(flags(control | command | shift))
        XCTAssertEqual(state.releases, 0)
        state.held = false
        hotkey.handleEvent(flags(command | shift))
        await waitUntil { self.state.releases == 1 }
    }

    func testCombinationConsumesDownRepeatsAndUpWhileLeavingUnrelatedKeysAlone() async throws {
        let hotkey = makeHotkey(shortcut: try XCTUnwrap(DictationShortcut(modifierFlags: control, keyCode: space)))
        state.held = true
        state.heldKeys = [space]
        hotkey.handleEvent(flags(control))
        XCTAssertFalse(hotkey.handleEvent(key(.keyDown, code: 0)))
        XCTAssertTrue(hotkey.handleEvent(key(.keyDown)))
        XCTAssertTrue(hotkey.handleEvent(key(.keyDown, repeat: true)))
        await waitUntil { self.state.presses == 1 }
        state.held = false
        state.heldKeys = []
        XCTAssertTrue(hotkey.handleEvent(key(.keyUp)))
        await waitUntil { self.state.releases == 1 }
        XCTAssertFalse(hotkey.handleEvent(key(.keyUp)))
        XCTAssertEqual(state.presses, 1)
        XCTAssertEqual(state.releases, 1)
    }

    func testModifierFirstReleaseStillConsumesTheHeldKeyAndItsRepeat() async throws {
        let hotkey = makeHotkey(shortcut: try XCTUnwrap(DictationShortcut(modifierFlags: control, keyCode: space)))
        state.held = true
        state.heldKeys = [space]
        hotkey.handleEvent(flags(control))
        hotkey.handleEvent(key(.keyDown))
        await waitUntil { self.state.presses == 1 }
        state.held = false
        hotkey.handleEvent(flags(0))
        await waitUntil { self.state.releases == 1 }
        XCTAssertTrue(hotkey.handleEvent(key(.keyDown, modifiers: 0, repeat: true)))
        state.heldKeys = []
        XCTAssertTrue(hotkey.handleEvent(key(.keyUp, modifiers: 0)))
        await Task.yield()
        XCTAssertEqual(state.releases, 1)
    }

    func testRepeatsAndExtraModifiersCannotStartACombination() async throws {
        let hotkey = makeHotkey(shortcut: try XCTUnwrap(DictationShortcut(modifierFlags: control, keyCode: space)))
        hotkey.handleEvent(flags(control | command))
        XCTAssertFalse(hotkey.handleEvent(key(.keyDown, modifiers: control | command)))
        XCTAssertFalse(hotkey.handleEvent(key(.keyDown, repeat: true)))
        await Task.yield()
        XCTAssertEqual(state.presses, 0)
    }

    func testNavigationKeysDoNotImplyAPhysicalFunctionModifier() async throws {
        let hotkey = makeHotkey(shortcut: try XCTUnwrap(DictationShortcut(modifierFlags: control, keyCode: 123)))
        state.held = true
        state.heldKeys = [123]
        hotkey.handleEvent(flags(control))
        XCTAssertTrue(hotkey.handleEvent(key(.keyDown, code: 123, modifiers: control | DictationShortcut.functionFlag)))
        await waitUntil { self.state.presses == 1 }
        hotkey.stop()
    }

    func testClearedUnicodeEventFlagsCannotActivateAFunctionAndAKeyShortcut() async throws {
        let hotkey = makeHotkey(shortcut: try XCTUnwrap(DictationShortcut(
            modifierFlags: DictationShortcut.functionFlag, keyCode: 0
        )))
        hotkey.handleEvent(flags(DictationShortcut.functionFlag))
        // KeystrokeTextInjector uses physical keycode zero and clears its flags.
        XCTAssertFalse(hotkey.handleEvent(key(.keyDown, code: 0, modifiers: 0)))
        await Task.yield()
        XCTAssertEqual(state.presses, 0)
        state.held = true
        state.heldKeys = [0]
        XCTAssertTrue(hotkey.handleEvent(key(.keyDown, code: 0, modifiers: DictationShortcut.functionFlag)))
        await waitUntil { self.state.presses == 1 }
        hotkey.stop()
    }

    func testOwnUnicodeDeliveryPassesWhileTheSamePhysicalKeyIsConsumed() async throws {
        let hotkey = makeHotkey(shortcut: try XCTUnwrap(DictationShortcut(modifierFlags: control, keyCode: 0)))
        state.held = true
        state.heldKeys = [0]
        hotkey.handleEvent(flags(control))
        XCTAssertTrue(hotkey.handleEvent(key(.keyDown, code: 0)))
        await waitUntil { self.state.presses == 1 }
        let processID = Int64(ProcessInfo.processInfo.processIdentifier)
        XCTAssertFalse(hotkey.handleEvent(DictationKeyEvent(
            kind: .keyDown, keyCode: 0, sourceProcessID: processID
        )))
        XCTAssertFalse(hotkey.handleEvent(DictationKeyEvent(
            kind: .keyUp, keyCode: 0, sourceProcessID: processID
        )))
        await Task.yield()
        XCTAssertEqual(state.releases, 0)
        XCTAssertTrue(hotkey.handleEvent(key(.keyDown, code: 0, repeat: true)))
        hotkey.stop()
    }

    func testClearedKeyEventFlagsDoNotEndAModifierOnlyHold() async {
        let hotkey = makeHotkey()
        state.held = true
        hotkey.handleFlagsChanged(pressed: true)
        await waitUntil { self.state.presses == 1 }
        XCTAssertFalse(hotkey.handleEvent(key(.keyDown, code: 0, modifiers: 0)))
        XCTAssertFalse(hotkey.handleEvent(key(.keyUp, code: 0, modifiers: 0)))
        await Task.yield()
        XCTAssertEqual(state.releases, 0)
        state.held = false
        hotkey.handleFlagsChanged(pressed: false)
        await waitUntil { self.state.releases == 1 }
    }

    func testHardwareBackstopEndsALostReleaseAndAllowsTheNextPress() async {
        let hotkey = makeHotkey(reconcileInterval: .milliseconds(5))
        state.held = true
        hotkey.handleFlagsChanged(pressed: true)
        await waitUntil { self.state.presses == 1 }
        state.held = false
        await waitUntil { self.state.releases == 1 }
        hotkey.handleFlagsChanged(pressed: false)
        state.held = true
        hotkey.handleFlagsChanged(pressed: true)
        await waitUntil { self.state.presses == 2 }
        XCTAssertEqual(state.releases, 1)
        hotkey.stop()
    }

    func testAHeldShortcutSurvivesReconcileTicks() async {
        let hotkey = makeHotkey(reconcileInterval: .milliseconds(5))
        state.held = true
        hotkey.handleFlagsChanged(pressed: true)
        await waitUntil { self.state.presses == 1 }
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(state.releases, 0)
        hotkey.stop()
    }

    func testLostKeyUpCannotKeepTheConsumptionLatchForTheNextPress() async throws {
        let hotkey = makeHotkey(shortcut: try XCTUnwrap(DictationShortcut(modifierFlags: control, keyCode: space)))
        state.held = true
        state.heldKeys = [space]
        hotkey.handleEvent(flags(control))
        hotkey.handleEvent(key(.keyDown))
        await waitUntil { self.state.presses == 1 }
        state.held = false
        hotkey.handleEvent(flags(0))
        await waitUntil { self.state.releases == 1 }
        state.heldKeys = []
        hotkey.reconcileHardwareState()
        XCTAssertFalse(hotkey.handleEvent(key(.keyDown, modifiers: 0)))
        state.held = true
        state.heldKeys = [space]
        hotkey.handleEvent(flags(control))
        XCTAssertTrue(hotkey.handleEvent(key(.keyDown)))
        await waitUntil { self.state.presses == 2 }
        hotkey.stop()
    }

    func testFreshOrdinaryPressPassesImmediatelyAfterALostKeyUpWithoutReconciliation() async throws {
        let hotkey = makeHotkey(shortcut: try XCTUnwrap(DictationShortcut(modifierFlags: control, keyCode: space)))
        state.held = true
        state.heldKeys = [space]
        hotkey.handleEvent(flags(control))
        XCTAssertTrue(hotkey.handleEvent(key(.keyDown)))
        await waitUntil { self.state.presses == 1 }
        state.held = false
        hotkey.handleEvent(flags(0))
        // The old keyUp disappeared. Hardware is already down for a NEW press,
        // so waiting for the hardware poll would retain the stale latch.
        XCTAssertFalse(hotkey.handleEvent(key(.keyDown, modifiers: 0)))
        await waitUntil { self.state.releases == 1 }
        XCTAssertFalse(hotkey.handleEvent(key(.keyUp, modifiers: 0)))
        XCTAssertEqual(state.presses, 1)
        hotkey.stop()
    }

    func testDisabledTapIsReenabledAndReconcilesALostRelease() async {
        let hotkey = makeHotkey()
        hotkey.start()
        state.held = true
        hotkey.handleFlagsChanged(pressed: true)
        await waitUntil { self.state.presses == 1 }
        state.held = false
        XCTAssertFalse(hotkey.handleEvent(DictationKeyEvent(kind: .tapDisabled)))
        await waitUntil { self.state.releases == 1 }
        XCTAssertEqual(state.enables, 1)
        hotkey.stop()
    }

    func testRecordingSuspendsDictationAndDiscardsAnUndeliveredPress() async {
        let hotkey = makeHotkey()
        state.held = true
        hotkey.handleFlagsChanged(pressed: true)
        hotkey.setRecordingShortcut(true)
        XCTAssertFalse(hotkey.isShortcutHeld)
        hotkey.handleFlagsChanged(pressed: false)
        hotkey.handleFlagsChanged(pressed: true)
        await Task.yield()
        XCTAssertEqual(state.presses, 0)
        XCTAssertEqual(state.releases, 0)
        state.held = false
        hotkey.handleFlagsChanged(pressed: false)
        hotkey.setRecordingShortcut(false)
        state.held = true
        hotkey.handleFlagsChanged(pressed: true)
        await waitUntil { self.state.presses == 1 }
        hotkey.stop()
    }

    func testRecordingPassesTheNewCombinationToTheRecorder() throws {
        let hotkey = makeHotkey(shortcut: try XCTUnwrap(DictationShortcut(modifierFlags: control, keyCode: space)))
        hotkey.setRecordingShortcut(true)
        XCTAssertFalse(hotkey.handleEvent(flags(control)))
        XCTAssertFalse(hotkey.handleEvent(key(.keyDown)))
        XCTAssertFalse(hotkey.handleEvent(key(.keyUp)))
    }

    func testAChangedShortcutUsesTheNewBinding() async throws {
        let hotkey = makeHotkey()
        hotkey.setShortcut(try XCTUnwrap(DictationShortcut(modifierFlags: control)))
        hotkey.handleFlagsChanged(pressed: true)
        await Task.yield()
        XCTAssertEqual(state.presses, 0)
        state.held = true
        hotkey.handleEvent(flags(control))
        await waitUntil { self.state.presses == 1 }
        hotkey.stop()
    }
}
