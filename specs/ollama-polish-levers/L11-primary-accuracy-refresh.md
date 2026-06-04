# L11 Primary Accuracy Refresh

Status: implemented+verified

## Why This Lever Exists

The correction review loop is usable enough for dogfood, but the primary product
goal is still transcript quality and finish latency. Before adding more
secondary correction UI, rerun the current saved-recording scoreboard and use the
remaining errors to choose the next primary lever.

## Hypothesis

If current residuals are mostly deterministic correction misses, continue with
correction aliases or dictionary learning. If current residuals are raw ASR
misses and Apple Speech alternatives contain better transcripts, the next
primary lever should be alternative-candidate selection or reranking. If polish
or model variants improve strict-gate output, continue polish/model work. If the
scoreboard is already quality-bound but slow, prioritize finish latency.

## Read When Pulling This Lever

- `Tests/EposTests/DogfoodPipelineEvalTests.swift`
- `Tests/EposTests/SpeechContextEvalTests.swift`
- `scripts/dogfood-residual-report.py`
- `specs/local-ollama-polish-experiment.md`

## Evidence Needed

- Full 114-row dogfood JSONL against the current code.
- Residual markdown report.
- Residual-only speech-context/alternatives JSONL.
- Latency summary for transcribe, production polish, and shadow polish.
- Manual residual classification with a next-lever decision.

## Attempts

### 2026-06-04

- Change: no production behavior changed. This slice refreshes current evidence.
- Commands:
  - `jq -s '{rows:length, uniqueFiles:([.[].file] | unique | length), missingTranscript: map(select((.humanIntendedTranscript // "") == "")) | length}' "$HOME/Library/Caches/Epos/recordings/ground-truth.jsonl"`
  - `ollama list`
  - `ollama ps`
  - `EPOS_POLISH_ENGINE=ollama EPOS_RUN_DOGFOOD_EVAL=1 EPOS_EVAL_SHADOW_RELAXED_OLLAMA=1 EPOS_EVAL_RECORDING_FILES="$(jq -r '.file' "$HOME/Library/Caches/Epos/recordings/ground-truth.jsonl" | paste -sd, -)" EPOS_EVAL_OUTPUT=.build/evals/dogfood-pipeline-primary-refresh-20260604.jsonl swift test --filter DogfoodPipelineEvalTests > .build/evals/dogfood-pipeline-primary-refresh-20260604.log 2>&1`
  - `scripts/dogfood-residual-report.py .build/evals/dogfood-pipeline-primary-refresh-20260604.jsonl --output .build/evals/dogfood-primary-refresh-residuals-20260604.md`
  - `EPOS_RUN_CONTEXT_EVAL=1 EPOS_EVAL_RECORDING_FILES="$(jq -sr 'map(select(.outputTranscriptScore.wordErrorRate>0).file) | join(",")' .build/evals/dogfood-pipeline-primary-refresh-20260604.jsonl)" EPOS_EVAL_OUTPUT=.build/evals/speech-context-primary-refresh-residual10-20260604.jsonl swift test --filter SpeechContextEvalTests > .build/evals/speech-context-primary-refresh-residual10-20260604.log 2>&1`
  - `ollama ps`
- Results:
  - Ground truth manifest: `114` rows, `114` unique files, `0` missing intended
    transcripts.
  - Saved recordings available locally: `130` `.wav` files.
  - Installed Ollama models: `qwen3:1.7b` and `qwen3:4b`; `ollama ps` was empty
    before and after eval.
  - Full dogfood eval passed and wrote `114` JSONL rows.
  - Mean row WER raw/canonicalized/output: `0.076/0.011/0.009`.
  - Mean row accuracy raw/canonicalized/output: `0.924/0.989/0.991`.
  - Total word errors raw/canonicalized/output: `84/13/10` over `1325`
    intended words.
  - Output residual rows: `10`.
  - Raw to canonicalized: `37` better, `77` same, `0` worse.
  - Raw to output: `40` better, `74` same, `0` worse.
  - Output vs canonicalized raw: `3` better, `111` same, `0` worse.
  - Outcomes: `sameText=106`, `deterministicCleanup=3`, `applied=2`,
    `guardRejected=2`, `timedOut=1`.
  - Engine outcomes: `success=113`, `timedOut=1`.
  - Production finish-time polish latency: mean `0.704s`, p50 `0.652s`,
    p95 `0.942s`, max `2.502s`.
  - Transcribe latency: mean `0.131s`, p50 `0.117s`, p95 `0.226s`,
    max `0.445s`.
  - Shadow relaxed Ollama strict-gate output changed production in `0` rows.
  - Shadow relaxed raw candidate changed production in `43` rows, but strict
    guard kept production output unchanged.
  - Residual-only speech-context eval over the 10 current residual files passed.
  - Speech context variants changed raw transcripts in `0` residual rows.
  - Production alternatives contained better, perfect transcripts for `4` of the
    `10` residual rows.

Manual residual classification:

| Class | Count | Files | Notes |
| --- | ---: | --- | --- |
| Alternative candidate has perfect transcript | 4 | `2026-06-02_17-57-09-237.wav`, `2026-05-31_07-30-04-394.wav`, `2026-05-31_07-43-00-730.wav`, `2026-05-31_07-51-51-282.wav` | Apple Speech alternatives included the intended transcript, but production selected the non-perfect top transcript. This is the strongest measured next lever. |
| Raw ASR lexical miss, no better alternative | 4 | `2026-05-30_13-19-59-320.wav`, `2026-05-31_07-43-05-223.wav`, `2026-05-31_07-47-28-138.wav`, `2026-06-02_09-33-48-935.wav` | Examples include `Latif` vs `it`, `Drop` vs `Dropped`, `Lords` vs `logs`, and missing `working`. Broad deterministic cleanup would be risky from one row each. |
| Raw ASR leading/trailing boundary miss, no better alternative | 2 | `2026-06-01_14-31-11-463.wav`, `2026-06-02_17-56-38-709.wav` | Examples are missing leading `Add` and extra trailing `And.`. These point at capture/endpointing or segmentation, not correction UI. |

Important residual examples:

- `2026-05-31_07-51-51-282.wav`: top transcript said `books`; production
  alternative included `bugs` and scored WER `0.000`.
- `2026-05-31_07-43-00-730.wav`: top transcript omitted leading `It`;
  production alternative included the full intended sentence and scored WER
  `0.000`.
- `2026-05-31_07-30-04-394.wav`: top transcript said `enabled to check`;
  production alternative said `enabled so check` and scored WER `0.000`.
- `2026-06-02_17-57-09-237.wav`: top transcript inserted leading `I`;
  production alternative removed it and scored WER `0.000`.

## Decision

Stop adding correction-review niceties for now. The current correction path is
valuable, but the refreshed primary scoreboard says the next high-value lever is
Apple Speech alternative-candidate selection or reranking.

The next implementation slice should be an eval-only alternative-reranking
prototype before any production behavior change:

- Use the same saved-recording harness.
- Emit the top transcript plus available alternative transcript candidates.
- Score an oracle upper bound and at least one non-oracle, deterministic
  selection rule.
- Gate against all 114 ground-truth rows, not just the 10 residuals.
- Require zero regressions before considering production use.
- Measure latency impact, because alternatives should not make short dictation
  feel slower.

Rejected next levers for now:

- More correction UI: not the primary bottleneck in the current residual set.
- More `AnalysisContext` bias: current residual replay still produced `0` raw
  transcript changes.
- Looser LLM polish: relaxed shadow changed strict-gate production output in
  `0` rows and produced many raw candidates that the guard correctly refused.
- Broad deterministic aliases for one-off ASR misses: possible later through the
  correction loop, but risky as the next primary lever without repeated evidence.
