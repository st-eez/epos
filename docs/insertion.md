# Insertion

Epos captures the destination at shortcut press and authorizes one final write after
release. Provisional text may appear while recording through the companion input
method. The final path either commits through that companion or posts Unicode
keystrokes.

## Stream into field

Stream into field defaults on. A companion palette InputMethodKit bundle in
`~/Library/Input Methods/EposProbe.app` receives preview commands over a per-user
Unix socket. It renders the same cleaned provisional transcript as marked text
in the captured application's field. Updates are coalesced to at most one per
100 ms. The normal keyboard layout remains the user's layout.

Each update supplies the complete current provisional transcript to
`setMarkedText`, replacing Epos's owned preview span. Existing text around that
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
failed channel restores the recording pill and its transcript for that hold.
The menu toggle can disable inline preview.

Preview is skipped when the captured target has selected text. Before every mark,
the companion also requires a readable empty selection and checks composition
ownership against the recorded marked range and text. Unknown selections and
ambiguous sets of client sessions use the HUD.
This prevents cancellation from deleting a selection that marked text replaced.

Each pass pins its concrete input client and command connection. Superseded
commands cannot mutate a newer pass, and cleanup addresses only the recorded
client. A stale record cannot authorize changing another input method's live
mark. An unreachable owner is refused instead of redirecting cleanup into a
different field in the same application. Provisional text is discarded before
either final delivery path authorizes a write. Marked text still requires
verification in each target app because rendering and teardown are host dependent.

## Final delivery

The captured target guard checks the application and field. Where Accessibility
exposes an editable text context, it also requires the original value, caret, and
selection. Opaque targets use process, window, and focus signature evidence. An absent or changed
target refuses delivery. Epos does not restore focus or undo the user's edits.

A healthy preview channel that acknowledged at least one mark can receive the
final transcript through a single IME `insertText`. Epos first cancels the marked
composition, waits for the readable baseline to settle, and runs the same target
guard as the keystroke path. Text containing a newline uses the keystroke path.

A foreign composition or a changed selection detected after preview blocks both
final delivery paths and shows `Not inserted`. Unconfirmed preview cleanup also
blocks delivery, because an opaque target cannot prove the composition is gone.
Other conclusive commit refusals or commands that could not be sent completely
can fall back to guarded keystrokes. If the complete command was
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

Inline preview still requires a readable empty selection and provable composition
ownership through the companion. A first refused mark uses the overlay and
guarded final delivery.

On October 2, the live IMK client for installed Ghostty revision `33da6848d`
reported selection `{0, 0}` and marked range `{NSNotFound, NSNotFound}`. The
marked range is unavailable, so Epos cannot prove composition ownership in that
build and keeps preview in the overlay. Ghostty's direct `NSTextInputClient`
implementation does not establish what its legacy IMK wrapper exposes. The
terminal screen fix permits guarded final delivery without waiving preview
safety. Steve confirmed final delivery into Ghostty's Claude Code prompt with the
installed Release build, while preview remained in the overlay.

An isolated native test on October 2 reproduced the legacy wrapper's unavailable
marked range with both active foreign marked text and a cleared composition. A
view matching Ghostty's separate preedit storage reported a concrete marked
range directly, while its IMK wrapper returned the unavailable range. An empty
selection therefore cannot establish that it is safe to begin or clear a mark.
The companion safety checks cover this refusal. The fixture does not certify
rendering or cancellation in Ghostty itself.

The July 31 feasibility record describes successful inline preview in
cmux/Ghostty, and retained companion logs contain accepted Ghostty mark calls.
That implementation sent marks without the current selection and live ownership
checks. The current preview path requires the bridge to expose composition
absence and exact live ownership. The selection guard independently prevents the
native selected-text deletion reproduced in the audit. Relaxing unavailable
ownership metadata while retaining that guard does not remove selection protection.

An October 2 native English comparison relaxed only the unavailable marked-range
state, retaining the readable empty selection requirement. It used real
`NSTextView` writes with simulated bridge readback. A deliberately staged
different English mark was overwritten and discarded. Ordinary typing and
Backspace ended the original draft; a later update, cancellation, and final
insertion left old draft text beside the final transcript. These checks excluded
the companion's host callbacks and do not establish the same behavior in Ghostty.

A bounded live Ghostty probe then allowed only the unavailable marked-range state
in a disposable English prompt. The first underlined draft rendered directly in
the terminal and delivered zero input bytes. After that mark, the IMK wrapper
reported a concrete range `{0, 16}`, but its text readback remained unreadable.
The same narrow relaxation refused the next update and cancellation; the first
draft remained visible after restoring the original companion. Cua Escape later
removed it without delivering input bytes. This verifies initial rendering and
that explicit Escape action.

A further scratch policy permits unreadable content only when the concrete range
matches the recorded Epos range and pinned client. Its live retries sent zero
marks: one had no newly activated IMK client, and the next stopped during Cua
focus setup before creating a fresh terminal tab. Continued streaming, companion
cleanup, final commit, and English typing interruption remain unverified in the
current Ghostty build.

## Delivery evidence

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
[InlinePreviewTransport](../Sources/Epos/Inject/InlinePreviewTransport.swift), and
[TextInsertionBackend](../Sources/Epos/Inject/TextInsertionBackend.swift).
[ElectronAccessibilityWaker](../Sources/Epos/Inject/ElectronAccessibilityWaker.swift)
attempts to expose Electron's focused accessibility tree.

Tests cover [target guards](../Tests/EposTests/InsertionTargetGuardTests.swift),
[focus signatures](../Tests/EposTests/InsertionTargetFocusSignatureTests.swift),
[Ghostty terminal delivery](../Tests/EposTests/GhosttyInsertionTargetTests.swift),
[preview lifecycle](../Tests/EposTests/InlinePreviewSessionTests.swift),
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
