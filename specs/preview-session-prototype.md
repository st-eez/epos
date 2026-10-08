# Preview session ownership prototype

Date: 2026-10-07. Experimental, outside normal dictation.

## Problem

Ghostty displayed the first synthetic Epos draft in the October 2 probe. Its IMK
client then reported the draft range but did not return the draft text. Epos's
exact ownership check refused subsequent updates and cancellation. Historical
success and initial rendering do not establish correct teardown or final delivery.

## Experiment

Test whether an explicitly owned, uninterrupted input session can update and
discard its draft without reading the exact marked string. Reuse the companion,
socket, native text input operations, and existing target guards. Keep the normal
protocol and installed app behavior unchanged unless the experiment is explicitly
selected. Do not add a Ghostty patch or another runtime dependency.

The ownership test must pin the controller, client, connection, and target. It must
retire a pass on ordinary typing, caret or mouse interaction, focus movement,
controller teardown, connection loss, or ambiguous cleanup. Retired passes must
not restart marking or authorize a final write. Keep readable selection and
target checks. Exempt only the hold modifier from typing interruption; test its
behavior explicitly. An empty selection alone does not prove that no composition
exists, so the live experiment begins in a disposable, controlled empty prompt.

Determine which events the actual IMK client supplies. Do not assume that host
callbacks cover every edit, or that a saved client identity proves ownership.
If event coverage or cleanup cannot be established, record the failed condition
and retain the prototype as an experiment.

## Background rendering test

Added 2026-10-08. Steve requires the agent workspace to stay hidden. A separate
explicit test may address a disposable Ghostty client in the background through
the existing companion socket and native marked-text calls. It must not show the
workspace, activate an app, restore focus or send foreground input.

Pin one fresh client after a snapshot and one connection. Require a live empty
raw fixture, its synthetic nonce in the owned AX window title, unchanged target
geometry and readable empty selection. The client caret must intersect only the
owned window among all Ghostty windows, including hidden windows. Refuse missing
clients, overlap, stale fixture metadata, nonzero input bytes and controller
teardown. The public IMK client supplies no process or window identifier, so
bundle identity alone cannot authorize this test.

Reuse the lifecycle policy for ordered draft replacement, cancellation and final
delivery. Accept only the fixed alpha, beta and final tokens. This background
test omits the foreground and global event barrier requirements. Its evidence
can establish rendering, replacement, cancellation and exact delivery through
the addressed client. It cannot establish keyboard interruption, held fn, focus
changes or uninterrupted ownership. Keep the ownership test and production
checks separate. If background interaction cannot establish the owned client,
report that failed prerequisite.

## Verification

Use synthetic English text, without microphone capture or recording cues. Cover
draft A, revised draft B, cancellation with zero terminal bytes, and one exact
final payload. Test ordinary typing, Backspace, caret movement, focus change,
held fn, and connection loss where the live setup permits them. Measure actual
terminal input and inspect screenshots independently of acknowledgments.

Run meaningful native regression checks and compile with warnings as errors.
Review the final implementation independently. Live testing uses Cua and a
disposable Ghostty prompt; restore the signed companion and Epos afterward.
Report unavailable checks separately from passing checks. Promotion into normal
dictation requires a new scope decision and real host evidence.

## Native Dictation comparison

Added 2026-10-07. Steve reports that F5 Apple Dictation streams directly into
Ghostty. Establish this native baseline separately from the synthetic
session prototype, whose commands use no microphone.

Build a disposable AppKit text fixture using an `NSTextView` subclass. Record only
public text-input callback names, UTF-16 lengths, selection and marked ranges,
and relative timestamps for `setMarkedText`, `insertText` and `unmarkText`.
Display the input and metadata trace locally so Steve can dictate a known
synthetic phrase. Do not retain dictated text or microphone audio in evidence, inspect arbitrary
preferences, install an app or change the production companion. Launch the
temporary fixture through `kosmos open` only when the GUI operator runs it.

For Ghostty, reuse the disposable raw terminal fixture with byte-count and fixed
phrase-equality metadata. Add manual phase markers if needed to distinguish
visible provisional text from bytes delivered before dictation ends. Steve can
operate native Dictation. An automated attempt may use Cua and one short,
locally synthesized English phrase played through the speakers into the physical
microphone. Record that audio route separately from a human speech trial. The
fixture itself calls no microphone or speech recognition API.
Keep Dictation active until the raw fixture records the paused phase and its byte
count settles across successive reads, then stop Dictation. Writing the phase
file alone does not establish that ordering. Raw timestamps measure when the
fixture reads queued input, not native commit or recognition timing.

The AppKit callback trace describes that fixture's public boundary. It cannot
prove the exact Ghostty callback path or Apple's internal delivery architecture.
Combine its trace with independent Ghostty screenshots and timed terminal counts.
Keep observed native behavior, synthetic callback checks and source research
separate. Actual native Dictation, Ghostty timing and interruption remain
unverified until the controlled native run completes.
