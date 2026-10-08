# Native Dictation comparison

Steve reports that his F5 Apple Dictation shortcut streams into Ghostty. This
[comparison scope](../../specs/preview-session-prototype.md#native-dictation-comparison)
measures that behavior separately from Epos's marked-text session prototype.
The fixture calls no speech or microphone API. An automated attempt can use Cua
and one short, locally synthesized English phrase played through the speakers
into the physical microphone. Record that route separately from human speech;
do not treat it as a recognition accuracy test. Delete the synthesized input
file after the trial. Evidence retains no dictated text or microphone audio.

## AppKit callback trace

Build from the repository root:

```sh
probes/native-dictation/build
python3 -I probes/native-dictation/Tests/TerminalTimingTests.py
```

The build prints a private artifact directory containing a temporary signed app
and runs a synthetic native callback check with warnings as errors. It installs
nothing. Launch the reviewed app through Kosmos:

```sh
probes/native-dictation/run ARTIFACT_DIRECTORY
```

The fixture provides application and Edit menus with standard AppKit editing
actions. Inspect the live Edit menu for macOS's Start Dictation item; its presence
and availability require runtime verification. The fixture supplies no custom
Dictation action.

Cua Driver 0.32.0 maps `f5` to virtual keycode 96 and emits ordinary keyboard
events, as shown in its [release source](https://github.com/trycua/cua/blob/cua-driver-rs-v0.32.0/libs/cua-driver/rust/crates/platform-macos/src/input/keyboard.rs).
Apple distinguishes [function keys from their hardware features](https://support.apple.com/en-gb/102439)
and documents [Edit > Start Dictation](https://support.apple.com/en-gb/guide/mac-help/mh40584/26/mac/26).
A synthetic Cua F5 does not establish that the hardware microphone key was used.

The operator uses Cua to inspect the exact fixture window, clicks Start trial and
focuses its input. Start Dictation through the native Edit menu if offered, or use
the existing Dictation shortcut. Speak only
"EPOS final token", pause while Dictation remains active, then stop Dictation and
click Finish trial. Confirm the displayed phrase and trace independently.

`callbacks.jsonl` records `setMarkedText`, `insertText`, `unmarkText`, manual trial
markers, UTF-16 payload lengths, ranges and elapsed milliseconds. A depth of zero
identifies an outer callback; a greater depth identifies a callback invoked
inside another recorded native operation. NSTextView can invoke callbacks during
its own editing, so a nested insert is not independent evidence that Dictation
committed a phrase. The finish marker reports equality against the synthetic
phrase after ignoring capitalization and outer punctuation. It records no text
payload or audio. The live input itself remains visible in memory until the app
closes. Close the fixture after each trial and use a fresh build directory.

These callbacks describe the disposable NSTextView. They cannot prove which
callbacks Ghostty receives or Apple's private Dictation implementation. F5 may
be intercepted before the view sees a key-down; missing that marker does not
mean Dictation failed.

## Ghostty byte arrival

Use a separate disposable Ghostty prompt, created through the authorized GUI
operator. Reuse the raw terminal fixture with a fresh private directory and nonce:

```sh
python3 -I probes/inline-preview/Tools/session-fixture.py \
  PRIVATE_DIRECTORY EPOS-SESSION-NATIVE-NONCE
```

This fixture executes no input. The operator marks listening by writing
`listening` to `native-phase` in that directory, starts Dictation through the
native Edit menu or the existing shortcut, and supplies the same phrase. While
Dictation remains active, capture the synthetic
prompt and write `paused` to `native-phase`. Keep Dictation active until the
fixture records that paused event and the byte count settles across successive
reads. Capture the settled counts while Dictation remains active. Only then stop
Dictation and write `finished`. If Dictation ended earlier,
the trial cannot establish whether input arrived before stopping. Read
`terminal.json` and `terminal-events.jsonl` without reading arbitrary terminal
contents.

The state reports byte count, first and last raw-fixture read times, fixed token
equality and running status. The events record arrivals and manual phase markers
with elapsed times and byte counts. Counts growing before the paused marker
establish input delivery before Dictation stops. Visible words with zero bytes
require a settled receiver before they establish provisional rendering at that
point. Keep Dictation active, wait for the paused marker to appear in the event
trace, then wait for the byte count to settle across successive state reads.
A zero count from one state read is insufficient. Timestamps record when the
fixture reads queued bytes. Phase timing includes the operator's delay and must
not be presented as recognizer latency.

`nativePhraseMatches` allows the known capitalization and outer punctuation;
`exactFinal` retains the earlier prototype's strict 16-byte token check. They
measure different equality rules. The raw fixture renders only that exact old
token, so a blank terminal after bytes arrive does not mean native delivery failed.
Create `stop-fixture` to end the raw prompt and restore its terminal settings,
then close only the disposable window through the GUI operator.

## Current evidence

The source research verified Ghostty's installed revision
`33da6848d63b3bba2b4f31ab1531d618f2795192`. Its
[AppKit text input client](https://github.com/ghostty-org/ghostty/blob/33da6848d63b3bba2b4f31ab1531d618f2795192/macos/Sources/Ghostty/Surface%20View/SurfaceView_AppKit.swift)
stores temporary marked text separately and sends nonempty inserted text as typed
key events. [The Dictation fix](https://github.com/ghostty-org/ghostty/pull/13817)
is related primary source evidence. A controlled native trial still needs to
establish the actual callback order, commit timing and interruption behavior.

The synthetic checks validate callback capture and metadata privacy in a native
text view, and byte timing in an isolated pseudo-terminal. They produce no
recording cues and do not start Dictation. Epos's installed companion, settings
and final delivery behavior are outside this comparison's edits.

### October 8 automated attempt

A fresh fixture build passed its native check and signature verification. The
GUI operator opened the owned AppKit and Ghostty windows on the agent workspace.
Cua activated Start trial through its background Accessibility route. An initial
background F5 attempt was refused with `same_pid_keyboard_ambiguity` because Cua
observed another eligible window in that process. It sent no F5 event.

Cua also refused menu activation while the windows were hidden. Showing the
agent workspace allowed the native Edit > Start Dictation action. The AppKit
fixture showed Stop Dictation and the microphone badge. Ghostty showed Stop
Dictation, then Cancel Dictation. These observations establish activation of the
native UI.

One synthetic phrase playback was attempted per fixture. Both `afplay` commands
exited zero, but Steve reported hearing no test phrase and that starting Dictation
interrupted his music. The acoustic trial is invalid. A successful playback
process does not establish audible output or microphone input, so this attempt
cannot establish recognition behavior, text callbacks or streaming timing.

The AppKit trace contained only fixture readiness and trial start. The raw
Ghostty receiver reported zero bytes at the acknowledged paused marker and a
later state read. It later recorded four unidentified bytes, including one
backspace, and the fixed phrase did not match. Those bytes cannot be attributed
to Dictation.

Both owned windows were closed. The raw fixture reported `running=false` and
restored its terminal settings, and the synthetic audio file was deleted.
The controlled native comparison remains unconfirmed.
