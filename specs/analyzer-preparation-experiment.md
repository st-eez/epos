# Analyzer preparation experiment

Date: 2026-10-01.

## Question

Does `SpeechAnalyzer.prepareToAnalyze(in:)` reduce the time from a hold to the
first visible recognition result enough to justify preparing the next analyzer
while Epos is idle? The installed Speech SDK exposes the API on macOS 26. Apple's
[documentation](https://developer.apple.com/documentation/speech/speechanalyzer/preparetoanalyze(in:))
describes preparing the analyzer's resources ahead of the first input.

## Experiment

A DEBUG host runs inside the installed signed app, without creating the app UI,
opening a microphone, producing sounds, or writing to any destination field. It
reuses the confirmed evaluation corpus and checks each selected WAV's digest
before recognition. Three arms each create a fresh analyzer and module with the
production preset, vocabulary context, canonicalizer, and deterministic cleanup.

- `unprepared` matches the current analyzer setup.
- `inline` calls preparation after the simulated hold begins.
- `advance` calls preparation before the simulated hold begins and retains that
  analyzer for the configured idle interval.

The host converts each recording once and feeds the same buffers at their audio
rate, including a burst of startup buffers when setup outlasts their tap times.
It checks the total frames submitted and consumed by the analyzer. This measures
first input and release behavior, rather than offline throughput. Arm order
rotates by recording and repeat. The first trial is labeled
explicitly. It does not prove that the system's Speech service is cold.

Rows record preparation, analyzer start, first result from hold and input, release
to final result, transcript scores, and RSS before setup, at readiness, after the
idle interval, and after cleanup. Preparation and idle time remain separate from
the hold clock. An advance-arm result cannot describe work moved earlier as work
eliminated. RSS is the evaluation process's sampled resident memory, not the
installed app's five-minute idle acceptance measurement.

The experiment retains every startup frame. If setup exceeds the app's three
second capture pre-roll cap, the inline arm does not model the resulting loss of
opening speech and cannot support adopting that setup path.

An evaluation watchdog terminates the host if a trial outlives the recording's
duration, configured idle time, and a generous framework allowance. Failed
preparation is an explicit failed row; it is not scored as a working speedup.

## Decision gate

Keep the production lifecycle until current measurements show a repeatable
first-result improvement, equivalent transcripts, and an acceptable memory cost.
If advance preparation wins, a separate change must define single-use standby
ownership, invalidation for vocabulary and format changes, bounded preparation,
and cleanup on cancellation, release, and quit. It must retain the current fresh
analyzer per recording and startup-audio guarantees.

Inline preparation alone can add work after capture starts. A measured gain for
advance preparation does not establish that inline preparation benefits Epos.

## Reproduction

Build and install the current signed Debug app using the development workflow,
then run its executable in the evaluation mode. The parent task serializes this
with other signed evaluations.

```sh
EPOS_RUN_ANALYZER_PREPARATION_EVAL=1 \
EPOS_DIAGNOSTIC_LOGS=0 \
EPOS_EVAL_CORPUS="$PWD/.build/evals/evaluation-corpus-v2.jsonl" \
EPOS_EVAL_OUTPUT="$PWD/.build/evals/analyzer-preparation.jsonl" \
EPOS_EVAL_LIMIT=6 EPOS_PREPARE_REPEATS=2 EPOS_PREPARE_IDLE_SECONDS=2 \
  /Applications/Epos.app/Contents/MacOS/Epos
```

`EPOS_EVAL_RECORDINGS_DIR` overrides the saved WAV directory. Set
`EPOS_PREPARE_IDLE_SECONDS=300` for a sampled five-minute retention experiment.
Use `EPOS_PREPARE_FIRST_ARM` to choose which arm starts a new evaluation process.
The JSONL rows and adjacent summary preserve those settings and trial order.

## Results

Pending the signed comparison. Production currently creates its analyzer when a
hold begins and does not call preparation.
