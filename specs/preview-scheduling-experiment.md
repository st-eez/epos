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
8.81 and 7.85 percent more marks. It was the first candidate selected to validate against a
native target. The 16 ms interval reduced staleness further, but its first
repeat's release result was within 0.10 ms of the 5 ms screening limit.
That boundary is too close to timing noise to treat as a robust release result.
Acknowledgment only coalescing more than doubled writes and failed that replay's
25 percent limit. The later native comparison below replaces this unmeasured
mark-count constraint with native cost measurements.

Transcript handler wall time p95 ranged from 1.08 to 1.22 ms across arms and
repeats. This includes scheduling and awaits, so it is not CPU consumption.
The fake transport measures no host rendering work. At this replay stage,
production remained at 100 ms pending native evidence.

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

## Native comparison protocol

Steve challenged the need for any fixed delay and requested a native comparison
before installation. The earlier 25 percent mark-count cap is a replay screening
choice, not a measured native capacity limit. A higher call count alone does not
establish a user-visible regression.

`NativePreviewSchedulingTests` compares the actual `InlinePreviewSession` at
100 ms and zero through `UnixSocketInlinePreviewTransport` and the normal
installed companion. It requires an explicitly authorized foreground Ghostty
fixture, captures its target with the production Accessibility observer, and
checks the expected process and synthetic window title. Companion ownership,
selection, input-event retirement and final-commit checks remain active.
No microphone or speaker is needed for this component comparison. Stop Epos and
any other owned probe driver before connecting, because a new companion peer
supersedes the previous one. Record the original app, source and foreground state;
restore and independently verify all three afterward. The harness refuses while
Epos is running and claims a single-use run directory before source acquisition.

Use a fresh private directory and the existing raw terminal fixture. Supply a
JSON configuration containing `targetPID`, `companionPID`, `fixturePID` and
`nonce`, with the nonce matching the fixture's `EPOS-SESSION-` title.
Set `EPOS_NATIVE_SCHEDULING_CONFIG` to that file and run the optimized test package.
After `source-ready` appears, deliver one ordinary `x` to the owned terminal,
verify its arrival, then create `start`. This establishes an actual native key
event before Ghostty's `insertText`; the priming byte is included in every
independent delivery check. It is fixture setup, not a product wake key.

Six pairs alternate arm order and repeat three workloads twice. They cover short
bursts, drafts of roughly 1,900 characters, and release during an unfinished native mark transport call. Each paired arm publishes the same 25 updates on the same intended
deadlines over 1.4 seconds. Short and long workloads release at 1.55 seconds. The
pending-call workload releases when its last draft enters the transport; the
evidence must confirm that call is unfinished. This includes socket queue time
and does not establish that the native client has received the request. Intended and actual publication times are
retained so late producers cannot masquerade as faster preview delivery. The transport records call-entry
and reply-completion timestamps. Each final must deliver exactly `EPOS final token`; the
receiver's cumulative byte count and SHA-256 verify all twelve commits. A separate
zero-delay trial pauses at `visual-ready` for a screenshot of its marked text.
Create `finish-visual` to commit, then inspect the final screenshot and all
thirteen exact payloads. That visual trial is excluded from timing summaries.
The harness restores its acquired input source on completion or failure.
The operator stops the fixture, closes only its window, and restores the previous
foreground window. It never replaces the installed companion for this check.

```sh
EPOS_NATIVE_SCHEDULING_CONFIG=<private-directory/config.json> \
swift test -c release -Xswiftc -DDEBUG --filter NativePreviewSchedulingTests
python3 scripts/analyze-native-preview.py <private-directory>
```

Use acknowledgment timestamps to reconstruct stale intervals, including revisions
superseded while a native request is pending. These measure completion of native
calls, not display scanout. Compare every pair, final latency, reply latency,
call count and native CPU use. Freeze these practical screening limits before
collecting results. Every pair must improve stale interval p95 by at least 20 ms.
The paired release increase must have a median no greater than 5 ms, with no pair
above 10 ms. Additional native CPU must have a median no greater than two
percentage points of one core, with no pair above five points. The median paired
increase in mark reply p95 must remain within 5 ms. These budgets reject trading
visible responsiveness for meaningful foreground work or a slower release; they
are experimental acceptance choices, not native API limits.

Publication lateness p95 must stay within 10 ms in every trial and differ by no
more than 5 ms within each pair. Both pending-release repeats must observe an
unfinished transport call in both arms. Exact bytes, successful native replies and
nonoverlapping commands are mandatory. A timing or coverage miss is inconclusive;
a delivery or native refusal fails the run. At most one fresh paired run may
resolve timing noise before reporting the comparison as inconclusive. Screenshots,
cleanup verification and the independent review remain required even when the
analyzer's timing screen passes.

Native CPU counters are Mach ticks and must be scaled by `mach_timebase_info`.
The harness records that timebase and process start time with each sample.
Apple's [task accounting implementation](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/task.c)
and [resource accounting export](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/bsd_kern.c)
establish the counter units. An independent `getrusage` calibration is retained
with the local experiment evidence.

## Native result, October 20

The authorized foreground Ghostty comparison completed all six pairs and the
separate visual trial using the installed companion. Every paired screening gate
passed. All thirteen native commits delivered the exact expected bytes. Screenshots
show the last marked phrase in place before release and the same text committed
afterward. The fixture stopped, its Ghostty process exited, and the original
ChatGPT window, ABC input source and Epos running state were restored.

| Measurement | 100 ms delay | Zero delay |
| --- | ---: | ---: |
| Median of trial stale-interval p95, ms | 116.85 | 14.89 |
| Median native mark reply p95, ms | 7.95 | 8.04 |
| Median release-to-commit completion, ms | 3.63 | 5.31 |
| Median combined native CPU, percent of one core | 8.58 | 10.15 |
| Total native marks across six trials | 78 | 105 |

Every pair improved stale-interval p95 by at least 100 ms. The greater mark count
stayed within the predefined CPU and reply-latency budgets. This supports removing
the default 100 ms scheduling delay while retaining serialized native replies and
coalescing. Production now defaults to zero additional scheduling delay.

These timestamps measure acknowledged native operations. They do not measure
display scanout or Speech recognition latency. The bounded synthetic workloads
do not certify overall replacement readiness or sustained microphone behavior.
Local evidence is retained under `.build/native-delay-20261020/native-run1/`,
including raw trials, analyzer output, terminal digests, screenshots and cleanup.
