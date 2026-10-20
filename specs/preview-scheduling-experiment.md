# Preview scheduling and phrase acknowledgment experiment

Steve requested silent scheduling replay first, then phrase commit stall checks,
with production changes only for a real gain. Normal Epos remains running.
The experiment uses fake transports and saved text events. It opens no windows,
captures no microphone input, and plays no audio.

## Protocol frozen before replay

Use all 70 baseline traces from the October 20 recognition comparison,
35 recordings captured twice. Preserve event timestamps, release timestamps,
correction dictionaries, and final events. Reuse the actual `RecordingSession`
transcript handlers and `InlinePreviewSession` through
`RecognitionEventReplayTests`.

Compare the existing 100 ms interval with 33 ms, 16 ms, and acknowledgment only
coalescing. The latter uses a zero interval, so revisions can coalesce while a
request is in flight but have no additional wait after its reply. This is a
bounded candidate, not a new adaptive algorithm.

Replay four independent sessions concurrently for each recording, rotating their
creation order. All see the same captured timestamps and an immediately replying
fake transport. Release runs independently of transcript processing. Keep both
capture repeats separate in the analysis. This is a scheduler comparison under
shared process load, not a native rendering or isolated CPU benchmark.

Reconstruct simulated displayed text from mark, seal, commit and cancel commands.
The fake transport succeeds immediately, so command timestamps stand in for
acknowledgment timestamps.
Measure the fraction of replay time that text differs from the latest display
publication, duration of each stale interval, mark count, transcript processing
wall time, and release to completion. Superseded revisions remain in the stale
time calculation. Require identical delivered text and routes in every paired
run, with no keystroke writes or failed assertions.

A useful scheduling candidate must reduce the 95th percentile stale interval by
at least 20 ms in each capture repeat, without raising mark count by more than
25 percent or release to completion's 95th percentile by more than 5 ms.
Report all candidates, including failures. Native rendering cost is unmeasured,
so passing this screen alone does not authorize production promotion.

Then exercise the actual `RecordingSession` event loop with controlled phrase
acknowledgment delays. Check queued partials and finals, release during a pending
reply, and an ambiguous reply. Record event publication delay and exact committed
payloads. Artificial delay establishes susceptibility, not the frequency of slow
acknowledgments in daily use. Inspect existing diagnostics for that frequency
without collecting new audio or manipulating any target application.

If evidence justifies concurrent recognition processing, model its ownership,
ordering, release, cancellation and ambiguous outcomes in TLA+ before changing
coordination. A passing model does not establish native latency or delivery.

## Evidence limits

The replay calls production transcript handlers in their existing order. It does
not start Speech or run the full capture lifecycle. The separate stall checks
exercise the actual event loop with fake microphone, recognizer, target observer,
keyboard source and transport. Neither establishes current Ghostty rendering,
terminal bytes, or native acknowledgment cost.

## Reproduction

Prepare JSONL input by selecting the `unprepared` arm from the recognition
comparison's development capture. Keep all 35 recordings and both repeats.
Keep raw text and results in ignored `.build` artifacts.

Run the optimized test package with `DEBUG` defined, because the package's other
evaluation tests depend on helpers excluded from ordinary release builds.

```sh
EPOS_RECOGNITION_REPLAY_INPUT=<input.jsonl> \
EPOS_RECOGNITION_REPLAY_OUTPUT=<replays.jsonl> \
EPOS_REPLAY_COMPARE_SCHEDULES=1 \
swift test -c release -Xswiftc -DDEBUG --filter RecognitionEventReplayTests

python3 scripts/analyze-preview-scheduling.py \
  --captures <input.jsonl> --replays <replays.jsonl>

EPOS_PHRASE_STALL_OUTPUT=<stalls.json> \
swift test -c release -Xswiftc -DDEBUG \
  --filter RecordingPhraseTests/testPhraseAcknowledgmentStalls
```

The ordinary test suite skips these experiments unless their output paths are
provided. The analysis self-check runs with `--self-test`.

## October 20 results

All 280 replays completed successfully. Every schedule delivered identical text
for each recording and capture repeat, through simulated IME delivery, with zero
keystroke writes.

| Interval | Stale interval p95, repeat 1 | Stale interval p95, repeat 2 | Marks, repeat 1 / 2 | Release p95 change, repeat 1 / 2 | Replay screen |
| --- | ---: | ---: | ---: | ---: | --- |
| 100 ms | 105.92 ms | 106.24 ms | 329 / 331 | baseline | baseline |
| 33 ms | 37.60 ms | 37.88 ms | 358 / 357 | +1.11 / +1.15 ms | pass |
| 16 ms | 19.84 ms | 19.67 ms | 361 / 361 | +4.90 / +3.05 ms | pass |
| Acknowledgment only | 0.28 ms | 0.30 ms | 679 / 679 | +2.56 / +4.93 ms | fail, write volume |

The 33 ms interval reduced stale interval p95 by 68.32 and 68.36 ms, with
8.81 and 7.85 percent more marks. It is the first candidate to validate against a
native target. The 16 ms interval reduced staleness further, but its first
repeat's release result was within 0.10 ms of the 5 ms screening limit.
That boundary is too close to timing noise to treat as a robust release result.
Acknowledgment only coalescing more than doubled writes and fails the frozen
25 percent limit.

Transcript handler wall time p95 ranged from 1.08 to 1.22 ms across arms and
repeats. This includes scheduling and awaits, so it is not CPU consumption.
The fake transport measures no host rendering work. Production remains at
100 ms, pending native evidence for the 33 ms candidate.

The actual recording loop passed 17 controlled phrase reply scenarios. For each
configured delay, three runs queued a partial, a final, and another partial while
the first phrase reply was pending.

| Configured first reply delay | Median time from enqueue to last publication |
| --- | ---: |
| 0 ms | 0.42 ms |
| 5 ms | 6.41 ms |
| 20 ms | 24.55 ms |
| 100 ms | 105.18 ms |
| 400 ms | 404.09 ms |

Each publication followed the measured first reply. The remaining wait for that
reply accounts for all but at most 1.50 ms of the held scenarios' publication
delay. This confirms that awaiting a phrase commit can stall recognition event
consumption. Every queued final remained in the delivered text.

Release during a 100 ms reply wait delivered the first phrase once and the
remaining text once. A simulated 500 ms reply timeout permitted only the
ambiguous first phrase attempt, with no further native writes or keystroke
fallback. These checks establish the current sequencing and duplicate
suppression, not a faster concurrent implementation.

The existing 14 app log files and companion log contained no phrase send/reply
latency pairs. The app's `ime-commit` stage times final routing, while the
companion logs phrase completion only. Slow native phrase replies' frequency
therefore remains unconfirmed. No concurrency change or TLA+ model was introduced.
If native timings justify decoupling, the ownership and ordering model remains a
prerequisite to that change.

Local ignored evidence is under `.build/scheduling-replay-20261020/`.
`provenance.json` identifies the input and harness, `replays.jsonl` contains the
280 runs, `analysis.json` contains the paired checks and aggregates,
`stalls.json` contains all 17 controlled scenarios, and
`native-diagnostics.json` records the log inspection. Raw transcripts stay local.
