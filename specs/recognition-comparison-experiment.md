# Silent recognition comparison

October 19, 2026. Production baseline `04d95fd`.

## Question and scope

Does removing fast results improve accuracy enough to keep streaming responsive?
Does omitting unused confidence attributes improve recognition latency?
The experiment changes only DEBUG evaluation code until a candidate clears the
criteria below. It uses saved, human-confirmed audio directly, without microphone
capture, playback, application focus changes or text insertion. Restore the
previous signed normal app after each evaluation stage, including failure.

The existing preset comparison supplies vocabulary only to its production arm.
Its other arms are unhinted controls and cannot isolate the effect of a preset.
This comparison supplies the same frozen vocabulary to every arm and verifies
the analyzer's context readback for each trial.

## Arms and controls

- `unprepared` uses the production preset and lifecycle.
- `no-fast-results` removes only `fastResults`, retaining volatile streaming and confidence.
- `no-confidence` removes only `transcriptionConfidence`, retaining both reporting options.

Every arm uses a fresh analyzer. Convert each recording once per repeat, then
reuse those buffers and their audio-rate deadlines in every arm. Verify audio
hashes and expected, submitted and consumed frame totals. Vocabulary, locale,
dictionary and cleanup stay identical. Rotate arm order by recording and repeat.
Record the first trial; system Speech service coldness remains unknown. Use one
optimized signed evaluation executable for every arm and inspect its build
metadata. An optimization level mismatch invalidates a production speed claim.

Start with all 35 confirmed development recordings and two repeats. Do not inspect
held-out error text while selecting a candidate. Freeze the selected candidate
before evaluating it against baseline on all 40 held-out recordings, twice.
This existing holdout is a regression check, not newly collected independent data.

## Measures and decision criteria

Measure first nonempty raw result, first result that survives production
corrections and cleanup, completion after actual input release, raw and cleaned
word errors, missing outputs, frame counts and memory samples. The first-result
clock includes the file's leading silence and spoken audio. Paired comparisons
use the same recording and repeat; they do not treat that interval as computation.
Do not call recognizer completion field delivery or screen paint.

Any failed, empty, truncated or context-mismatched trial blocks promotion. Every
paired recording must avoid a cleaned word-error regression in both repeats.
An accuracy candidate must reduce total cleaned word errors in each repeat while
adding at most 50 ms to paired median first-useful-result latency. A speed
candidate must improve that paired median by at least 50 ms and 5% of baseline
median in each repeat. The upper bound of a 95% bootstrap interval, resampling
recordings as clusters across repeats, must also remain below zero. Both types
must avoid increasing p95 completion-after-release latency by more than 25 ms
in either repeat. These are conservative experiment thresholds, not measured
human perception limits or existing product guarantees.

Choose among eligible candidates by cleaned error reduction, then first-useful
latency improvement. Repeat the same criteria on the frozen holdout. If no arm
qualifies, retain production unchanged. If one qualifies, replay its recorded
recognition events through the existing recording-session replay check to catch
phrase-commit correction regressions before changing production. Native screen
and microphone checks remain deferred under Steve's current constraint.

## Reproduction

The existing analyzer evaluation host accepts a comma-separated `EPOS_PREPARE_ARMS`
list and `EPOS_EVAL_DESIGNATION=legacy` or `holdout`. Without these options its
preparation experiment retains the original three arms and corpus selection.
`EPOS_PREPARE_ONLY_ARM` remains supported; specifying both arm selectors fails.
The same corpus ledger must still contain all 75 confirmed entries.

For the development stage, launch the installed signed evaluation build with
`EPOS_RUN_ANALYZER_PREPARATION_EVAL=1`,
`EPOS_PREPARE_ARMS=unprepared,no-fast-results,no-confidence`,
`EPOS_EVAL_DESIGNATION=legacy`, `EPOS_EVAL_LIMIT=35`,
`EPOS_PREPARE_REPEATS=2` and explicit corpus and output paths.
Use unique output files. The rows include preset arm, dictionary snapshot,
context readback, source and executable provenance, timing and actual recognition
events. Private recordings, references and artifacts stay outside Git.

This does not evaluate other recognizers, vocabulary changes, long-form accuracy,
background noise, microphone routing, field rendering or native insertion.
Those require separate evidence if the current candidates do not help.
