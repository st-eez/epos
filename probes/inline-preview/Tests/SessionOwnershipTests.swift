import AppKit
import ApplicationServices
import Foundation

@main
enum SessionOwnershipTests {
    @MainActor
    private final class Fixture {
        let view = NSTextView(frame: .zero)
        let policy: ProbeSessionOwnership
        var text: String?
        var operations = [String]()

        init() {
            view.string = "prefix suffix"
            view.setSelectedRange(NSRange(location: 7, length: 0))
            policy = ProbeSessionOwnership(controlledEmptyFixture: true, observation: .init(
                selection: view.selectedRange(), marked: unavailable, composition: .unreadable
            ))!
        }

        var observation: ProbeSessionOwnership.Observation {
            let mark = view.markedRange()
            // The actual native view retains its draft. Hide only the text as the
            // Ghostty IMK wrapper did, while using its actual mark and selection.
            return .init(selection: view.selectedRange(), marked: mark,
                         composition: mark.length == 0 ? .absent : .unreadable)
        }

        func mark(_ value: String) -> Bool {
            guard policy.canOperate(observation) else { return false }
            operations.append("mark")
            view.setMarkedText(value, selectedRange: NSRange(location: (value as NSString).length, length: 0),
                               replacementRange: unavailable)
            text = value
            return policy.didMark(observation, utf16Length: (value as NSString).length)
        }

        func discard() {
            operations.append("discard")
            view.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: unavailable)
            view.unmarkText()
            text = nil
        }

        func cancel() -> Bool {
            guard policy.canOperate(observation), policy.isDraft else { return false }
            discard()
            return policy.didDiscard(observation)
        }

        func final() -> Bool {
            guard policy.canOperate(observation), policy.finish() else { return false }
            operations.append("final")
            view.insertText("English final ", replacementRange: unavailable)
            return true
        }

        func beforeInput(_ reason: String, action: () -> Void) {
            let mayDiscard = policy.isDraft && policy.canOperate(observation)
            policy.interrupt(reason) {
                precondition(policy.isRetired && !policy.permitsFinal, "cleanup ran before retirement")
                if mayDiscard { discard() }
            }
            operations.append("forward")
            action()
        }
    }

    private static let unavailable = NSRange(location: NSNotFound, length: NSNotFound)

    @MainActor
    static func main() {
        productionInputBarrier()
        deferredShortcutPreservesFinal()
        productionAcquisition()
        uninterruptedLifecycle()
        for (name, key, code) in [("typing", "x", UInt16(7)), ("backspace", "\u{7f}", UInt16(51)),
                                 ("caret", String(UnicodeScalar(NSLeftArrowFunctionKey)!), UInt16(123))] {
            interruptedKey(name, key: key, code: code)
        }
        for reason in ["mouse", "focus", "host-commit", "deactivate", "disconnect"] {
            interruptedLifecycle(reason)
        }
        refusesChangedHostState()
        refusesUncontrolledStart()
        fnFlagsOnly()
        barrierFailure()
        preservesForeignSameLengthText()
        reentrantMarkCannotRevive()
        reentrantDiscardCannotRevive()
        finishedInsertionCannotRepeat()
        print("session ownership prototype: 20 native lifecycle checks passed")
    }

    private static func productionInputBarrier() {
        var flags: CGEventFlags = [.maskSecondaryFn]
        var heldKey: UInt16?
        precondition(ProbeInputBarrier.ignoresInput(.flagsChanged, flags: [], previousFlags: &flags, heldKey: &heldKey),
                     "fn release interrupted finalization")
        flags = [.maskControl, .maskShift]
        precondition(ProbeInputBarrier.ignoresInput(.flagsChanged, flags: [], previousFlags: &flags, heldKey: &heldKey),
                     "custom modifier hold release interrupted finalization")
        precondition(ProbeInputBarrier.ignoresInput(.keyUp, flags: [], previousFlags: &flags, heldKey: &heldKey),
                     "custom key hold release interrupted finalization")
        heldKey = 7
        precondition(ProbeInputBarrier.ignoresInput(.keyDown, flags: [.maskControl], previousFlags: &flags,
                                                   heldKey: &heldKey, keyCode: 7, isRepeat: true),
                     "configured hold repeat retired the draft")
        precondition(!ProbeInputBarrier.ignoresInput(.keyDown, flags: [.maskControl], previousFlags: &flags,
                                                    heldKey: &heldKey, keyCode: 8, isRepeat: true),
                     "another key's repeat bypassed retirement")
        precondition(!ProbeInputBarrier.ignoresInput(.keyDown, flags: [.maskControl], previousFlags: &flags,
                                                    heldKey: &heldKey, keyCode: 7, isRepeat: false),
                     "fresh hold-key press bypassed retirement")
        precondition(ProbeInputBarrier.ignoresInput(.keyUp, flags: [], previousFlags: &flags,
                                                   heldKey: &heldKey, keyCode: 7) && heldKey == nil)
        precondition(!ProbeInputBarrier.ignoresInput(.keyDown, flags: [], previousFlags: &flags,
                                                    heldKey: &heldKey, keyCode: 7, isRepeat: true),
                     "released hold key retained its repeat exemption")
        precondition(ProbeInputBarrier.holdKey(from: "hold-key=0") == 0)
        precondition(ProbeInputBarrier.holdKey(from: "hold-key=127") == 127)
        for token in ["hold-key=128", "hold-key=-1", "hold-key=65535", "hold-key=", "key=7"] {
            precondition(ProbeInputBarrier.holdKey(from: token) == nil, "invalid hold key accepted")
        }
        let commandA = ProbeInputBarrier.holdShortcut(keyToken: "hold-key=0",
                                                     flagsToken: "hold-flags=\(CGEventFlags.maskCommand.rawValue)")!
        flags = [.maskCommand]
        precondition(ProbeInputBarrier.ignoresInput(.keyDown, flags: [.maskCommand], previousFlags: &flags,
                                                   heldKey: &heldKey, shortcut: commandA, keyCode: 0),
                     "fresh matched shortcut retired the finalizing pass before the main tap")
        precondition(heldKey == 0)
        precondition(!ProbeInputBarrier.ignoresInput(.keyDown, flags: [], previousFlags: &flags,
                                                    heldKey: &heldKey, shortcut: commandA, keyCode: 0),
                     "Unicode delivery inherited the physical Command modifier")
        precondition(!ProbeInputBarrier.ignoresInput(.keyDown, flags: [.maskCommand, .maskShift], previousFlags: &flags,
                                                    heldKey: &heldKey, shortcut: commandA, keyCode: 0),
                     "a different shortcut bypassed retirement")
        precondition(ProbeInputBarrier.ignoresInput(.keyDown, flags: [], previousFlags: &flags,
                                                   heldKey: &heldKey, shortcut: commandA, keyCode: 0, isRepeat: true),
                     "held shortcut repeat leaked when its modifiers were released")
        precondition(!ProbeInputBarrier.ignoresInput(.keyDown, flags: [.maskCommand], previousFlags: &flags,
                                                    heldKey: &heldKey, shortcut: commandA, keyCode: 7, isRepeat: true))
        precondition(ProbeInputBarrier.ignoresInput(.keyUp, flags: [], previousFlags: &flags,
                                                   heldKey: &heldKey, shortcut: commandA, keyCode: 0) && heldKey == nil)
        precondition(!ProbeInputBarrier.ignoresInput(.keyDown, flags: [.maskCommand], previousFlags: &flags,
                                                    heldKey: &heldKey, shortcut: commandA, keyCode: 0, isRepeat: true),
                     "repeat reacquired the shortcut after keyUp")
        let fnLeft = DictationShortcut(modifierFlags: CGEventFlags.maskSecondaryFn.rawValue, keyCode: 123)!
        flags = []
        precondition(!ProbeInputBarrier.ignoresInput(.keyDown, flags: [.maskSecondaryFn], previousFlags: &flags,
                                                    heldKey: &heldKey, shortcut: fnLeft, keyCode: 123),
                     "implicit navigation fn matched a physical fn shortcut")
        flags = [.maskSecondaryFn]
        precondition(ProbeInputBarrier.ignoresInput(.keyDown, flags: [.maskSecondaryFn], previousFlags: &flags,
                                                   heldKey: &heldKey, shortcut: fnLeft, keyCode: 123))
        for token in ["hold-flags=0", "hold-flags=\(CGEventFlags.maskAlphaShift.rawValue)",
                      "hold-flags=18446744073709551616", "hold-flags=-1", "hold-flags=", "flags=1048576"] {
            precondition(ProbeInputBarrier.holdShortcut(keyToken: "hold-key=0", flagsToken: token) == nil,
                         "invalid shortcut modifiers accepted")
        }
        precondition(ProbeInputBarrier.holdShortcut(keyToken: "hold-key=63",
                                                   flagsToken: "hold-flags=\(CGEventFlags.maskCommand.rawValue)") == nil)
        for type: CGEventType in [.keyDown, .leftMouseDown, .leftMouseDragged, .scrollWheel] {
            precondition(!ProbeInputBarrier.ignoresInput(type, flags: [], previousFlags: &flags, heldKey: &heldKey),
                         "ordinary input bypassed synchronous retirement")
        }
    }

    @MainActor
    private static func deferredShortcutPreservesFinal() {
        let fixture = Fixture()
        precondition(fixture.mark("English draft") && fixture.cancel())
        var flags: CGEventFlags = [.maskCommand]
        var heldKey: UInt16?
        let shortcut = DictationShortcut(modifierFlags: CGEventFlags.maskCommand.rawValue, keyCode: 0)!
        if !ProbeInputBarrier.ignoresInput(.keyDown, flags: [.maskCommand], previousFlags: &flags,
                                          heldKey: &heldKey, shortcut: shortcut, keyCode: 0) {
            fixture.beforeInput("fresh shortcut") {}
        }
        precondition(fixture.final(), "deferred shortcut lost the previous finalized transcript")
        precondition(fixture.view.string == "prefix English final suffix")
    }

    private static func productionAcquisition() {
        let caret = NSRange(location: 0, length: 0)
        let unknown = ProbeSessionOwnership.Observation(selection: caret, marked: unavailable, composition: .unreadable)
        precondition(ProbeSessionOwnership(acquiredFromLayout: false, observation: unknown) == nil,
                     "another keyboard method authorized an unknown composition")
        let acquired = ProbeSessionOwnership(acquiredFromLayout: true, observation: unknown)!
        precondition(acquired.canOperate(unknown), "exclusive acquisition from a layout was refused")
        let foreign = ProbeSessionOwnership.Observation(selection: caret, marked: NSRange(location: 0, length: 5), composition: .foreign)
        precondition(ProbeSessionOwnership(acquiredFromLayout: true, observation: foreign) == nil,
                     "keyboard acquisition replaced a known foreign composition")
        let malformed = ProbeSessionOwnership.Observation(selection: caret, marked: NSRange(location: 0, length: NSNotFound), composition: .unreadable)
        precondition(ProbeSessionOwnership(acquiredFromLayout: true, observation: malformed) == nil,
                     "acquisition accepted arbitrary unreadable marked metadata")
        let marked = ProbeSessionOwnership.Observation(selection: caret, marked: NSRange(location: 0, length: 5), composition: .unreadable)
        precondition(acquired.didMark(marked, utf16Length: 5))
        precondition(acquired.requiresUnicodeFinal && !acquired.finishNativeCommit(),
                     "unreadable draft was eligible for native final insertion")
        precondition(acquired.didDiscard(unknown))
        precondition(acquired.requiresUnicodeFinal && !acquired.finishNativeCommit(),
                     "cancellation erased unreadable draft delivery policy")
        let absent = ProbeSessionOwnership.Observation(selection: caret, marked: NSRange(location: 0, length: 0), composition: .absent)
        let readable = ProbeSessionOwnership(acquiredFromLayout: false, observation: absent)!
        let owned = ProbeSessionOwnership.Observation(selection: caret, marked: NSRange(location: 0, length: 5), composition: .owned)
        precondition(readable.didMark(owned, utf16Length: 5) && !readable.requiresUnicodeFinal)
        precondition(readable.didDiscard(absent) && readable.finishNativeCommit())
        precondition(!readable.finishNativeCommit(), "native commit repeated its final insertion")
    }

    @MainActor
    private static func uninterruptedLifecycle() {
        let fixture = Fixture()
        precondition(fixture.mark("English alpha"))
        precondition(fixture.mark("English beta"))
        precondition(fixture.view.string == "prefix English betasuffix")
        precondition(fixture.cancel())
        precondition(fixture.view.string == "prefix suffix")
        precondition(fixture.view.selectedRange() == NSRange(location: 7, length: 0))
        precondition(fixture.final())
        precondition(!fixture.final())
        precondition(!fixture.mark("duplicate"))
        precondition(fixture.view.string == "prefix English final suffix")
    }

    @MainActor
    private static func interruptedKey(_ reason: String, key: String, code: UInt16) {
        let fixture = Fixture()
        precondition(fixture.mark("English draft"))
        fixture.beforeInput(reason) {
            fixture.view.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                 windowNumber: 0, context: nil, characters: key,
                                                 charactersIgnoringModifiers: key, isARepeat: false, keyCode: code)!)
        }
        precondition(fixture.operations == ["mark", "discard", "forward"], "input preceded discard")
        precondition(!fixture.view.string.contains("English draft"), "typing committed the old draft")
        precondition(!fixture.mark("English beta") && !fixture.final(), "retired pass resumed")
        if reason == "typing" { precondition(fixture.view.string == "prefix xsuffix") }
    }

    @MainActor
    private static func interruptedLifecycle(_ reason: String) {
        let fixture = Fixture()
        precondition(fixture.mark("English draft"))
        fixture.beforeInput(reason) { fixture.view.unmarkText() }
        precondition(fixture.view.string == "prefix suffix", "host finalized a stale preview")
        precondition(!fixture.mark("English beta") && !fixture.final())
        fixture.policy.interrupt("another callback") { preconditionFailure("retired cleanup repeated") }
    }

    @MainActor
    private static func refusesChangedHostState() {
        let fixture = Fixture()
        precondition(fixture.mark("English draft"))
        fixture.view.unmarkText()
        fixture.view.setSelectedRange(NSRange(location: 0, length: 0))
        let baseline = fixture.view.string
        fixture.beforeInput("missed host edit") {}
        precondition(fixture.view.string == baseline, "ambiguous cleanup altered ordinary text")
        precondition(!fixture.final())
    }

    private static func refusesUncontrolledStart() {
        let opaque = ProbeSessionOwnership.Observation(selection: NSRange(location: 0, length: 0),
                                                      marked: unavailable, composition: .unreadable)
        precondition(ProbeSessionOwnership(controlledEmptyFixture: false, observation: opaque) == nil)
        let foreign = ProbeSessionOwnership.Observation(selection: NSRange(location: 0, length: 0),
                                                       marked: NSRange(location: 0, length: 5), composition: .foreign)
        precondition(ProbeSessionOwnership(controlledEmptyFixture: true, observation: foreign) == nil)
    }

    private static func fnFlagsOnly() {
        let fn = CGEventFlags.maskSecondaryFn.rawValue
        precondition(ProbeSessionOwnership.ignoresFlagsChange(fn, fnMask: fn))
        precondition(ProbeSessionOwnership.ignoresFlagsChange(0, fnMask: fn))
        precondition(!ProbeSessionOwnership.ignoresFlagsChange(fn | CGEventFlags.maskShift.rawValue, fnMask: fn))
        for flags in [NSEvent.ModifierFlags.function, []] {
            let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: 0,
                                        windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                                        isARepeat: false, keyCode: 63)!
            precondition(ProbeSessionOwnership.ignoresControllerEvent(isFlagsChange: event.type == .flagsChanged,
                                                                     keyCode: event.keyCode), "fn release retired pass")
        }
        precondition(!ProbeSessionOwnership.ignoresControllerEvent(isFlagsChange: true, keyCode: 56))
    }

    @MainActor
    private static func barrierFailure() {
        let fixture = Fixture()
        precondition(fixture.mark("English draft"))
        fixture.policy.retire("tap-disabled")
        precondition(!fixture.mark("English beta") && !fixture.final())
        precondition(fixture.view.hasMarkedText(), "ambiguous barrier failure guessed cleanup")
    }

    private static func preservesForeignSameLengthText() {
        let policy = ProbeSessionOwnership(controlledEmptyFixture: true, observation: .init(
            selection: NSRange(location: 0, length: 0), marked: unavailable, composition: .unreadable
        ))!
        let owned = ProbeSessionOwnership.Observation(selection: NSRange(location: 5, length: 0),
                                                     marked: NSRange(location: 0, length: 5), composition: .owned)
        precondition(policy.didMark(owned, utf16Length: 5))
        let foreign = ProbeSessionOwnership.Observation(selection: owned.selection, marked: owned.marked, composition: .foreign)
        precondition(!policy.canOperate(foreign))
    }

    @MainActor
    private static func reentrantMarkCannotRevive() {
        let fixture = Fixture()
        fixture.view.setMarkedText("English draft", selectedRange: NSRange(location: 13, length: 0),
                                   replacementRange: unavailable)
        fixture.policy.interrupt("host-commit") { fixture.discard() }
        precondition(!fixture.policy.didMark(fixture.observation, utf16Length: 13))
        precondition(fixture.policy.isRetired && !fixture.final())
    }

    @MainActor
    private static func reentrantDiscardCannotRevive() {
        let fixture = Fixture()
        precondition(fixture.mark("English draft"))
        fixture.discard()
        fixture.policy.interrupt("tap-disabled") {}
        precondition(!fixture.policy.didDiscard(fixture.observation))
        precondition(!fixture.final())
    }

    @MainActor
    private static func finishedInsertionCannotRepeat() {
        let fixture = Fixture()
        precondition(fixture.policy.finish())
        fixture.policy.interrupt("host callback") { preconditionFailure("finished pass tried cleanup") }
        fixture.view.insertText("English final ", replacementRange: unavailable)
        precondition(fixture.policy.state == .finished && !fixture.final())
        precondition(fixture.view.string == "prefix English final suffix")
    }
}
