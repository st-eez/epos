# Raw STT benchmark results

Source of truth for the first raw local STT comparison against Apple
`SpeechTranscriber`.

## Run

Date: 2026-06-06

Ground truth source:

- `~/Library/Caches/Epos/recordings/ground-truth.jsonl`
- `114` saved `.wav` recordings
- `1325` reference words
- `456.0` seconds of audio

Raw-transcription constraints:

- No Epos `TranscriptCanonicalizer`
- No LLM polish
- No Apple `contextualStrings`
- No model hotword list or biasing context
- IBM Granite used only its required neutral ASR task prompt:
  `can you transcribe the speech into a written format?`

Artifacts:

- Candidate rows: `.build/evals/raw-stt-benchmark-full114-20260606/`
- Candidate summary: `.build/evals/raw-stt-benchmark-full114-20260606/summary.json`
- Candidate markdown: `.build/evals/raw-stt-benchmark-full114-20260606/combined-summary.md`
- Apple rows: `.build/evals/raw-apple-full114-20260606.jsonl`
- Apple log/resource metrics: `.build/evals/raw-apple-full114-20260606.log`

Harness commit:

- `7a192e2 feat: add raw stt benchmark harness`

## Summary

| Engine | Corpus WER | Exact Clips | Word Errors | Warm RTFx | Wall RTFx | Peak RSS | Peak Footprint | Load |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Apple Speech raw | `6.34%` | `66 / 114` | `84 / 1325` | `36.50x` | `30.12x` | `64.8 MiB` / `0.06 GB` | `15.3 MiB` / `0.01 GB` | n/a |
| Whisper large-v3-turbo MLX | `5.28%` | `73 / 114` | `70 / 1325` | `6.50x` | `6.35x` | `1783.4 MiB` / `1.74 GB` | `3408.0 MiB` / `3.33 GB` | `1.43s` |
| Parakeet MLX | `6.57%` | `68 / 114` | `87 / 1325` | `28.85x` | `26.35x` | `1209.6 MiB` / `1.18 GB` | `7017.8 MiB` / `6.85 GB` | `1.31s` |
| IBM Granite Speech | `6.64%` | `64 / 114` | `88 / 1325` | `5.35x` | `5.05x` | `3755.4 MiB` / `3.67 GB` | `10169.1 MiB` / `9.93 GB` | `4.33s` |

GB values are approximate `MiB / 1024` conversions.

## Definitions

Corpus WER is the primary accuracy metric for model comparison. It is total word
edit errors divided by total reference words across the full corpus.

Exact clips is a secondary file-level metric. A model can have more exact clips
and still worse corpus WER if its non-exact clips contain more total word
errors.

Warm RTFx is audio duration divided by transcription wall time after the model
is loaded. `6.50x` means the model processed `6.5` seconds of audio per `1`
second of wall time.

Wall RTFx includes model load/startup overhead.

Peak RSS is resident memory observed by `/usr/bin/time -l`.

Peak footprint is macOS memory pressure charged to the process. For MLX model
runs, use footprint as the more practical RAM-pressure estimate.

Apple memory numbers are for the Swift test process. They do not directly count
memory used inside Apple's system speech service.

## Row-level comparison versus Apple

| Model | Better Rows | Worse Rows | Tied Rows |
|---|---:|---:|---:|
| Parakeet MLX | `23` | `24` | `67` |
| Whisper large-v3-turbo MLX | `28` | `16` | `70` |
| IBM Granite Speech | `27` | `26` | `61` |

Parakeet had `68` perfect clips versus Apple's `66`, but Apple had fewer total
word errors: `84` versus Parakeet's `87`. This is why Apple has better corpus
WER while Parakeet has more exact clips.

## Current decision

Apple Speech remains the product default because it is fastest and has the
lowest app-visible memory pressure.

Whisper large-v3-turbo MLX is the best raw-accuracy candidate from this run. It
reduced corpus WER from Apple's `6.34%` to `5.28%`, at roughly `3.33 GB` peak
memory footprint and `6.35x` wall speed.

Parakeet MLX is the strongest speed candidate among local non-Apple models. It
was near Apple speed on this corpus, but it did not beat Apple on corpus WER and
had a higher footprint than Whisper in this run.

IBM Granite Speech is not a good next integration candidate from this run. It
was less accurate than Whisper, slower than Parakeet, and had the highest memory
footprint.

## Re-run commands

Set up Python dependencies:

```sh
uv venv --python 3.12 .build/stt-bench/venv
uv pip install --python .build/stt-bench/venv/bin/python parakeet-mlx mlx-audio mlx-whisper
```

Run local candidate models:

```sh
scripts/raw-stt-benchmark.py \
  --models parakeet,whisper,granite \
  --output-dir .build/evals/raw-stt-benchmark-full114-20260606
```

Run Apple raw baseline over the same selected files:

```sh
files=$(jq -r '.file' .build/evals/raw-stt-benchmark-full114-20260606/selection.jsonl | paste -sd, -)
/usr/bin/time -l env \
  EPOS_RUN_RAW_STT_APPLE_EVAL=1 \
  EPOS_EVAL_RECORDING_FILES="$files" \
  EPOS_EVAL_OUTPUT=.build/evals/raw-apple-full114-20260606.jsonl \
  swift test --filter RawSpeechTranscriberEvalTests \
  > .build/evals/raw-apple-full114-20260606.log 2>&1
```

For a future comparison, keep the same selected files when possible. If new
ground-truth rows are added, record the row count, reference word count, total
audio seconds, and artifact paths in this file before comparing headline
metrics.
