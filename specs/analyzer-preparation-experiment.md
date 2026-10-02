# Analyzer preparation experiment

Date: 2026-10-01.

## Question

Does `SpeechAnalyzer.prepareToAnalyze(in:)` reduce the time from a hold to the
first nonempty recognizer result enough to justify preparing the next analyzer
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

First result means the first nonempty raw recognition event. Cleanup may remove
that event's filler text before the app displays it. This host does not measure
preview rendering or release to field delivery.

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

The signed run completed on 2026-10-01 with 36 successful trials. It used six
human-confirmed legacy clips, two repeats, and three arms. Clips ranged from 1.1
to 7.5 seconds and contained 17.3 seconds of unique audio. Each arm consumed
553,600 converted frames across its twelve trials. All expected, submitted, and
consumed frame counts matched. Every trial produced identical raw and cleaned
text to its matching unprepared trial. All 44 vocabulary terms matched the
analyzer's context readback.

| Arm | Median preparation ms | Median hold to first result ms | Paired first result delta ms | Median release to final ms | Paired release delta ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| Unprepared | 0 | 1142.887 | 0 | 87.459 | 0 |
| Inline | 29.769 | 1142.066 | +2.258 | 83.904 | +0.391 |
| Advance | 28.651 | 1138.842 | -2.071 | 83.043 | -2.216 |

Paired deltas compare the same clip and repeat. They are not differences between
the aggregate medians. Negative values mean earlier results. Advance preparation
also moved a median 28.815 ms of setup before the hold and retained the analyzer
for two seconds before beginning input.

Advance first-result deltas ranged from -6.795 to +8.372 ms. Their median was
-0.883 ms in the first repeat and -2.887 ms in the second. Inline deltas ranged
from -14.080 to +16.258 ms. Excluding the first trial's matched comparisons left
advance at -2.169 ms and inline at +1.682 ms. The small differences also varied
with arm order. The first unprepared trial took 1132.538 ms to its first result.

Median evaluation RSS at readiness was 29.758 MiB unprepared, 29.852 MiB inline,
and 29.875 MiB advance. Advance RSS after its two-second idle interval was
29.781 MiB. The median readiness increase from each trial's own starting RSS was
zero for every arm; the largest sampled advance increase was 0.047 MiB. These
samples include the replay process and its framework state. They do not measure
the normal menu bar app, Apple's Speech service, or five-minute standby retention.

Preparation completed in roughly 29 ms while first input arrived about 93 ms
after the hold. That timing is consistent with preparation finishing before the
first simulated capture buffer, which would explain the small visible difference
in this sample. It is an inference, not a cold-start measurement.

The build was signed Debug with `-Onone`, a clean source tree at
`f7118f7a5e59623eb275497e1696a54b2b02de60`, macOS 27 SDK, and macOS 27.0 build
26A428 on arm64. A full accuracy evaluation ran before this comparison. The
system Speech service's coldness is unknown. The sample contains legacy clips
only and does not establish release-build, first-launch, microphone, or field
delivery behavior.

The private artifact is
`.build/evals/analyzer-preparation-f7118f7-20261002.jsonl`. Its filename uses the
UTC date. Its SHA-256 is
`c9b87a967cac49905449e63a1cba0503c481ad1f7ee0f1bb62a909df1e13502f`.
Every row carries the WAV, confirmed corpus, dictionary snapshot, and signed
executable hashes. Private audio and reference text stay out of the repository.

## Decision

Retain fresh analyzer creation when each hold begins. The approximately 2.1 ms
advance difference is less than 0.2% of the first-result time in this sample.
Inline preparation's paired median is slightly slower. These results do not
justify standby ownership, vocabulary and format invalidation, or additional
cleanup paths in production. Keep the quiet comparison available for a measured
startup problem. Cold first-hold delay, release builds, and longer idle retention
remain outside this experiment's evidence.
