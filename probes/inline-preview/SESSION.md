# Session ownership experiment

The [scope brief](../../specs/preview-session-prototype.md) defines this
controlled experiment. Normal builds exclude `EPOS_SESSION_PROTOTYPE`; the
experimental `session-*` socket commands are unavailable in them.

The prototype permits unreadable draft text only while an uninterrupted pass
owns its pinned controller, client, connection, target process and window. It
requires a readable empty selection, unchanged selection after each draft, and
the concrete range from its preceding native mark. It requires a synchronous
Quartz event tap on the main run loop, Accessibility trust, and verified tap mask
coverage. The tap returns every event unchanged after retiring and attempting to
discard the draft. Ordinary keys, Backspace, arrows, other modifiers, mouse
actions, focus changes, host callbacks and disconnection retire the pass. Fn press
and release remain allowed. A disabled tap retires without guessing cleanup.

The first mark requires one newly activated client after `session-snapshot` and
the explicit `controlled-empty-fixture` assertion. This is an operator statement
about a disposable raw prompt. An empty selection or fresh object identity does
not prove composition absence. After cancellation the host may again hide the
marked range. Its acknowledgement records the ordered native discard call in
this fixture, not independently proven absence. Verify screenshots and actual
terminal bytes before treating a live pass as successful.

## Controlled run

Run these tools on the Mac host. A sandbox can hide running processes or the
registered input source and invalidate process restoration evidence. Launch apps
with `kosmos open` onto the agent workspace and use Cua for GUI interaction, with
a single operator. Never address an existing private terminal. The fixture runs
Python in raw terminal mode and executes no received input. It persists counts
and equality against fixed synthetic tokens only.

1. Run `probes/inline-preview/verify`. It compiles normal and experimental
   companions with warnings as errors, then runs native safety and ordered
   lifecycle checks. Those checks simulate unreadable text and callbacks; they
   do not establish live InputMethodKit or event tap ordering.
2. Run `probes/inline-preview/session-experiment prepare`. It prints a private
   temporary directory. It copies the installed companion, builds the gated
   prototype and matches its signing certificate and designated requirement.
   Review the prepared bundle and source before continuing.
   Certificate extraction uses `--extract-certificates=PREFIX`; codesign treats
   a separate prefix argument as another code path. Each prepared directory is
   single use. A second run refuses before stopping either app.
   Requirement comparison extracts exactly one `designated =>` line from either
   output stream. An executable-path diagnostic cannot substitute for it.
3. Run `session-experiment run PREPARED_DIRECTORY` in the background. It records
   settings, keyboard source and main binary fingerprints before stopping Epos,
   then preserves the original companion by rename. It restores after 360 seconds,
   a `finish` file, or a caught interruption. It never registers, enables or selects
   input sources. Required existing consent must already be present.
   The runner launches both the prototype and restored companion with
   `kosmos open -g`.
4. Run `python3 -I probes/inline-preview/Tools/session-client.py
   PREPARED_DIRECTORY` as one persistent interactive process. Send `preflight`
   and `snapshot` while Ghostty's new prompt does not yet exist. An untrusted
   companion refuses the event barrier. Report that failed gate rather than
   changing settings or repeatedly trying a mark.
5. Use `kosmos open` to create a separate Ghostty window running `python3 -I
   ABSOLUTE_REPO_PATH/probes/inline-preview/Tools/session-fixture.py
   PREPARED_DIRECTORY EPOS-SESSION-NONCE`. Confirm its fresh PID/window, nonce,
   live fixture PID and zero byte count. Configure `target PID WINDOW` in the
   client, focus that exact prompt through Cua, then send `begin`.
6. Send `alpha`, capture the prompt, then `beta` and capture again. Send `cancel`,
   confirm no draft and zero bytes, then `final`. `terminal.json` must show
   `exactFinal=true` and `byteCount=16`. The acknowledgement alone is insufficient.
7. Test interruption in a new controlled pass. A retired pass cannot begin again
   until `end`, and another begin still requires a newly activated client after
   a new snapshot. Deliver English `x`, Backspace, an arrow or mouse action through
   Cua's foreground HID route. Background AX or per-PID keyboard events can bypass
   the session tap and cannot establish keyboard coverage. Inspect counters and
   ranges, then attempt `beta` and `final`; both must refuse. Cover focus change,
   host callback and disconnect where the host permits them. Fn hold needs an
   actual hold; a tap or native state test does not verify it.
8. Create `finish` in the prepared directory. Verify `restoration.json`, including
   original manifest, source/settings fingerprints and companion process state.
   Reopen installed Epos with `kosmos open` if it was running before, and
   verify its actual installed executable. The runner keeps bundle restoration
   and main app relaunch evidence separate. To recover a stopped wrapper, use
   `session-experiment restore PREPARED_DIRECTORY`.
9. Create `stop-fixture` in the prepared directory. Confirm `running=false` and
   termios restoration, and close the synthetic window through Cua. Preserve the
   user's original terminals. Evidence files remain local.

Retain failed or unavailable checks alongside successful checks. A draft can
remain visible when the barrier or ownership readback becomes ambiguous; the
prototype then refuses its final text. This experiment does not provide daily
dictation or justify replacing the production ownership check.

## October 7 host preflight

The signed prototype returned `ok session preflight trusted=false`. Existing
input-source registration, enablement and selection did not supply the companion
process's required Accessibility trust. The persistent client sent exactly one
read-only preflight command. It sent no snapshot, begin, draft, cancellation or
final commands, and no GUI or foreground actions ran.

The operator immediately ended the bounded run. Restoration verified the original
companion's exact file hashes and modes, and confirmed that its installed process
was running. Before and after fingerprints matched for the shortcut, microphone
and inline-preview settings, input-source metadata and main Epos executable.
Main Epos was stopped before the experiment and remained stopped afterward.
The run preserved its private local `before.json`, `after.json`,
`restoration.json` and `protocol.jsonl` evidence.

This run established the permission prerequisite and restoration behavior.
Actual Ghostty draft updates, cleanup, typing interruption, event coverage,
held fn and final delivery remain unverified. Native lifecycle checks do not
settle those host outcomes.

## October 8 host preflight

A fresh signed prototype again returned `ok session preflight trusted=false`.
The protocol contains only that preflight command. The operator disconnected
immediately and finished the bounded run. No target, draft, cancellation or final
commands ran, and the experiment used no GUI or audio.

Restoration confirmed `bundleRestored=true`, `companionRunning=true` and
`fingerprintsMatch=true`. Main Epos was stopped before and after. The private
prepared directory retains the protocol and restoration evidence.

The operator separately opened the macOS `Privacy_Accessibility` settings URL
with `kosmos open` on the agent workspace. The observed pane was titled
"Device Control and Data Access" and showed Epos on and EposProbe off. No toggle
was pressed. The live fixed-text test remains blocked on the companion process's
own Accessibility trust. Ghostty rendering, revisions, cleanup, interruption and final delivery
remain unverified by this prototype.
