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

The focused AX window must match exactly one layer-zero Quartz window belonging
to the pinned process. Matching uses public AX position and size with Quartz
bounds, which both use the main display's top-left origin. The match must carry
the requested window ID and be on screen. Identical frames, including hidden
windows, refuse the pass. Each command repeats this check and keeps the existing
caret containment check. The prototype does not rely on the undocumented
`AXWindowNumber` attribute. Refusals report the failed gate and matching window
count; a missing or ambiguous fresh client reports its own count.

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

The agent workspace stays hidden for background work. This session prototype
requires the target to be the actual foreground application, so it cannot run
solely in that hidden workspace. An instruction to use the agent workspace does
not authorize showing or focusing it. Run foreground checks only when Steve
explicitly requests foreground control. A background rendering check must report
its narrower evidence separately from foreground session and interruption checks.

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

## Hidden workspace rendering run

`background-begin` selects a separate rendering test within the same prepared
prototype and persistent client. Keep the agent workspace hidden. Do not show
it, activate Ghostty, restore focus or send foreground input. The foreground
ownership steps above remain outside this background test.

Prepare and start the bounded runner as above. Send `preflight` and `snapshot`,
then create one owned disposable Ghostty raw prompt through `kosmos open`.
Verify its nonce, process and window independently through background Cua state
and the fixture metadata. The prompt must have received zero bytes. Configure
`target PID WINDOW`, then send `background-begin` without activating the app.

The client requires a running fixture heartbeat no older than two seconds,
zero bytes and the expected synthetic nonce before begin and every text command.
The companion requires the nonce as the owned AX window title, one fresh IMK
client, unchanged geometry and readable empty selection. It refuses a foreground
target. The client caret must intersect only the target among all Ghostty
windows, including hidden windows and windows from other Ghostty processes.
No fresh client, missing AX metadata or overlapping geometry ends this test at
that prerequisite. Background interaction does not authorize a foreground retry.
The pass pins the verified bounds at begin. Later commands refuse coherent window
movement or resizing with `window-frame-changed`, even when AX and Quartz still
agree with each other.

Send `alpha`, screenshot the owned window, then `beta` and screenshot again.
Send `cancel`, verify that the draft disappeared and the terminal still has zero
bytes, then send `final`. Only `EPOS draft alpha`, `EPOS draft beta` and
`EPOS final token` are allowed in this mode. Successful final delivery requires
`exactFinal=true` and `byteCount=16`. Ghostty requires an associated native event
for `insertText`; a companion acknowledgement cannot prove that requirement was
satisfied in the background.

The pass reuses the ordered lifecycle policy, client pin, selection checks,
reported marked range, callback retirement and disconnection cleanup. It does
not install a global event tap or observe global foreground changes. Inspection
labels the pass `rendering-only=true`, `tap=false` and `barrier=rendering-only`.
This run can establish visible replacement, cancellation and byte delivery in
the addressed client. It does not establish keyboard interruption, held fn,
focus protection or uninterrupted ownership. Finish and verify restoration,
stop the raw fixture and close only its owned window as above.

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
own Accessibility trust. Ghostty rendering, revisions, cleanup, interruption and
final delivery remained unverified by that preflight.

## October 8 permission and focused window trial

After Steve enabled EposProbe, a fresh signed run returned
`ok session preflight trusted=true`. The controlled Ghostty window had matching
AX and Quartz frames. Begin reached the focused window check and refused with
`gate=window-number-unavailable`, because that AX window did not expose
`AXWindowNumber`. Earlier begin refusals returned the stale `uninspected` gate
when no fresh client was available. The diagnostic now names that condition.

No native mark ran and the terminal received zero bytes. Restoration confirmed
the original companion, running process and unchanged fingerprints. This trial
identified a defect in the experimental window check. Draft rendering, revision,
cleanup, interruption and final delivery still require a new live run.

The replacement uses the documented coordinate systems for
[AX position](https://developer.apple.com/documentation/applicationservices/kaxpositionattribute)
and [Quartz bounds](https://developer.apple.com/documentation/coregraphics/kcgwindowbounds).
Native checks cover unique identity, wrong IDs, another process, other window
layers, identical visible and hidden frames, moved frames, secondary display
coordinates, invalid geometry and incomplete metadata.

A following prepared run recognized trust and took a client snapshot, but was
stopped after Steve clarified that the agent workspace must remain hidden.
Its raw fixture already reported two bytes before any begin command, so it was
not a valid empty fixture. No begin or native text operation ran. Exact bundle
restoration, companion liveness and unchanged fingerprints were confirmed.
The operator had incorrectly treated workspace placement as authorization for
foreground control. Future background probes must not repeat that assumption.

## October 8 hidden workspace trials

Two fresh signed runs recognized Accessibility trust and kept the agent
workspace hidden. Each used an owned raw terminal with its verified synthetic
nonce and zero received bytes. Both background begins refused with
`fresh-client-count fresh=0`. No draft, cancellation or final operation ran.

The second run included one Cua pixel click through its background per-process
route. Cua reported the click as unverified; the helper still had no fresh active
Ghostty client afterward. The AX tree exposed the fixture prompt, while the
window captures showed the title and blank terminal canvas. These results do not
establish that the click reached Ghostty's responder or that native draft
rendering is unavailable. Obtaining an activated IMK client for this inactive
fixture remains the failed prerequisite.

Resolve the test window's owner through Cua's WindowServer metadata. The raw
fixture's parent PID was a helper process rather than the window owner in these
runs. A background frame request also returned an unverified result; do not
treat that acknowledgement as the requested position.

Both runs restored the exact original companion and confirmed unchanged
settings, input-source and main executable fingerprints. Fixture shutdown
reported zero bytes and `running=false`. Fresh Kosmos state confirmed the agent
workspace remained hidden and the original terminal remained focused.
Rendering, draft revision, cancellation and final delivery remain unverified.
