# Selective phrase commit deferral

October 16, 2026. Follow-up to the [optimization investigation](optimization-2026-10-16.md).
Baseline source is `8bb7efb`, whose executable sources match `46f480a`.

The guard fixes the constructed correction-boundary regressions, but this actual
recognition replay measured no accuracy gain. All 75 delivered transcripts and
all 1,430 event display texts were identical between versions. Full-corpus display
processing stayed below one millisecond at p95; native screen latency remains
unverified.

## Change

Before a held native phrase commit, Epos checks the uncommitted raw suffix against
prefixes compiled from the recording's frozen correction dictionary. It keeps
that phrase marked when it ends with an incomplete alias, a full ambiguous name
alias needing following context, or a spoken `dash` awaiting continuation.

Display publication and preview mirroring happen before this check. A subsequent
safe final commits the accumulated phrase. Release resolves the remainder through
the existing guarded delivery path. Previously committed text remains immutable,
and lost acknowledgments still suppress further writes.

The policy is the same one frozen before the earlier artificial-boundary holdout.
It does not add a debounce interval, change recognition, add aliases, or tune the
policy against the actual-event holdout. It can conservatively keep a completed
phrase provisional when its last word happens to begin a dictionary alias.

## Actual recognition capture

The installed, development-signed Debug evaluation host replayed the 75 confirmed
WAVs at their audio rate with the production Speech preset and frozen dictionary.
All source WAV hashes matched the confirmed ledger. All 75 trials succeeded;
expected, submitted and consumed audio-frame counts matched in every trial.

The 352.5 seconds of audio produced 1,430 partial/final events. Sixteen final events
arrived before release. The artifact records each event's original text, finality
and receipt time, plus the actual release time. No event boundary was invented or
moved to create a correction failure. Capture uses the existing saved-audio feeder;
its buffer cadence can differ from live microphone capture.

The daily app was backed up before the temporary capture installation, then
restored and relaunched. Its restored executable SHA-256 matched the original.
The companion input method and system services were not replaced or restarted.

## Replay method

Both versions use the same capture artifact, dictionary and references. Each runs
through `RecordingSession`, the preview coordinator, native commit routing and an
acknowledged fake transport at the captured event and release times. Both test
bundles use `-O` with `-DDEBUG` to retain the evaluation helpers. Baseline source is
an isolated archive, with no candidate switch added to the application.

Each replay validates the capture before writing results. It reconstructs the
accepted transcript from `seal` and `commit` payloads, requires it to equal final
display text, and checks that no keystroke fallback occurred. The reported word
errors score these reconstructed payloads against human-confirmed references.
Timing records both synchronous event-to-display work and publication relative
to the original schedule, plus the first preview command.

These timings measure software publication and transport scheduling. The fake
acknowledgment does not measure InputMethodKit, application redraw or Ghostty
screen latency. No current target-app acceptance claim follows from this replay.

## Paired results

Both optimized replay tests passed with no delivery assertion failures. The
actual capture contained 16 finals before release across 12 recordings. Neither
version introduced a phrase-boundary error relative to whole-utterance cleanup.

| Sample | Recordings | Reference words | Baseline word errors | Candidate word errors | Exact recordings, both |
| --- | ---: | ---: | ---: | ---: | ---: |
| Development | 35 | 478 | 3 | 3 | 32 |
| Holdout | 40 | 485 | 6 | 6 | 35 |
| Total | 75 | 963 | 9 | 9 | 67 |

Both versions scored 0.935% word error rate. No recording improved or regressed.
The earlier artificial-boundary improvement therefore remains a regression-test
result, not a demonstrated accuracy improvement on actual recognition events.

| Software timing | Baseline median | Candidate median | Baseline p95 | Candidate p95 |
| --- | ---: | ---: | ---: | ---: |
| Event handling to display publication | 0.355 ms | 0.380 ms | 0.976 ms | 0.994 ms |
| Complete event handling, including commit checks | 0.378 ms | 0.400 ms | 1.044 ms | 1.056 ms |
| First preview command after hold start | 1,202.50 ms | 1,201.12 ms | 2,143.00 ms | 2,142.94 ms |

The candidate added 0.025 ms to median synchronous display processing and
0.018 ms at p95. Paired first-preview time changed by -0.125 ms median and
+38.005 ms p95. Paired publication time changed by -0.142 ms median and
+39.957 ms p95, with a maximum of +102.235 ms. These schedule-relative differences
include timer wakeup and host scheduling variation. Each version ran once,
baseline first, so this experiment cannot attribute the tail variation to the
guard or establish native latency equivalence.

The baseline sealed 16 phrases; the candidate sealed 15. On the single changed
development recording, the guard conservatively deferred a final ending in `it?`,
whose normalized last word begins a dictionary alias. Permanent insertion moved
from 5,081.28 ms to 8,312.24 ms after hold start, 3,230.96 ms later. Release occurred
at 8,200.46 ms. Eight preview commands continued during that interval, and every
display publication matched the baseline. This delay buys editability but did
not improve this recording's text.

### Timing follow-up

The original full-corpus replay used the clock's default sleep tolerance. To
reduce avoidable wakeup slack, the final replay harness requests zero tolerance
at the same absolute deadlines. Production code and captured events are
unchanged. The affected recording was then replayed in six paired trials, with
baseline/candidate order alternating between pairs. All 12 tests passed, and all
48 event display texts and final deliveries matched in each pair.

| Timing on the affected recording | Baseline median | Candidate median | Baseline p95 | Candidate p95 |
| --- | ---: | ---: | ---: | ---: |
| Event handling to display publication | 0.474 ms | 0.450 ms | 1.114 ms | 1.057 ms |
| Scheduled event to publication | 3.747 ms | 4.277 ms | 7.240 ms | 7.215 ms |

Paired first-preview differences had a median of +0.168 ms and ranged from
-0.935 ms to +2.424 ms. Across 288 matched publications, the median difference
was +0.287 ms, p95 was +3.385 ms, and the maximum was +5.614 ms. This supports
no material software timing regression in the affected recording. It is six
repeats of one recording, not six independent recordings or a native screen test.
Zero sleep tolerance still permits scheduler delay.

## Regression checks

The full Swift suite completed 533 tests: 529 passed and four opt-in evaluations
skipped. The focused optimized run completed 19 tests: 18 passed and one replay
skipped before the capture existed. The two new correction regression tests fail
against the old source and pass with the guard. They cover aliases split across
multiple finals,
a preceding committed phrase, Unicode offsets, following name context, spoken
flags, continuing preview and release with an unresolved suffix.

The signed Debug build, warnings-as-errors build, SwiftLint, audit self-test,
signed-installer checks, companion checks and stopped-engine input-routing probe
passed. Independent Ponytail and correctness reviews completed. The former's
capture-validation concern was fixed before the correctness review.

## Evidence and reproduction

Private artifacts live under `.build/phrase-deferral-20261016/` and stay outside
Git. `recognition-events.jsonl` contains the signed capture. `baseline-replay.jsonl`
and `candidate-replay.jsonl` contain the paired deliveries and timing records.
`provenance.json` records source hashes and signed-build metadata. The archive,
runner, comparison script, logs and original app backup are retained there.
`comparison.json` contains the aggregate results. The shared capture's SHA-256 is
`5c5f5aff93483b308696e9055f3e743c9cf8b529e0b9068ee32f4dcb9cac1394`.
`precise/` and `precise-comparison.json` retain the alternating timing follow-up.
The provenance distinguishes the original test source from the three subsequent
sleep-tolerance changes. The correctness reviewer also checked those changes.

The [capture workflow](../specs/analyzer-preparation-experiment.md#reproduction)
uses `EPOS_EVAL_LIMIT=75`, `EPOS_PREPARE_REPEATS=1` and
`EPOS_PREPARE_ONLY_ARM=unprepared`. Replay runs
`RecognitionEventReplayTests.testCapturedRecognitionEvents` with
`EPOS_RECOGNITION_REPLAY_INPUT` and `EPOS_RECOGNITION_REPLAY_OUTPUT` pointing to
absolute local files. Use a fresh output path for each version and run versions
sequentially. Direct XCTest invocation should use a minimal environment.
