import AppKit
import Foundation

@main
enum CallbackTests {
    @MainActor
    static func main() throws {
        let trace = try CallbackTrace()
        let view = TracedTextView(frame: .zero, trace: trace)
        let firstEvent = trace.events.count
        let unavailable = NSRange(location: NSNotFound, length: NSNotFound)
        view.setMarkedText("EPOS draft alpha", selectedRange: NSRange(location: 16, length: 0), replacementRange: unavailable)
        view.setMarkedText(NSAttributedString(string: "EPOS draft beta"), selectedRange: NSRange(location: 15, length: 0),
                           replacementRange: unavailable)
        view.unmarkText()
        view.setSelectedRange(NSRange(location: 0, length: view.string.utf16.count))
        view.insertText(CallbackTrace.syntheticPhrase, replacementRange: unavailable)
        let callbacks = trace.events.dropFirst(firstEvent).filter { $0.phase == "before" && $0.depth == 0 }
        let topLevelWrites = callbacks.filter { $0.callback == "setMarkedText" || $0.callback == "insertText" }
        precondition(topLevelWrites.map(\.callback) == ["setMarkedText", "setMarkedText", "insertText"],
                     "unexpected outer callback metadata: \(topLevelWrites.map { ($0.callback, $0.payloadUTF16Length) })")
        precondition(callbacks.contains { $0.callback == "unmarkText" })
        precondition(callbacks.filter { $0.callback == "setMarkedText" }.map(\.payloadUTF16Length) == [16, 15])
        precondition(view.string == CallbackTrace.syntheticPhrase)
        precondition(CallbackTrace.matchesSyntheticPhrase("Epos final token."))
        precondition(!CallbackTrace.matchesSyntheticPhrase("different phrase"))
        let data = try JSONEncoder().encode(trace.events)
        let serialized = String(decoding: data, as: UTF8.self)
        for phrase in ["EPOS draft alpha", "EPOS draft beta", CallbackTrace.syntheticPhrase] {
            precondition(!serialized.contains(phrase), "trace retained text payload")
        }
        precondition(trace.events.last?.marked.length == 0)
        print("native Dictation fixture: callback order, lengths, phrase equality and trace privacy passed")
    }
}
