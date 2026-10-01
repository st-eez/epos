import AppKit
import Foundation

@main
enum PreviewSafetyTests {
    private static let replacementRange = NSRange(location: NSNotFound, length: NSNotFound)

    @MainActor
    static func main() {
        preservesSelectedText()
        preservesForeignComposition()
        cancelsPreviewAtCaret()
        preservesUnmarkedOtherField()
        preservesSelectionAfterHostEndsComposition()
        preservesForeignCompositionAfterHostEndsOurMark()
        preservesForeignCompositionWithUnreadableText()
        preservesHostStateWhenCancellingWithoutRecord()
        refusesUnreadableSelection()
        refusesSupersededCommands()
        print("inline preview safety: 10 checks passed")
    }

    @MainActor
    private static func mark(_ text: String, in view: NSTextView) {
        view.setMarkedText(
            text,
            selectedRange: NSRange(location: (text as NSString).length, length: 0),
            replacementRange: replacementRange
        )
    }

    @MainActor
    private static func discard(_ view: NSTextView) {
        view.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: replacementRange)
        view.unmarkText()
    }

    @MainActor
    private static func state(
        of view: NSTextView,
        expected: (range: NSRange, text: String)? = nil
    ) -> ProbePreviewSafety.CompositionState {
        ProbePreviewSafety.compositionState(markedRange: view.markedRange(), expected: expected) {
            view.attributedSubstring(forProposedRange: $0, actualRange: nil)?.string
        }
    }

    @MainActor
    private static func canWrite(
        to view: NSTextView,
        expected: (range: NSRange, text: String)? = nil
    ) -> Bool {
        ProbePreviewSafety.canWrite(
            selectedRange: view.selectedRange(),
            compositionState: state(of: view, expected: expected),
            continuingComposition: expected != nil
        )
    }

    @MainActor
    private static func preservesSelectedText() {
        let view = NSTextView(frame: .zero)
        view.string = "hello world"
        let selection = NSRange(location: 6, length: 5)
        view.setSelectedRange(selection)
        if canWrite(to: view) {
            mark("dictation preview", in: view)
            discard(view)
        }
        precondition(view.string == "hello world", "preview deleted the original selection")
        precondition(view.selectedRange() == selection, "preview moved the original selection")
    }

    @MainActor
    private static func preservesForeignComposition() {
        let view = NSTextView(frame: .zero)
        view.string = "prefix "
        view.setSelectedRange(NSRange(location: 7, length: 0))
        mark("other input method", in: view)
        let baseline = view.string
        let baselineMark = view.markedRange()
        if canWrite(to: view) {
            mark("dictation preview", in: view)
        }
        precondition(view.string == baseline, "preview replaced another input method's composition")
        precondition(view.markedRange() == baselineMark, "preview changed the foreign marked range")
    }

    @MainActor
    private static func cancelsPreviewAtCaret() {
        let view = NSTextView(frame: .zero)
        view.string = "prefix suffix"
        let caret = NSRange(location: 7, length: 0)
        view.setSelectedRange(caret)
        precondition(canWrite(to: view))
        mark("dictation preview", in: view)
        precondition(view.string == "prefix dictation previewsuffix", "the safe preview did not render")
        let original = (range: NSRange(location: 7, length: 17), text: "dictation preview")
        precondition(canWrite(to: view, expected: original), "a valid owned update was refused")
        mark("updated preview", in: view)
        let updated = (range: NSRange(location: 7, length: 15), text: "updated preview")
        precondition(state(of: view, expected: updated) == .owned, "updated preview ownership was not verified")
        discard(view)
        precondition(view.string == "prefix suffix", "cancel did not restore the field")
        precondition(view.selectedRange() == caret, "cancel did not restore the caret")
        precondition(canWrite(to: view), "final commit after owned cancellation was refused")
        view.insertText("authoritative ", replacementRange: replacementRange)
        precondition(view.string == "prefix authoritative suffix", "final commit after cancellation did not land once")
    }

    @MainActor
    private static func preservesUnmarkedOtherField() {
        let view = NSTextView(frame: .zero)
        view.string = "unrelated selected text"
        let selection = NSRange(location: 10, length: 8)
        view.setSelectedRange(selection)
        let original = (range: NSRange(location: 7, length: 11), text: "old preview")
        if state(of: view, expected: original) == .owned {
            discard(view)
        }
        precondition(view.string == "unrelated selected text", "cleanup deleted another field's selection")
        precondition(view.selectedRange() == selection, "cleanup moved another field's selection")
    }

    private static func refusesUnreadableSelection() {
        let unreadable = ProbePreviewSafety.compositionState(
            markedRange: replacementRange, expected: nil, readText: { _ in nil }
        )
        precondition(!ProbePreviewSafety.canWrite(
            selectedRange: replacementRange,
            compositionState: unreadable,
            continuingComposition: false
        ), "unknown selection was treated as empty")
        let original = (range: NSRange(location: 7, length: 11), text: "old preview")
        let unreadableText = ProbePreviewSafety.compositionState(
            markedRange: original.range, expected: original, readText: { _ in nil }
        )
        precondition(unreadableText == .unreadable, "an unreadable marked span was treated as owned")
    }

    @MainActor
    private static func preservesSelectionAfterHostEndsComposition() {
        let view = NSTextView(frame: .zero)
        view.string = "prefix "
        view.setSelectedRange(NSRange(location: 7, length: 0))
        mark("old preview", in: view)
        view.unmarkText()
        let selection = NSRange(location: 0, length: 6)
        view.setSelectedRange(selection)
        let baseline = view.string
        let original = (range: NSRange(location: 7, length: 11), text: "old preview")
        if canWrite(to: view, expected: original) {
            mark("updated preview", in: view)
        }
        precondition(view.string == baseline, "a stale composition record bypassed the new selection guard")
        precondition(view.selectedRange() == selection, "a stale composition record moved the selection")
    }

    @MainActor
    private static func preservesForeignCompositionAfterHostEndsOurMark() {
        let view = NSTextView(frame: .zero)
        view.string = "prefix "
        view.setSelectedRange(NSRange(location: 7, length: 0))
        mark("old preview", in: view)
        let original = (range: NSRange(location: 7, length: 11), text: "old preview")
        view.unmarkText()
        view.setSelectedRange(original.range)
        mark("new preview", in: view)
        let baseline = view.string
        let selection = view.selectedRange()
        precondition(view.markedRange() == original.range, "fixture must exercise the same range with different text")
        precondition(selection.length == 0, "fixture must exercise an empty caret")
        precondition(state(of: view, expected: original) == .foreign, "a stale tuple claimed a foreign mark")
        if canWrite(to: view, expected: original) { mark("Epos update", in: view) }
        if state(of: view, expected: original) == .owned { discard(view) }
        if canWrite(to: view, expected: original) {
            view.insertText("Epos final", replacementRange: replacementRange)
        }
        // Final commit after an acknowledged Epos cancellation has no record.
        if canWrite(to: view) { view.insertText("Epos final", replacementRange: replacementRange) }
        precondition(view.string == baseline, "update, cancel, or final commit changed foreign composition text")
        precondition(view.markedRange() == original.range, "a foreign marked range was cleared")
        precondition(view.selectedRange() == selection, "a foreign composition's caret was moved")
    }

    @MainActor
    private static func preservesForeignCompositionWithUnreadableText() {
        let view = NSTextView(frame: .zero)
        view.string = "prefix "
        view.setSelectedRange(NSRange(location: 7, length: 0))
        mark("other input method", in: view)
        let baseline = view.string
        let range = view.markedRange()
        let selection = view.selectedRange()
        let observed = ProbePreviewSafety.compositionState(
            markedRange: range, expected: nil, readText: { _ in nil }
        )
        precondition(observed == .foreign, "a foreign marked range was treated as ordinary unreadable text")
        if ProbePreviewSafety.canWrite(
            selectedRange: selection, compositionState: observed, continuingComposition: false
        ) {
            view.insertText("Epos final", replacementRange: replacementRange)
        }
        precondition(view.string == baseline, "unreadable foreign text was replaced")
        precondition(view.markedRange() == range, "unreadable foreign composition was cleared")
        precondition(view.selectedRange() == selection, "unreadable foreign composition's caret moved")
    }

    @MainActor
    private static func preservesHostStateWhenCancellingWithoutRecord() {
        let view = NSTextView(frame: .zero)
        view.string = "prefix "
        view.setSelectedRange(NSRange(location: 7, length: 0))
        mark("old preview", in: view)
        discard(view)
        let safeReply = ProbePreviewSafety.cancellationReplyWithoutComposition(
            selectedRange: view.selectedRange(), compositionState: state(of: view)
        )
        precondition(safeReply == "ok cancelled nothing marked", "a safe empty caret was refused after host cleanup")
        precondition(view.string == "prefix ", "cancellation acknowledgement changed the safe field")
        precondition(view.selectedRange() == NSRange(location: 7, length: 0), "safe cancellation moved the caret")
        let selection = NSRange(location: 0, length: 6)
        view.setSelectedRange(selection)
        let selectionReply = ProbePreviewSafety.cancellationReplyWithoutComposition(
            selectedRange: view.selectedRange(), compositionState: state(of: view)
        )
        precondition(selectionReply == "err unsafe selection or composition before cancellation",
                     "cancellation without a record accepted a new selection")
        precondition(view.string == "prefix ", "cancellation without a record deleted newly selected text")
        precondition(view.selectedRange() == selection, "cancellation without a record moved a new selection")

        view.setSelectedRange(NSRange(location: 7, length: 0))
        mark("other input method", in: view)
        let baseline = view.string
        let foreignRange = view.markedRange()
        let foreignCaret = view.selectedRange()
        let foreignReply = ProbePreviewSafety.cancellationReplyWithoutComposition(
            selectedRange: view.selectedRange(), compositionState: state(of: view)
        )
        precondition(foreignReply == "err unsafe selection or composition before cancellation",
                     "cancellation without a record accepted a foreign composition")
        precondition(view.string == baseline, "cancellation without a record deleted foreign marked text")
        precondition(view.markedRange() == foreignRange, "cancellation without a record cleared a foreign mark")
        precondition(view.selectedRange() == foreignCaret, "cancellation without a record moved the foreign caret")
    }

    @MainActor
    private static func refusesSupersededCommands() {
        let ownership = ProbeConnectionOwnership()
        let view = NSTextView(frame: .zero)
        view.string = "new recording"
        ownership.adopt(1)
        let queuedBegin = { ownership.perform(1) { view.string = "old begin"; return "ok" } }
        ownership.adopt(2)
        precondition(queuedBegin() == "err superseded connection", "queued old begin reclaimed the pass")
        let oldCommit = ownership.perform(1) { view.insertText("old commit", replacementRange: replacementRange); return "ok" }
        precondition(oldCommit == "err superseded connection", "old commit reached the new client")
        let oldCancel = ownership.perform(1) { discard(view); return "ok" }
        precondition(oldCancel == "err superseded connection", "old cleanup reached the new client")
        ownership.retire(1)
        let accepted = ownership.perform(2) { view.string += " accepted"; return "ok" }
        precondition(accepted == "ok", "old retirement invalidated the current connection")
        precondition(view.string == "new recording accepted", "superseded commands changed the document")
    }
}
