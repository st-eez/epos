import AppKit
import Foundation

struct CallbackEvent: Codable {
    struct Range: Codable {
        let location: Int?
        let length: Int?

        init(_ value: NSRange) {
            location = value.location == NSNotFound ? nil : value.location
            length = value.length == NSNotFound ? nil : value.length
        }
    }

    let callback: String
    let phase: String
    let depth: Int
    let milliseconds: Double
    let payloadUTF16Length: Int?
    let selection: Range
    let marked: Range
    let replacement: Range?
    let syntheticPhraseMatches: Bool?
}

@MainActor
final class CallbackTrace {
    static let syntheticPhrase = "EPOS final token"
    private let start = ProcessInfo.processInfo.systemUptime
    private(set) var events = [CallbackEvent]()
    private let output: FileHandle?
    var onEvent: ((String) -> Void)?
    private(set) var depth = 0

    init(file: URL? = nil) throws {
        if let file {
            guard FileManager.default.createFile(atPath: file.path, contents: nil,
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            output = try FileHandle(forWritingTo: file)
        } else {
            output = nil
        }
    }

    func record(_ callback: String, phase: String, view: NSTextView, payload: Any? = nil,
                replacement: NSRange? = nil, phraseMatches: Bool? = nil) {
        let length: Int?
        if let attributed = payload as? NSAttributedString {
            length = attributed.length
        } else if let string = payload as? String {
            length = (string as NSString).length
        } else {
            length = nil
        }
        let event = CallbackEvent(callback: callback, phase: phase, depth: depth,
                                  milliseconds: (ProcessInfo.processInfo.systemUptime - start) * 1_000,
                                  payloadUTF16Length: length, selection: .init(view.selectedRange()),
                                  marked: .init(view.markedRange()), replacement: replacement.map(CallbackEvent.Range.init),
                                  syntheticPhraseMatches: phraseMatches)
        events.append(event)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let data = try encoder.encode(event)
            try output?.write(contentsOf: data + Data([0x0a]))
            onEvent?(String(decoding: data, as: UTF8.self))
        } catch {
            onEvent?("Evidence write failed. Stop this trial.")
        }
    }

    func callback(_ name: String, view: NSTextView, payload: Any? = nil,
                  replacement: NSRange? = nil, body: () -> Void) {
        record(name, phase: "before", view: view, payload: payload, replacement: replacement)
        depth += 1
        defer {
            depth -= 1
            record(name, phase: "after", view: view, payload: payload, replacement: replacement)
        }
        body()
    }

    static func matchesSyntheticPhrase(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).lowercased()
            == syntheticPhrase.lowercased()
    }
}

/// Trace the public NSTextInputClient boundary while leaving its native editing
/// behavior to NSTextView. Payload contents never enter the trace.
@MainActor
final class TracedTextView: NSTextView {
    let trace: CallbackTrace
    private let backingStorage: NSTextStorage

    init(frame: NSRect, trace: CallbackTrace) {
        self.trace = trace
        // A nil container creates a view without editable storage. Supply the
        // standard Cocoa text system explicitly and retain its backing storage.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: max(frame.width, 1), height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        backingStorage = storage
        super.init(frame: frame, textContainer: container)
        isRichText = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticTextReplacementEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        trace.callback("setMarkedText", view: self, payload: string, replacement: replacementRange) {
            super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        }
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        trace.callback("insertText", view: self, payload: insertString, replacement: replacementRange) {
            super.insertText(insertString, replacementRange: replacementRange)
        }
    }

    override func unmarkText() {
        trace.callback("unmarkText", view: self) { super.unmarkText() }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 96 { trace.record("F5", phase: "key-down", view: self) }
        super.keyDown(with: event)
    }
}
