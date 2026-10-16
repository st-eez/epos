# Epos performance and accuracy investigation

October 16, 2026. Source revision `46f480a`. Investigation and recommendations only.

The strongest accuracy candidate is to defer native phrase commits when a
correction still needs the next words. The next performance experiment is to
reduce actual audio delivery intervals. No live speed gain or current production
WER improvement was established. The existing evidence does not justify a
recognizer switch, analyzer prewarming, or a cleanup rewrite.

## 1. Preserve corrections across recognition phrase boundaries

`RecordingSession.commitConfirmedPhraseIfHeld()` freezes both corrected text and
the raw offset after an acknowledged phrase commit. Later renders run
`canonicalizeSuffix` after that offset. `CorrectionRuleMatcher` rejects a match
that begins before it. This deliberately protects committed text, but also loses
corrections that need words from the next recognition segment.

Context can matter even for a single-word alias. The person-name matcher reads
following words to accept or reject a name interpretation. Committing before that
context arrives can preserve a missed correction or an unwanted correction.

Controlled examples through the actual recording and insertion classes, using
fake audio and an acknowledged fake native transport, reproduced these results.
The name rule in the examples is synthetic.

| Recognizer finals, separated by a bar | Current committed output | Whole-utterance output |
| --- | --- | --- |
| `Use dash` \| ` dash fix.` | `Use dash dash fix.` | `Use --fix.` |
| `Mark` \| ` pushed the fix.` | `Mark pushed the fix.` | `Marco pushed the fix.` |
| `Ask mark` \| ` by tomorrow.` | `Ask Marco by tomorrow.` | `Ask mark by tomorrow.` |

The experiment split each saved raw development transcript at every internal
whitespace position. Each split represents two artificial recognition finals,
with the first eligible for commitment while held. This is a boundary stress
test, not a measurement of Apple's actual segmentation or user error frequency.

The test-only candidate checks the available prefix before committing. It defers
when the ending matches a proper prefix of a dictionary alias, a complete
person-name alias that may need following context, or a trailing `dash`. The
phrase remains marked and visible. The next final or release supplies the
remaining context. No production code was changed.

| Measurement | Development | Frozen holdout |
| --- | ---: | ---: |
| Recordings | 35 | 40 |
| Artificial boundaries | 451 | 450 |
| Current outputs differing from whole-utterance processing | 37, across 12 recordings | 3 |
| Current boundaries with more word errors than whole-utterance processing | 36 | 2 |
| Candidate outputs differing from whole-utterance processing | 0 | 0 |
| Candidate improvements over current boundary behavior by word-error score | 36 | 2 |
| Candidate regressions by word-error score | 0 | 0 |
| Boundaries where the candidate deferred commitment | 111 | 75 |

All candidate routes were accepted by the fake native transport. Verification
also reconstructs the delivered string from `seal` and `commit` payloads and
checks it against the displayed final transcript. Existing phrase-commit safety
tests passed. These checks do not establish real InputMethodKit delivery.

The policy was frozen before the holdout run. Only aggregate holdout results
were inspected. Current whole-utterance transforms reproduce all 75 historical
production outputs, and the stored 46-record dictionary is identical to the
replay snapshot. The difference is attributable to the imposed commit boundaries
within this controlled experiment.

**Recommendation.** Implement and evaluate selective commit deferral before
adding more aliases. Start with the small policy above and keep text streaming
as marked text. The implementation must preserve ownership checks, cancellation,
lost-acknowledgment handling, and the rule against rewriting committed text.
Read the product specification before changing its explicit phrase-boundary
contract.

**Expected benefit and cost.** The tests show recoverable correction errors, not
a measured live WER reduction. Delaying whole phrases is conservative and can
delay permanent commitment unnecessarily. It deferred 24.6% of artificial
development boundaries and 16.7% of holdout boundaries. Actual frequency and
delay remain unknown. Implementation cost is modest; verifying the streaming
tradeoff is the main work.

**Decisive next check.** Replay timestamped partial/final events from the same
audio through current and candidate recording sessions. Preserve event boundaries,
release timing, dictionary and audio hashes. Score the concatenated accepted
commits, measure how much longer text remains provisional, and then check the
native result in a controlled Ghostty field. Freeze the candidate before a fresh
holdout comparison. The artificial-boundary result does not replace the signed
production promotion gate.

## 2. Test actual audio delivery cadence for first-text latency

Seven completed, acknowledged native recordings from October 15 provide a small
sample after the current timeout fix. They include five Codex and two Ghostty
recordings. The selection excludes refusals and empty recordings, so it cannot
estimate reliability. Timings below describe those seven successful paths.

| Boundary | Median | Descriptive p95 |
| --- | ---: | ---: |
| Microphone opening | 66.1 ms | 104.8 ms |
| Analyzer startup | 0.5 ms | 5.2 ms |
| Recording-session start to first recognizer result | 1,206.6 ms | 2,085.8 ms |
| First recognizer result to display publication, paired within recording | 0.45 ms | 1.10 ms |
| Display publication to first mark acknowledgment, paired within recording | 16.9 ms | 18.4 ms |
| Release to recognizer completion | 144.7 ms | 183.1 ms |
| Final transcript cleanup | 0.14 ms | 0.35 ms |
| Final IME commit | 2.0 ms | 3.0 ms |
| Release to accepted final write | 159.7 ms | 189.3 ms |

These are software boundaries. They do not measure physical shortcut delivery,
speech onset, or screen paint. The interval before the first result includes the
user's speech and any silence, so it is not all avoidable recognizer computation.
The seven-sample p95 values are descriptive, not population tail estimates.
All seven final writes lacked independent field readback.

`AudioCapture` requests 4,096 input frames per tap. Reliability counts for the
same recordings imply about 99.4 to 100.0 ms of converted audio per callback at
16 kHz. The observed interval matters more than interpreting the requested tap
size as an achieved hardware interval. No startup truncation or input overflow
was observed in this selected sample.

**Recommendation.** Run a bounded paired experiment with smaller requested tap
sizes, verifying the actual delivered frame sizes first. Compare the existing
request with 2,048 and 1,024 frames on the same input route. Keep the recognizer
preset, dictionary, audio content and release schedule fixed. Randomize trial
order and repeat trials with explicit warm/cold conditions.

**Expected benefit and cost.** This may reduce the batching portion of first-text
delay. No gain has been measured, and macOS may deliver the same buffers despite
a smaller request. The change itself is small. More callbacks can increase CPU
and allocation cost, and altered boundaries must not lose frames or change
recognition. Do not attribute the entire 1.2-second interval to this setting.

**Decisive next check.** Require a real reduction in delivered buffer duration,
then compare speech-onset-to-first-useful-result and release-to-stable-field
latency. Check input/submitted/consumed frame totals, raw and delivered accuracy,
CPU and memory. Stop if the callback cadence is unchanged. Saved-audio pacing
can isolate recognizer sensitivity, but only native capture verifies the tap
change. Keep native IME evidence separate from fallback keystrokes.

## Evidence that narrows the work

The rebuilt corpus ledger still contains 682 recordings, of which 75 are
human-confirmed. All 75 original WAV hashes match the signed replay artifact.
The historical production arm has 44 raw word errors and 9 cleaned word errors
across 963 reference words, or 0.9346% cleaned micro WER. Cleanup improves 20
recordings and regresses none. There are 67 exact normalized transcripts.

Those recordings total only 352.5 seconds. All confirmed audio dates from June
or July. The holdout has 485 reference words and no recording longer than 9.9
seconds. It cannot establish current long-form, microphone-route, noise, name,
developer-token, or incremental-delivery accuracy. There is no independently
labeled slice sufficient to report consequential name/token accuracy. A seeded
10,000-resample bootstrap by holdout recording gives an illustrative WER interval
of 0.22% to 2.51%, without correcting this representativeness problem.

The installed executable matches source `46f480a`, reports Release with `-O`,
and has SHA-256
`b67fffebef3cf898689f0c6e1944b9a236cb9ce40ac6e46b0a12e51ee6619b5e`.
The verified saved-audio baseline remains the older `f7118f7` Debug replay.
No fresh signed recognition replay ran in this investigation. Its evaluation
entry points are compiled only under `DEBUG`; running those environment flags
against the installed Release app would not invoke an evaluation host.

The existing preparation artifact contains 36 paced trials. Advance preparation
improves the paired median first-result time by about 2.1 ms, with about 29 ms of
preparation work. It does not justify a standby analyzer lifecycle.

The unhinted quality and final-only Speech arms produce identical raw and cleaned
outputs on all 75 recordings. Both have 22 cleaned word errors. The fast arm has
9, but it also supplies 44 contextual terms, so that comparison does not isolate
the preset. Existing evidence does not support abandoning streaming for accuracy.

An isolated optimized transform benchmark used the frozen dictionary, repeated
synthetic text, ten discarded warmup iterations, and 240 measured iterations per
size. Medians were 0.10 ms for 104 UTF-16 units, 0.31 ms for 454,
1.33 ms for 2,204, and 5.03 ms for 8,749. Reprocessing a long committed prefix is
visible in the source, but ordinary live cleanup is already sub-millisecond.
This experiment measures transformation cost, not total app CPU or streaming
latency. It does not support a priority rewrite.

October 16 logs include eleven recordings into the controlled native dictation
fixture and one empty Ghostty recording. Seven fixture recordings fell back to
keystrokes after `input method activation pending`; four used native commits.
All eleven had verified final readback. Do not report these as eleven successful
native streaming trials or as a daily-use failure rate. The current acquisition
path already retries this explicit pending response for 200 ms. A normal-target
reproduction is needed before changing its readiness policy or timeout.

Two of the seven October 15 native recordings contain final recognition events
while held. Their text is redacted, so the actual correction effects and revision
churn cannot be reconstructed. Repeated character counts are not text stability.

October 16 periodic idle samples have median RSS 29.7 MiB and median physical
footprint 47.7 MiB. Idle RSS reaches 89.8 MiB; three periodic recording samples
reach 75.0 MiB RSS and 186.8 MiB footprint. These mixed lifecycle samples neither
certify the five-minute memory acceptance criterion nor identify a leak. There
is no demonstrated memory optimization to rank above the two items here.

## Verification and reproduction

Private artifacts are under `.build/optimization-20261016/`. Audio, reference
text, dictionary data and generated diagnostic artifacts remain outside Git.

- `baseline-audit.json` and `oct15-audit.json` contain the independent audit output.
- `corpus.jsonl` is the regenerated ledger. `evidence-summary.json` includes
  paired recording timings, original log hashes and WAV verification counts.
- `accuracy-summary.json` contains arm counts and aggregate uncertainty estimates.
- `boundary-stress.json`, `selective-deferral.json`, `candidate-freeze.json` and
  `frozen-policy-holdout.json` preserve the controlled comparisons.
- `OptimizationEvidenceTests.swift` preserves the temporary experiment source.
  Its candidate policy hash was unchanged after the holdout was opened.
- `transform-cost.json` and `final-verification.log` preserve the unprofiled
  optimized run. The separately profiled timings are not used for cost estimates.

`scripts/audit --self-test` and `scripts/corpus --test` passed. The optimized
experiment suite, phrase safety tests and evaluation snapshot tests passed,
19 selected tests with zero failures.
No production source, settings, installed app, keyboard source or services were
changed. The temporary test source was removed after verification.

To reproduce the accuracy audit from the repository root:

```sh
scripts/corpus --output .build/optimization-20261016/corpus-fresh.jsonl
scripts/audit \
  --eval .build/evals/apple-presets-signed-confirmed75-f7118f7-20261002.jsonl \
  --eval-arm speech-progressive-fast \
  --corpus .build/optimization-20261016/corpus-fresh.jsonl --json
```

The temporary tests ran with `swift test -c release -Xswiftc -DDEBUG` and an
explicit test filter. Ordinary `swift test -c release` failed because the
evaluation tests reference types compiled only under `DEBUG`. Adding that define
keeps `-O` while enabling the evaluation helpers. These isolated optimized tests
must not be described as installed Release-app verification.

The Time Profiler launch completed its test workload, but recording finalization
stalled and the incomplete trace could not be exported. It was stopped. No
Instruments call-tree or allocation conclusion is claimed.

Tooling precaution learned during this run: `xcrun xctest -help` treats `-help`
as a missing test bundle and prints the entire environment. Use valid runner
arguments in a minimal environment and capture diagnostic output privately.
Do not use that help invocation with a credential-bearing environment.
