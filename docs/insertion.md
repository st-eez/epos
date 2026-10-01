# Insertion

Epos captures the destination at fn press and authorizes one final write after
release. Provisional text may appear while recording through the companion input
method. The final path either commits through that companion or posts Unicode
keystrokes.

## Stream into field

Stream into field defaults on. A companion palette InputMethodKit bundle in
`~/Library/Input Methods/EposProbe.app` receives preview commands over a per-user
Unix socket. It renders the same cleaned provisional transcript as marked text
in the captured application's field. Updates are coalesced to at most one per
100 ms. The normal keyboard layout remains the user's layout.

The signed app installer installs the companion in lockstep with Epos. The local
installer leaves it uninstalled. The companion needs live registration and input
source consent. A missing companion, unidentified target, refused focus lock, or
failed channel restores the recording pill and its transcript for that hold.
The menu toggle can disable inline preview.

The companion owns teardown of its composition when the command connection ends
or the client session deactivates. Provisional text is discarded before either
final delivery path authorizes a write. Marked text must be verified in each
target app because its rendering and teardown are host dependent.

## Final delivery

The captured target guard checks the application and field. Where Accessibility
exposes text, it also requires the original value, caret, and selection. Opaque
targets use process, window, and focus signature evidence. An absent or changed
target refuses delivery. Epos does not restore focus or undo the user's edits.

A healthy preview channel that acknowledged at least one mark can receive the
final transcript through a single IME `insertText`. Epos first cancels the marked
composition, waits for the readable baseline to settle, and runs the same target
guard as the keystroke path. Text containing a newline uses the keystroke path.

If the companion explicitly refuses the commit or the command could not be sent
completely, Epos can fall back to guarded keystrokes. If the complete command was
sent and its acknowledgment is lost, delivery is ambiguous. Epos suppresses a
second write to avoid duplicated text. The current implementation records this
as `ime-commit-unacknowledged` without a user-facing refusal notice.

The keystroke backend uses private Unicode keyboard events with cleared modifier
flags. Text appears only on key-down. Payloads are chunked on grapheme boundaries,
normally up to 20 UTF-16 units per event. The clipboard is untouched. A long
keystroke write is an ordered event sequence, so target app verification must
include long text and complex Unicode.

## Delivery evidence

The current review reproduced a selection-loss bug in the companion path:
placing marked text over an existing selection and then cancelling it can delete
the original selection. Cleanup can also address a different field in the same
application after the original client session changes. These are open review
findings; the target guard on final delivery does not restore text already
changed by preview. Verify their fixes before using inline preview for daily
work.

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
[preview lifecycle](../Tests/EposTests/InlinePreviewSessionTests.swift),
[socket failures](../Tests/EposTests/InlinePreviewTransportTests.swift), and
[commit routing](../Tests/EposTests/FinalTranscriptCommitRouterTests.swift).
The [feasibility spec](../specs/inline-preview-feasibility.md) and
[companion README](../probes/inline-preview/README.md) retain historical per-app
observations, which require rechecking after changes.
