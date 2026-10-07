import AppKit
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
        print("session ownership prototype: 17 native lifecycle checks passed")
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
