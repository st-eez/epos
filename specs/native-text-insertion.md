# Native Text Insertion Feasibility

Status: investigated on 2026-05-27. This is post-baseline work; baseline behavior remains final-text insertion through the paste backend.

## Verdict

The previous session's finding is mostly valid: Epos is currently outside the macOS text input session, and native-style insertion requires Epos to participate as an input method.

The important correction is that this is not just a new implementation of `TextInsertionBackend` inside the current menu bar app. A normal app does not get the focused field's `NSTextInputClient`. The native path needs an InputMethodKit input-method bundle selected as an input source. That input method receives an input-session client and can call `insertText` for final text and `setMarkedText` for live provisional text.

## Verified Facts

- Epos captures microphone audio directly through `AudioCapture`.
- Epos transcribes through `SpeechAnalyzer` and `SpeechTranscriber`.
- `AppCoordinator` applies the correction layer and calls `TextInsertionBackend.insert` only after final text exists.
- The current concrete backend, `PasteTextInjector`, still uses the general pasteboard plus synthesized Cmd-V and then restores the clipboard.
- `NSTextInputClient` publicly defines `insertText:replacementRange:` in `/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks/AppKit.framework/Versions/C/Headers/NSTextInputClient.h:37` and `setMarkedText:selectedRange:replacementRange:` in the same file at line 45.
- `IMKTextInput` publicly defines input-method client insertion in `/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks/Carbon.framework/Versions/A/Frameworks/HIToolbox.framework/Versions/A/Headers/IMKInputSession.h:74` and marked-text calls in the same file at line 89.
- `IMKInputController` exposes the current input-session client through `client` in `/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks/InputMethodKit.framework/Versions/A/Headers/IMKInputController.h:338`.
- `IMKServer` is the public server object an input method creates in its main function, per `/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks/InputMethodKit.framework/Versions/A/Headers/IMKServer.h:11`.
- Swift can import InputMethodKit in this toolchain and type-check an `IMKInputController` subclass that calls `client().insertText(...replacementRange:)` and `client().setMarkedText(...selectionRange:replacementRange:)`.
- macOS input methods are packaged as app bundles under a `Library/Input Methods` domain, per `/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks/Carbon.framework/Versions/A/Frameworks/HIToolbox.framework/Versions/A/Headers/TextInputSources.h:1350`.

## What We Can Build

First production slice:

- Keep `PasteTextInjector` as the default and fallback.
- Add an `EposInputMethod` target that registers an `IMKServer`, exposes an `IMKInputController`, and installs to `$HOME/Library/Input Methods` or `/Library/Input Methods`.
- Start with a spike that commits a fixed diagnostic string through the active input-method client. Verify in TextEdit and at least one browser/editor field.
- Once final commit works, reuse the existing Epos library path inside the input method: `AudioCapture -> Transcriber -> TranscriptCanonicalizer -> client.insertText`.
- Keep the menu bar app for settings, permissions guidance, and fallback paste insertion. Add IPC only if the speech engine must remain in the menu bar app instead of the input method process.
- Add marked-text partials only after final commit is reliable: `setMarkedText` for partial transcript updates, `insertText` on release, and `unmarkText` on cancel.

## Constraints And Risks

- The user will likely need to install and select the Epos input method as an input source. Without that, the app cannot get the input-session client and must fall back to paste.
- Mic and speech permissions may be separate for the input-method process. The installed app path and signing identity matter for TCC, just as they already do for `/Applications/Epos.app`.
- Some clients may not support all document access features. `IMKInputSession.h:93` says selection, attributed substring, and document length depend on client support; final insertion at the current selection is still the lowest-risk operation.
- The exact Apple Dictation UI, ambiguous-word styling, and deep system context are not fully public. We can emulate final insertion and marked provisional text, not clone all Dictation behavior.
- Streaming partials through repeated clipboard paste remains the wrong approach. It risks corrupting selection, rich text state, undo grouping, and user typing.

## Acceptance For The Spike

- A selected Epos input method commits a fixed test string into the focused TextEdit document without changing the pasteboard.
- The same path works in one browser text field.
- If the input method is not selected or insertion fails, the existing paste backend remains available.
- No transcript text is written to diagnostic logs.
