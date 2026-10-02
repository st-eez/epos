import CoreGraphics
import XCTest
@testable import Epos

final class ShortcutRecordingTests: XCTestCase {
    private let control = CGEventFlags.maskControl.rawValue
    private let command = CGEventFlags.maskCommand.rawValue

    private func flags(_ flags: UInt64) -> DictationKeyEvent {
        DictationKeyEvent(kind: .flagsChanged, modifierFlags: flags)
    }

    private func key(
        _ kind: DictationKeyEvent.Kind, code: UInt16 = 49,
        modifiers: UInt64 = CGEventFlags.maskControl.rawValue, repeat isRepeat: Bool = false
    ) -> DictationKeyEvent {
        DictationKeyEvent(kind: kind, modifierFlags: modifiers, keyCode: code, isRepeat: isRepeat)
    }

    func testModifierOnlyCaptureKeepsTheFullCombinationThroughRelease() throws {
        var recorder = ShortcutRecording()
        XCTAssertNil(recorder.handle(flags(control)))
        XCTAssertNil(recorder.handle(flags(control | command)))
        XCTAssertNil(recorder.handle(flags(control)))
        let shortcut = try XCTUnwrap(DictationShortcut(modifierFlags: control | command))
        XCTAssertEqual(recorder.handle(flags(0)), .shortcut(shortcut))
    }

    func testCombinationCommitsOnlyAfterKeyAndModifiersReleaseInEitherOrder() throws {
        let shortcut = try XCTUnwrap(DictationShortcut(modifierFlags: control, keyCode: 49))
        for modifierFirst in [true, false] {
            var recorder = ShortcutRecording()
            XCTAssertNil(recorder.handle(flags(control)))
            XCTAssertNil(recorder.handle(key(.keyDown)))
            XCTAssertNil(recorder.handle(key(.keyDown, repeat: true)))
            if modifierFirst {
                XCTAssertNil(recorder.handle(flags(0)))
                XCTAssertEqual(recorder.handle(key(.keyUp, modifiers: 0)), .shortcut(shortcut))
            } else {
                XCTAssertNil(recorder.handle(key(.keyUp)))
                XCTAssertEqual(recorder.handle(flags(0)), .shortcut(shortcut))
            }
        }
    }

    func testPlainKeyShowsAnErrorAndAllowsAnotherAttempt() throws {
        var recorder = ShortcutRecording()
        XCTAssertNil(recorder.handle(key(.keyDown, modifiers: 0)))
        XCTAssertTrue(recorder.message.contains("Include"))
        XCTAssertNil(recorder.handle(key(.keyUp, modifiers: 0)))
        XCTAssertNil(recorder.handle(flags(control)))
        XCTAssertEqual(recorder.handle(flags(0)), .shortcut(try XCTUnwrap(DictationShortcut(modifierFlags: control))))
    }

    func testMultipleKeysAreRejectedUntilTheChordFullyReleases() {
        var recorder = ShortcutRecording()
        XCTAssertNil(recorder.handle(flags(control)))
        XCTAssertNil(recorder.handle(key(.keyDown)))
        XCTAssertNil(recorder.handle(key(.keyDown, code: 0)))
        XCTAssertTrue(recorder.message.contains("one key"))
        XCTAssertNil(recorder.handle(key(.keyUp)))
        XCTAssertNil(recorder.handle(key(.keyUp, code: 0)))
        XCTAssertNil(recorder.handle(flags(0)))
    }

    func testAlreadyHeldModifiersAreReleasedBeforeCaptureBegins() throws {
        var recorder = ShortcutRecording(initialModifierFlags: control)
        XCTAssertNil(recorder.handle(flags(control | command)))
        XCTAssertNil(recorder.handle(flags(0)))
        XCTAssertNil(recorder.handle(flags(DictationShortcut.functionFlag)))
        XCTAssertEqual(recorder.handle(flags(0)), .shortcut(.functionKey))
    }

    func testEscapeCancelsAndResetWaitsForRelease() {
        var recorder = ShortcutRecording()
        XCTAssertEqual(recorder.handle(key(.keyDown, code: 53, modifiers: 0)), .cancelled)
        recorder = ShortcutRecording()
        XCTAssertNil(recorder.handle(flags(control)))
        XCTAssertNil(recorder.resetToFunctionKey())
        XCTAssertEqual(recorder.handle(flags(0)), .shortcut(.functionKey))
        recorder = ShortcutRecording()
        XCTAssertEqual(recorder.resetToFunctionKey(), .shortcut(.functionKey))
    }

    func testFunctionFlagOnAnArrowDoesNotEnterTheRecordedModifiers() throws {
        var recorder = ShortcutRecording()
        XCTAssertNil(recorder.handle(flags(control)))
        XCTAssertNil(recorder.handle(key(.keyDown, code: 123, modifiers: control | DictationShortcut.functionFlag)))
        XCTAssertNil(recorder.handle(key(.keyUp, code: 123)))
        XCTAssertEqual(
            recorder.handle(flags(0)),
            .shortcut(try XCTUnwrap(DictationShortcut(modifierFlags: control, keyCode: 123)))
        )
    }
}
