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

The prototype must pin the controller, client, connection, and target. It must
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
