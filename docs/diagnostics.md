# Diagnostics and evaluation

## Logs

Use `EposLogger` and reuse the category owned by the module. It sends events to
Apple unified logging under `com.steez.Epos` and mirrors them into
`~/Library/Caches/Epos/logs/`. The diagnostic sink rotates
at roughly 10 MB per file and keeps at most 14 files. Individual messages are
capped at 20,000 characters. The shared sink is disabled in recognized test
processes so synthetic failures do not become dogfood evidence.

Transcript timing logs contain event order, elapsed time, and UTF-16 counts by
default. Setting `EPOS_DIAGNOSTIC_TRANSCRIPT_TEXT=1` for the app process adds raw,
final, partial, and displayed transcript text. Diagnostic logs are local debug
material, and enabling transcript text preserves dictated content there.
Keep transcript-bearing diagnostics local and out of source control.

For a bounded live investigation, use `scripts/epos-tail-logs.sh` or this manual
unified log command:

```sh
/usr/bin/log stream --predicate 'subsystem == "com.steez.Epos"' --info --debug
```

The companion keeps its own log at `~/Library/Caches/EposProbe/probe.log`; inspect
it when debugging marked text.

Recording IDs join capture, recognizer, preview, guard, insertion, and terminal
reliability events. Each recording emits schema-1 reliability metadata with counts,
stage outcomes, write acceptance, readback state, IME acknowledgment, and release
latency. The terminal emitter is idempotent. Recognition failures, interrupted capture,
empty speech, target refusal, backend refusal, delivery mismatch, verified
delivery, and accepted but unverified delivery have distinct outcomes. A fully
sent IME commit without acknowledgment is explicitly ambiguous.

## Stage timing

Each recording also emits metadata events such as
`recording timing schema=1 stage=analyzer-startup attempt=1 durationMs=12.345 elapsedMs=45.678 outcome=completed`.
Durations and elapsed time use `ContinuousClock`, with millisecond values to three
decimal places. The timing schema is separate from the unchanged reliability
schema. Recording IDs join the two.

The stages cover microphone opening, target baseline capture, analyzer startup,
the first recognizer result, the first nonempty cleaned display publication, the
first acknowledged IME mark, release to recognizer stream completion, final
transcript cleanup, preview cancellation and discard, composition and readable
baseline waits, target authorization, IME commit, keystroke write, delivery
readback, and session cleanup. Repeated authorizations after a safe IME refusal
have distinct attempt numbers.

The three first-result stages start at recording startup. A filler-only result
can precede a useful display publication. Display publication measures the
coordinator event, and IME acknowledgment includes its callback's handoff to the
main actor. Neither measures a HUD paint or the host application's screen update.
These timers exclude readiness checks and deferred fn presses, so they cannot
establish physical fn-to-text or cold app startup latency.

`release-to-write` ends when Unicode posting returns accepted or the IME commit
acknowledgment is recorded. Readback runs separately and can finish after the
session returns to idle. Accepted posting does not prove the field has displayed
the text. Release during analyzer startup includes the remaining startup time in
recognizer finalization. A recognizer that already ended before release records
zero remaining finalization work.

`scripts/audit` reports p50 and p95 durations for each stage and outcome, including
sample counts. It counts unavailable first results with `durationMs=-1` and
excludes them from percentiles. Unexecuted stages produce no sample. Failed,
refused, ambiguous, and unavailable measurements stay separate from completed
work. The parser rejects malformed measurements and conflicting duplicate
attempts. A completed wait means the bounded wait returned; the authorization
and reliability outcome determine whether delivery was safe and successful.
Stages can overlap, so their percentiles cannot be added to produce total latency.

The [timing contract](../specs/recording-stage-timing.md) defines the boundaries
and limits. Instrumentation identifies costs; it does not establish a speed gain.

## Saved audio and correction evidence

Save audio samples defaults off. When enabled for a recording, DogfoodTap copies
native microphone buffers to a serial disk queue and writes a per-recording WAV
under `~/Library/Application Support/Epos/recordings/`. This directory also holds
the evaluation manifests and confirmations. Samples are durable local evaluation
material; they are not placed in purgeable cache storage.

Learn corrections is a separate opt-in. Its transcript and edit records persist
in UserDefaults with a 200-record cap. See [corrections](corrections.md).
Neither setting provides a transcription history UI. Turning them off stops new
capture; existing saved material remains on disk or in preferences.

## Evaluation tools

Run these from the repository root. Use `--help` for Python command options.

| Command | Purpose |
| --- | --- |
| `scripts/audit` | Classify operational logs and signed corpus artifacts; `--json` emits a report and `--self-test` checks the parser |
| `scripts/corpus` | Build a provenance ledger, validate frozen membership, and freeze the confirmed holdout floor |
| `scripts/confirm` | Prepare and manage an audio-backed human confirmation session for the frozen holdout |
| `scripts/label` | Build a human review queue from supported evaluation artifacts |
| `scripts/bench [count]` | Install a signed Debug app and run the Apple preset comparison inside its app identity |
| `scripts/correct <candidate.json> [artifact.jsonl]` | Evaluate a correction candidate against the confirmed signed production arm |
| `scripts/migrate` | Move the historical recording corpus from cache storage to Application Support |
| `scripts/raw-stt-benchmark.py` | Benchmark saved audio with supported recognizers and score transcript errors |

Start an investigation with `scripts/audit`, then inspect events for the affected
recording. Reliability auditing prints metadata only. Check log dates and installed
build provenance. Logs before the test-sink fix can contain synthetic test output;
missing recording IDs, `app=nil`, or bursts without recording boundaries alone
cannot establish user harm.

`scripts/bench` replaces the installed application. Candidate evaluation defaults
to `.build/evals/apple-presets-signed-confirmed75.jsonl`, whose expected shape is
35 confirmed legacy rows plus 40 confirmed holdout rows. It requires no
development or holdout regressions and at least one holdout improvement. That
artifact name and contract do not prove the artifact exists or is current.

The `speech-progressive-fast` arm now reuses the production preset, including
confidence attributes, and the production context builder. One persisted
dictionary snapshot supplies its canonical vocabulary and every arm's final
cleanup. The other four arms remain unhinted controls. Context readback must
match the requested terms before a replay can become a scored baseline.
Historical preset artifacts omitted vocabulary context, so retain their dated
results as unhinted evidence.

New private rows preserve the dictionary records and its SHA-256 digest, the
corpus digest, requested context and actual readback, compiled source revision,
source dirty flag, Debug or Release configuration, compiler optimization, SDK,
OS, architecture, and executable
SHA-256. The dirty flag excludes generated Info.plist and entitlements, whose
inputs live in `project.yml`. Older rows remain readable, but absent metadata
cannot establish current build or context provenance.

The audit keeps schema-1 logs distinct from legacy inferred sessions and reports
incomplete or ambiguous outcomes. Delivery success and recognition accuracy have
separate denominators. Verified accuracy requires explicit human-confirmed
reference provenance backed by the corpus. Raw recognizer output cannot establish
the user's intended transcript. Select an artifact and arm explicitly when
interpreting a current result.

Opt-in Swift evaluation tests use `EPOS_RUN_*` environment flags. Skipping those
harnesses during the ordinary test suite does not certify recognition quality.
See [the corpus specification](../specs/evaluation-corpus.md),
[intended transcript accuracy](../specs/intended-transcript-accuracy.md),
[recognition bias decision](../specs/recognition-bias-decision.md), and
[raw benchmark results](../specs/raw-stt-benchmark-results.md) for their dated
evidence and scoring contracts.

## Evidence

Source is [EposLogger](../Sources/Epos/Diagnostics/EposLogger.swift),
[TranscriptTimingDiagnostics](../Sources/Epos/Diagnostics/TranscriptTimingDiagnostics.swift),
[ReliabilityDiagnostics](../Sources/Epos/Diagnostics/ReliabilityDiagnostics.swift),
[RecordingLatencyDiagnostics](../Sources/Epos/Diagnostics/RecordingLatencyDiagnostics.swift),
[DogfoodTap](../Sources/Epos/Audio/DogfoodTap.swift), and
[SignedApplePresetEvalHost](../Sources/EposMacApp/SignedApplePresetEvalHost.swift).

[DiagnosticsSmokeTests](../Tests/EposTests/DiagnosticsSmokeTests.swift) and
[ReliabilityDiagnosticsTests](../Tests/EposTests/ReliabilityDiagnosticsTests.swift)
cover log defaults and outcomes.
[RecordingLatencyDiagnosticsTests](../Tests/EposTests/RecordingLatencyDiagnosticsTests.swift)
and [RecordingLatencyPipelineTests](../Tests/EposTests/RecordingLatencyPipelineTests.swift)
use an injected monotonic clock to check stage boundaries, missing results,
refused writes, and readback separation. Commit routing tests cover acknowledged
and ambiguous IME durations without another write.
[SavedRecordingEvalSupportTests](../Tests/EposTests/SavedRecordingEvalSupportTests.swift)
and [CanonicalizerCandidateEvalTests](../Tests/EposTests/CanonicalizerCandidateEvalTests.swift)
cover artifact and candidate contracts. The Python command self-tests cover
provenance and audit classification. None substitutes for a current signed app
dictation run and independently confirmed transcripts.
