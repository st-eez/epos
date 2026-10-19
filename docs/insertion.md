# Insertion

Epos captures the destination at shortcut press. The companion input method shows
unfinished text as native marked text. Confirmed phrases commit while held once
their corrections have enough context.
Release delivers the remaining text. Without a usable native session, Epos keeps
the guarded whole-transcript Unicode delivery path.

## Stream into field

Stream into field defaults on. A companion keyboard InputMethodKit bundle in
`~/Library/Input Methods/EposProbe.app` receives preview commands over a per-user
Unix socket. It renders the same cleaned provisional transcript as marked text
in the captured application's field. Updates are coalesced to at most one per
100 ms. If Epos is already your selected keyboard input method, the recording
adopts it with its underlying layout and leaves it selected after cleanup or
failure. Keeping Epos selected lets ordinary typing use that layout while its
activated client is ready for native streaming. Otherwise Epos acquires the source for the hold. After a successful native
commit acquired from a keyboard layout, it keeps Epos selected with that layout.
This avoids switching back to ABC and showing the input-source indicator at
release. Acquisition failures and borrowed input methods restore the prior source.
A source you choose
during dictation is retained. Selecting Epos alone does not start preview:
the companion must acknowledge an activated client in the captured application.

Each update supplies the complete unfinished phrase to `setMarkedText`, replacing
Epos's owned preview span. Confirmed phrases already committed remain ordinary
text. A confirmed phrase stays marked if its trailing words could continue a
dictionary alias, need following name context, or complete a spoken dash flag.
Preview still updates on every event. The next safe final commits the accumulated
phrase; release resolves any remaining suffix. Corrections freeze when a phrase
commits. Later phrases retain preceding
raw context for their corrections, but cannot rewrite confirmed text or match
aliases across that boundary. Cleanup keeps the full corrected transcript as
context. Trailing whitespace and commas remain provisional so filler removal can
still repair the boundary without changing committed text. Existing text around that
span is preserved. An update matching the text already sent removes any obsolete
queued revision. Commands awaiting a reply count as sent, so a newer revision
still replaces them when needed.
The native API treats the supplied string as the new composition; a payload
containing only changed words
does not portably preserve the rest of the provisional composition. A document
replacement range also requires host support, which Ghostty's current client
does not provide.

An empty provisional transcript clears Epos's owned composition while retaining
the preview pass. Later text starts a new composition.

The signed app installer installs the companion in lockstep with Epos. The local
installer leaves it uninstalled. The companion needs live registration and input
source consent. A missing companion, unidentified target, refused focus lock, or
failed channel leaves the microphone cue visible and uses guarded final delivery.
The menu toggle can disable inline preview.

Preview is skipped when the captured target has selected text. Before every mark,
the companion also requires a readable empty selection and checks the observed
marked range. During an uninterrupted acquired session, unavailable draft text
does not block updates or cancellation. Chromium can update its native marked
range before its surrounding-text cache. A readback identical to the text sampled
at that range immediately before the write is also unavailable as evidence of the
new draft. This allowance ends once the readback matches the draft. Other readable
text that differs from the draft still refuses the operation. Unknown selections and
ambiguous sets of client sessions use the HUD.
This prevents cancellation from deleting a selection that marked text replaced.

Each pass pins its concrete input client and command connection. Superseded
commands cannot mutate a newer pass, and cleanup addresses only the recorded
client. Ordinary keyboard and mouse input retire the session and discard its
owned draft synchronously before the event reaches the host. Source changes,
focus loss, host callbacks, and connection loss also retire ownership. The pass
cannot restart after retirement. An unreachable owner is refused instead of redirecting cleanup into a
different field in the same application. A healthy composition stays visible through its native final commit. A fallback
write requires acknowledged cleanup first. Marked text still requires
verification in each target app because rendering and teardown are host dependent.

A controlled October 15 Codex check displayed native underlined `E`, revised it
to `F` and `Epos test`, then committed `Epos verified` in place. Screenshots and
the editor's Accessibility value confirmed the final phrase and its removal.
The companion acknowledged each operation. This check exercised the companion
directly, not speech recognition or Epos's final Accessibility guard.

## Final delivery

The captured target guard checks the application and field. Keystroke delivery
also requires the original Accessibility value, caret, and selection when exposed. Opaque targets use process, window, and focus signature evidence. An absent or changed
target refuses delivery. Epos does not restore focus or undo the user's edits.

A healthy preview channel uses IME `insertText` to commit confirmed phrases once
their corrections have enough context. This replaces its owned marked span in
place. It retains the same native client,
connection and event barrier, and captures the new empty-selection baseline.
Release commits only the remaining phrase. If everything is already committed,
release performs no further insertion and clears an obsolete owned draft if needed. It does not clear the field first. Release waits for an outstanding preview
reply, without waiting for the preview throttle interval. The app checks captured
focus. The companion authorizes replacement of the composition by rechecking its
concrete client, native selection, marked range, readable draft and uninterrupted
session immediately before committing. Accessibility text can include generated
placeholders and layout newlines, so it is not compared with the native draft.
Ordinary final delivery and fallback still require the exact original
Accessibility value and selection after confirmed cleanup.

If the host leaves marked text after `insertText`, the result is ambiguous and
Epos suppresses a second write. A native acknowledgement still establishes
acceptance rather than independently verified delivery. Text containing a newline uses the keystroke path before any native phrase has
committed, as do unavailable preview channels. After a phrase has committed, a
newline in the remainder travels through an encoded native commit command. Those paths cancel
owned marked text, wait for the readable baseline to settle, then run the original
target guard. A conclusively refused first mark requires no settlement.

When the system-wide focus lookup has no value, cannot complete, or is unsupported,
Epos queries the frontmost application's focused field directly. It requires the
field to belong to that application's focused window and rechecks the application,
window, and field before accepting it. Permission and invalid-element errors
still refuse delivery.
Some Chromium hosts expose only the editor's `AXFocused` flag. If the application
lookup is also unavailable, Epos searches its focused window, bounded to 2,048
nodes and a 200 ms work budget with bounded IPC. It requires exactly one focused
editable field and rechecks the application and window afterward. Cached search
results require the same checks and a positive focused flag. Missing or ambiguous
focus still refuses delivery.

A foreign composition or a changed selection detected after preview blocks both
final delivery paths and shows `Not inserted`. Unconfirmed preview cleanup also
blocks delivery, because an opaque target cannot prove the composition is gone.
Ending or disconnecting that session relinquishes its stale composition record
without clearing unverified host text. A failed preview in one app must not block
the next recording in another app. Native mark-readback failures log the expected
length, actual selection and marked ranges, and ownership state without transcript text.
Other conclusive commit refusals or commands that could not be sent completely
can fall back to guarded keystrokes only before any phrase has committed. After
that, Epos preserves confirmed text and refuses further delivery with `Partly
inserted`. Cleanup discards only the unfinished draft. If the complete command was
sent and its acknowledgment is lost or malformed, delivery is ambiguous.
The transport closes a connection after any reply failure, so a late reply cannot
become the acknowledgement for the next command. Epos suppresses a
second write to avoid duplicated text and shows `Check the field`. This notice
asks the user to inspect the destination because the text may already be there.
Diagnostics record the outcome as `ime-commit-unacknowledged`.

The keystroke backend uses private Unicode keyboard events with cleared modifier
flags. Text appears only on key-down. Payloads are chunked on grapheme boundaries,
normally up to 20 UTF-16 units per event. The clipboard is untouched. A long
keystroke write is an ordered event sequence, so target app verification must
include long text and complex Unicode.

## Terminal input

Ghostty exposes its rendered terminal screen through Accessibility, including
output from programs such as Claude Code. That text and the terminal's selection
are separate from the command editor's prompt and caret. Treating a redraw as an
input edit would refuse dictation even when the user stayed in the same field.

The confirmed Ghostty terminal surface uses the opaque target guard. Application,
window, and focused surface checks still apply. Its native search and rename
fields keep exact value, caret, and selection checks, as do unconfirmed surfaces
and other applications.

The October 9 implementation acquires Epos as an exclusive keyboard input method
before streaming. Ghostty's legacy IMK wrapper can hide an absent composition and
cannot return the draft string. Epos now uses its uninterrupted input session and
the observed draft range for ownership, while preserving readable selection and
client checks. A synchronous event barrier covers Ghostty's mouse input, which
does not pass through the input-method callbacks.

An already selected Epos source with its underlying layout, or acquisition from
a keyboard layout, can accept unavailable initial marked metadata after actual
Epos activation. Acquisition from another keyboard input
method requires positively absent composition metadata. Known foreign marks
always refuse. Missing activation, an unavailable event barrier, or uncertain
cleanup uses the HUD or refuses delivery as appropriate. This does not turn an
unavailable range into proof of absence.

Ghostty's `insertText` consumes the preedit and delivers committed text without a
separate preview-clear command. Confirmed phrases leave preedit as recognition
finalizes them, so a long hold no longer recommits all its phrases on release.
Ghostty still redraws the unfinished phrase when it becomes terminal input; a
short hold with one phrase can therefore still show a native redraw. Its current implementation also requires a prior
native event. A newly launched background fixture can therefore acknowledge the
call without receiving bytes. The companion checks that the marked span was
consumed; a still-marked result is ambiguous and cannot trigger a second write.
Actual terminal bytes still require a live check.
No Ghostty patch, synthetic wake key, clipboard, corrective backspaces, or external
service is used. Switching the source only at fn press did not activate Ghostty
in the October 9 installed hold. Epos can adopt a source selected before dictation;
its actual client activation still gates every draft.

Steve confirmed live Ghostty streaming and text staying visible on release on
October 15 with signed build `67e89fe`, after reselecting Epos following the upgrade.
Recordings `73f924ce` and `1b99b83a` each acknowledged one native commit with no
preview cancellation or Unicode fallback. Their native commit calls took 4.0 and
5.9 ms. Terminal byte readback remains unavailable. Interruption, other host apps
and ordinary typing still need installed checks before replacement readiness can
be claimed. Concurrent additive input methods remain a limit.

Earlier observations are retained in the [feasibility record](../specs/inline-preview-feasibility.md)
and [session prototype](../specs/preview-session-prototype.md). July 31 dogfood
used fewer ownership checks. October 2 rendered one underlined Ghostty draft
with zero input bytes, then refused its unreadable content. October 8 background
probes stopped at client acquisition and sent no marks; they did not establish
Ghostty's rendering limits.

## Session ownership prototype

The [October 7 prototype](../specs/preview-session-prototype.md) tests ownership
through an uninterrupted input session. Its
[controlled runner](../probes/inline-preview/SESSION.md) is compiled only with
`EPOS_SESSION_PROTOTYPE` and accepts explicit experimental socket commands.
It pins the client and target, checks the reported draft range, and retires before
ordinary input passes through a synchronous event tap. Fn press and release are
exempt. Host callbacks, focus changes and connection loss also retire the pass;
a retired pass cannot send another draft or final text.

The first unavailable range requires a controlled empty fixture. Cancellation
can return to an unavailable marked range, so its acknowledgement establishes
the ordered native discard operation only. Native lifecycle checks exercise real
`NSTextView` updates, discards and English key events with simulated wrapper
readback. Actual Ghostty updates, cancellation, event coverage and final delivery
require a separate Cua run with terminal byte evidence. The October 9 production redesign replaces exact unreadable-text readback with
exclusive source acquisition and uninterrupted ownership; the experimental
fixture gates are not used by normal dictation.

The separate background rendering test keeps the agent workspace hidden. It
uses one fresh client, the disposable prompt's nonce and exclusive caret geometry
to address that prompt without asserting global foreground. Fixed draft updates,
cancellation and final delivery require screenshots and terminal byte evidence.
It reuses the lifecycle policy but does not install the global input barrier.
Its outcome cannot establish typing interruption or daily-use safety. See the
[background workflow](../probes/inline-preview/SESSION.md#hidden-workspace-rendering-run).

The October 7 and October 8 host preflights returned `trusted=false` for the
signed companion.
The experiment requires that process's Accessibility trust for its event tap.
Each run sent only the read-only preflight command, then immediately restored the
original companion. The bundle manifest, the three checked input settings,
keyboard and input-source metadata, and main Epos binary fingerprint matched
the initial state. The restored companion was running; main Epos was stopped
both before and after. No target commands or GUI actions ran in either experiment.
On October 8, the operator separately opened the `Privacy_Accessibility` settings
URL on the agent workspace. The pane was titled "Device Control and Data Access"
and showed Epos on and EposProbe off. No toggle was pressed. Ghostty draft
updates, cleanup, typing interruption, held fn and final delivery remain
unverified in this prototype. See the
[latest host preflight record](../probes/inline-preview/SESSION.md#october-8-host-preflight).

## Delivery evidence

The [native F5 comparison](../probes/native-dictation/README.md) measures Steve's
reported Apple Dictation streaming through a disposable AppKit callback trace and
a separate Ghostty raw prompt with timed byte counts. The former traces public
`setMarkedText`, `insertText` and `unmarkText` calls; the latter distinguishes
visible words from bytes delivered while Dictation remains active. Both save
metadata only. The native trial can use human speech or one short synthesized
English phrase through the physical speaker and microphone route. Its actual
callback model and Ghostty commit timing remain unverified until that run.
The operator must keep Dictation active until the raw fixture records its paused
phase and the byte count settles, then stop. One zero-count snapshot cannot
establish provisional rendering; raw timestamps measure receiver reads.

The October 1 review reproduced selection deletion using native NSTextView and
added selection, ownership, and superseded-connection safeguards. Run
`probes/inline-preview/verify` to compile the companion and exercise its native
safety checks. Those checks do not establish behavior in Electron, terminals,
or a live InputMethodKit session. Verify the current installed companion before
using inline preview for daily work.

Changed targets show `Not inserted`; missing Accessibility trust shows `No
access`. A successful backend call proves acceptance of the write operation.
For readable fields, Epos performs bounded exact readback of the inserted span
and logs matched, mismatched, or unavailable delivery. Opaque fields and replacing
selected text with identical text remain unverified by readback.

Unit tests use fake observers, transports, and backends. They exercise guard
decisions and ordering without delivering into real applications. Test the
installed app in every daily target with an empty field, existing text, selection
replacement, a moved caret, changed focus, long text, emoji, and companion failure.

## Evidence

Implementation lives in
[FinalTranscriptInsertion](../Sources/Epos/Inject/FinalTranscriptInsertion.swift),
[InsertionTargetGuard](../Sources/Epos/Inject/InsertionTargetGuard.swift),
[FinalTranscriptCommitRouter](../Sources/Epos/Inject/FinalTranscriptCommitRouter.swift),
[InlinePreviewSession](../Sources/Epos/Inject/InlinePreviewSession.swift),
[PreviewKeyboardSource](../Sources/Epos/Inject/PreviewKeyboardSource.swift),
[InlinePreviewTransport](../Sources/Epos/Inject/InlinePreviewTransport.swift), and
[TextInsertionBackend](../Sources/Epos/Inject/TextInsertionBackend.swift).
[ElectronAccessibilityWaker](../Sources/Epos/Inject/ElectronAccessibilityWaker.swift)
attempts to expose Electron's focused accessibility tree.

Tests cover [target guards](../Tests/EposTests/InsertionTargetGuardTests.swift),
[focus fallback](../Tests/EposTests/FocusedElementSearchTests.swift),
[focus signatures](../Tests/EposTests/InsertionTargetFocusSignatureTests.swift),
[Ghostty terminal delivery](../Tests/EposTests/GhosttyInsertionTargetTests.swift),
[preview lifecycle](../Tests/EposTests/InlinePreviewSessionTests.swift),
[native activation ordering](../Tests/EposTests/InlinePreviewAcquisitionTests.swift),
[keyboard-source restoration](../Tests/EposTests/PreviewKeyboardSourceTests.swift),
[release without throttle delay](../Tests/EposTests/InlinePreviewFinalPreparationTests.swift),
[single baseline settlement](../Tests/EposTests/InlinePreviewSettlementTests.swift),
[empty preview updates](../Tests/EposTests/InlinePreviewEmptyTests.swift),
[preview callback isolation](../Tests/EposTests/InlinePreviewCoordinatorTests.swift),
[final preview safety](../Tests/EposTests/InlinePreviewFinalSafetyTests.swift),
[socket failures](../Tests/EposTests/InlinePreviewTransportTests.swift), and
[commit routing](../Tests/EposTests/FinalTranscriptCommitRouterTests.swift).
[Ambiguous delivery tests](../Tests/EposTests/CoordinatorAmbiguousDeliveryTests.swift)
model an IME write that lands before its acknowledgment disappears, then verify
the notice remains visible through recording teardown without another write.
The [feasibility spec](../specs/inline-preview-feasibility.md) and
[companion README](../probes/inline-preview/README.md) retain historical per-app
observations, which require rechecking after changes.
