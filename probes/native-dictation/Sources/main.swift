import AppKit
import Foundation

@MainActor
final class FixtureDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var input: TracedTextView?
    private var trace: CallbackTrace?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard CommandLine.arguments.count == 2 else { NSApp.terminate(nil); return }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
            guard (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700 else {
                NSApp.terminate(nil)
                return
            }
            let recorder = try CallbackTrace(file: directory.appendingPathComponent("callbacks.jsonl"))
            trace = recorder
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 660),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Epos native Dictation comparison"
            let stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 12
            stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
            let instructions = NSTextField(wrappingLabelWithString:
                "Click Start trial, then the input below. Press your F5 Dictation shortcut and say only: "
                + "\"\(CallbackTrace.syntheticPhrase)\". Pause while recording so the operator can inspect the draft. "
                + "Stop Dictation, then click Finish trial. The saved trace contains callback names, lengths, ranges "
                + "and timing. This fixture saves no text or audio. Use a new app launch for each trial.")
            stack.addArrangedSubview(instructions)
            let buttons = NSStackView(views: [NSButton(title: "Start trial", target: self, action: #selector(startTrial)),
                                             NSButton(title: "Finish trial", target: self, action: #selector(finishTrial))])
            stack.addArrangedSubview(buttons)
            let editor = TracedTextView(frame: NSRect(x: 0, y: 0, width: 804, height: 220), trace: recorder)
            editor.font = .systemFont(ofSize: 20)
            editor.textColor = .textColor
            editor.backgroundColor = .textBackgroundColor
            editor.isVerticallyResizable = true
            editor.isHorizontallyResizable = false
            editor.autoresizingMask = .width
            editor.textContainer?.widthTracksTextView = true
            editor.textContainer?.containerSize = NSSize(width: 804, height: CGFloat.greatestFiniteMagnitude)
            input = editor
            let inputScroll = NSScrollView()
            inputScroll.hasVerticalScroller = true
            inputScroll.documentView = editor
            stack.addArrangedSubview(inputScroll)
            stack.addArrangedSubview(NSTextField(labelWithString: "Public callback trace. Evidence is local."))
            let visibleTrace = NSTextView(frame: NSRect(x: 0, y: 0, width: 804, height: 190))
            visibleTrace.isEditable = false
            visibleTrace.isRichText = false
            visibleTrace.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            visibleTrace.textColor = .textColor
            visibleTrace.backgroundColor = .textBackgroundColor
            visibleTrace.isVerticallyResizable = true
            visibleTrace.isHorizontallyResizable = false
            visibleTrace.autoresizingMask = .width
            visibleTrace.textContainer?.widthTracksTextView = true
            visibleTrace.textContainer?.containerSize = NSSize(width: 804, height: CGFloat.greatestFiniteMagnitude)
            let traceScroll = NSScrollView()
            traceScroll.hasVerticalScroller = true
            traceScroll.documentView = visibleTrace
            stack.addArrangedSubview(traceScroll)
            recorder.onEvent = { [weak visibleTrace] line in
                visibleTrace?.textStorage?.append(NSAttributedString(string: line + "\n", attributes: [
                    .foregroundColor: NSColor.textColor,
                    .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
                ]))
                visibleTrace?.scrollToEndOfDocument(nil)
            }
            window.contentView = stack
            instructions.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36).isActive = true
            inputScroll.widthAnchor.constraint(equalTo: instructions.widthAnchor).isActive = true
            traceScroll.widthAnchor.constraint(equalTo: instructions.widthAnchor).isActive = true
            inputScroll.heightAnchor.constraint(equalToConstant: 220).isActive = true
            traceScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 190).isActive = true
            self.window = window
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(editor)
            recorder.record("fixture", phase: "ready", view: editor)
        } catch {
            NSApp.terminate(nil)
        }
    }

    @objc private func startTrial() {
        guard let input, let trace else { return }
        input.string = ""
        input.setSelectedRange(NSRange(location: 0, length: 0))
        trace.record("trial", phase: "start", view: input)
        window?.makeFirstResponder(input)
    }

    @objc private func finishTrial() {
        guard let input, let trace else { return }
        trace.record("trial", phase: "finish", view: input,
                     phraseMatches: CallbackTrace.matchesSyntheticPhrase(input.string))
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = FixtureDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.regular)
    application.run()
}
