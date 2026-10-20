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

## Result

The October 19 run retained the production preset. Neither candidate met the
predeclared development gate, so no candidate was frozen and the holdout stage
was not run.

All 210 trials completed across 35 development recordings, three arms and two
repeats. Each arm and repeat covered the same 478 reference words. There were no
failed or empty outputs, audio frame mismatches, or context readback mismatches.
The evaluator used committed source `e52461e`, a clean optimized Debug build with
`-O` for both the app and library. Every trial used that executable. The normal
installed app remained Release source `04d95fd` after restoration.

| Configuration | Cleaned errors, repeat 1 / 2 | Raw errors, repeat 1 / 2 | Paired median first-useful delay versus baseline, repeat 1 / 2 |
| --- | --- | --- | --- |
| Production preset | 3 / 3 | 29 / 29 | Reference |
| Without fast results | 5 / 5 | 22 / 22 | +1,910.15 ms / +1,904.06 ms |
| Without confidence attributes | 3 / 3 | 29 / 29 | -0.15 ms / -1.25 ms |

These delays are medians of differences for matched recordings. They are not
computed by subtracting each arm's overall median. The clock includes the saved
audio leading up to the first useful recognition result. It does not measure
field insertion or screen paint.

Removing fast results improved the raw word-error count but increased errors
after production corrections and cleanup. Two recordings regressed in each
repeat. Its first-useful latency difference had a 95% recording-cluster bootstrap
interval from +1,197.00 to +2,809.52 ms. It failed both accuracy and speed gates.

Removing confidence attributes preserved cleaned accuracy and had no recording
regressions. Its corresponding interval was -2.41 to +0.70 ms, crossing zero.
The paired median changes were below the required 50 ms and 5% improvement in
both repeats. It failed both gain gates.

Both candidates passed the completion-after-release tail gate. The p95 change
without fast results was -7.90 ms and +9.25 ms across the two repeats. Without
confidence it was -13.70 ms and +5.28 ms. These use actual release timestamps;
they do not use the older summary's scheduled-release metric. No memory gain is
claimed from host RSS samples, which omit the Speech service and reflect process
warmup and shared allocations.

## Verification and artifacts

The background runner restored the original signed app after the development
stage. Full file manifests for the app and companion matched their saved copies,
both signatures verified, and a normal Epos process was running without the
evaluation environment variable. The app executable hash matched its value
before the experiment. The companion was not replaced or restarted. Kosmos
reported that neither launch created a window; no window location was available.
The evaluator fed saved buffers directly and exited before normal app startup.
There was no microphone capture, audio playback, or UI interaction in the run.

Private run artifacts are under `.build/recognition-ab-20261019/` and stay out of
Git. `development.jsonl` contains the 210 measurements and recognition timelines.
`development-analysis.json` contains the paired gates and bootstrap results.
`run-stage.py` and `analyze.py` reproduce the orchestration and analysis.
`development-outcome.json` and `restoration-verification.json` record restoration.
The `review/` folder holds proof output and the answered independent reviews.

Deep review covered the temporary installed-app swap. The walk and simplify
findings were fixed, code review finished clean, and the preflight ready check
passed. Fault checks covered interrupted restoration and changed holdout controls.
All seven repository proof commands passed. Swift reported 534 main tests with
four opt-in skips and zero failures, plus 14 evaluator tests with zero failures.
Build, lint, audit self-test, signed-installer checks, inline-preview checks and
the stopped-engine audio-input checks passed.

These results apply to this saved corpus and optimized evaluation build. They do
not establish fresh microphone behavior, native inline delivery, or latency in a
Release recording session. No candidate reached the conditional recognition-event
replay or holdout stage. Other recognizers, vocabulary changes and capture-path
optimizations remain separate experiments.
