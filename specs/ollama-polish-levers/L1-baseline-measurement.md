# L1 Baseline Measurement

Status: implemented+verified

## Why This Lever Exists

The experiment index requires a fresh baseline before pulling any optimization
lever. At checkpoint start, source wiring showed the production Ollama path
using `qwen3:1.7b`, the strict prompt, prewarm enabled, and `keep_alive: 0` for
the finish-time polish call. The factory still defaults production to
FoundationModels unless `EPOS_POLISH_ENGINE=ollama` is set.

Local prerequisites were verified on 2026-06-03: `ollama list` shows
`qwen3:1.7b` installed at 1.4 GB, `ollama ps` is empty at rest, and saved
recordings exist under `$HOME/Library/Caches/Epos/recordings`.

## Hypothesis

Fresh static, raw-candidate, dogfood, and resource measurements will establish
whether the current local Ollama baseline has enough quality and latency headroom
to justify prompt, option, or model levers.

## Read When Pulling This Lever

- `specs/local-ollama-polish-experiment.md`
- `Sources/Epos/Speech/OllamaPolishEngine.swift`
- `Sources/Epos/Speech/OllamaHTTPPolishClient.swift`
- `Sources/Epos/Speech/OllamaPolishPrompt.swift`
- `Sources/Epos/Speech/TranscriptPolisher.swift`
- `Tests/EposTests/OllamaPolishEvalTests.swift`
- `Tests/EposTests/DogfoodPipelineEvalTests.swift`
- `Tests/EposTests/OllamaRawCandidateEvalSupport.swift`
- `Tests/EposTests/SavedRecordingEvalSupport.swift`

## Evidence Needed

- Static polish JSONL comparing strict and relaxed, cold and prewarm variants.
- Static relaxed raw-candidate JSONL with strict guard diagnostics.
- Saved-dogfood JSONL with production Ollama plus relaxed shadow candidates.
- Resource measurements before and after evals, including `ollama ps`.
- Manual inspection of changed candidates, strict guard rejections, and
  model-only improvements.
- Decision on whether the next lever should target prompt shape, request
  options, model choice, guard policy, or be rejected as no actionable headroom.

## Attempts

### 2026-06-03

- Change: Created this baseline checkpoint only; no production behavior changed.
- Commands:
  - `command -v ollama && ollama list && ollama ps`
  - `fd -e wav . "$HOME/Library/Caches/Epos/recordings" -t f | wc -l`
  - `du -sh "$HOME/Library/Caches/Epos/recordings"`
  - `ls -lt "$HOME/Library/Caches/Epos/recordings"/*.wav | head -n 10`
  - Resource capture in `.build/evals/ollama-baseline-resource-20260603.txt` using `ollama ps`, `ps -axo pid,rss,vsz,pcpu,pmem,command`, and local Ollama `/api/chat` keepalive/unload requests.
  - `EPOS_RUN_OLLAMA_POLISH_EVAL=1 EPOS_EVAL_OUTPUT=.build/evals/ollama-polish-baseline-20260603.jsonl swift test --filter 'OllamaPolishEvalTests/testQwenPolishOverCorpus'`
  - `EPOS_RUN_OLLAMA_RAW_CANDIDATE_EVAL=1 EPOS_EVAL_OUTPUT=.build/evals/ollama-raw-candidate-baseline-20260603.jsonl swift test --filter 'OllamaPolishEvalTests/testRelaxedRawCandidatesBypassPolisherOverCorpus'`
  - `EPOS_POLISH_ENGINE=ollama EPOS_RUN_DOGFOOD_EVAL=1 EPOS_EVAL_SHADOW_RELAXED_OLLAMA=1 EPOS_EVAL_LATEST=1 EPOS_EVAL_LIMIT=11 EPOS_EVAL_OUTPUT=.build/evals/dogfood-pipeline-ollama-baseline-latest11-20260603.jsonl swift test --filter 'DogfoodPipelineEvalTests'`
  - `EPOS_POLISH_ENGINE=ollama EPOS_RUN_DOGFOOD_EVAL=1 EPOS_EVAL_SHADOW_RELAXED_OLLAMA=1 EPOS_EVAL_LATEST=1 EPOS_EVAL_OUTPUT=.build/evals/dogfood-pipeline-ollama-baseline-all-20260603.jsonl swift test --filter 'DogfoodPipelineEvalTests'`
  - `jq -s ... .build/evals/ollama-polish-baseline-20260603.jsonl`
  - `jq -s ... .build/evals/ollama-raw-candidate-baseline-20260603.jsonl`
  - `jq -s ... .build/evals/dogfood-pipeline-ollama-baseline-all-20260603.jsonl`
  - `jq -r ... .build/evals/dogfood-pipeline-ollama-baseline-all-20260603.jsonl` to extract every production change, production guard rejection, and relaxed-shadow difference for manual inspection.
  - `ollama ps` after eval completion.
- Results:
  - Local prerequisites: `/opt/homebrew/bin/ollama` exists; `qwen3:1.7b` installed, 1.4 GB on disk; 111 saved `.wav` recordings found under `$HOME/Library/Caches/Epos/recordings`; recordings directory size is 82 MB.
  - Static polish: 40 rows, all engine calls `success`. Strict cold mean 1.146s; strict prewarm mean 0.429s; relaxed cold mean 1.199s; relaxed prewarm mean 0.422s.
  - Static polish outcomes: applied=2, deterministicCleanup=6, guardRejected=6, sameText=26. Rejections were all `content-tokens-changed`.
  - Static raw candidates: 20 rows, all candidate calls `success`. Cold mean 1.196s; prewarm mean 0.420s. Strict gate outcomes were deterministicCleanup=4, guardRejected=4, sameText=12.
  - Latest-11 dogfood path check passed in 38.491s: applied=3, sameText=8, all engine calls `success`.
  - Full dogfood passed in 357.053s over 111 recordings and 443.1s of audio: applied=8, guardRejected=6, sameText=97, all engine calls `success`.
  - Full dogfood production polish latency: mean 0.449s, p95 0.690s, max 1.280s.
  - Full dogfood relaxed-shadow latency: mean 1.236s, p95 1.496s, max 2.085s.
  - Full dogfood relaxed shadow: applied=5, guardRejected=5, sameText=101; 16 raw candidates differed from production, but only 5 strict-gate outputs differed from canonicalized raw.
  - Resource check: idle `ollama ps` empty; kept-alive request loaded `qwen3:1.7b` at 1.8-1.9 GB, 100% GPU, 2048-4096 context depending on request; post-eval `ollama ps` empty. The production `keep_alive: 0` path unloads between calls.
- Manual inspection:
  - Production-applied changes were all content-preserving under the guard, but mixed quality: useful capitalization fixes (`seems` -> `Seems`, `Improvements` -> `improvements`) and several low-value punctuation/case edits (`And.` -> `And`, `Follow up...` -> `follow up...`, terminal period drops).
  - Production guard rejections were correct: ordinal normalization (`1st` -> `first`), word drops (`Make 2 tickets for this.` -> `make 2 tickets`), added `/no_think`, question mark removal, and an extreme compression (`Drop my entire transcription.` -> `transcription`).
  - Relaxed shadow did not reveal a safe high-value improvement stream. Differences were mostly canonicalizer-owned known-term corrections, terminal punctuation disagreements, and risky dropped lead-ins such as `Okay` or `An example from yesterday was`.
  - Static raw candidates confirmed the same two tempting but guard-rejected edits: `1st` -> `first` and dictated `comma` -> `,`.
- Decision: Baseline is implemented and verified. Keep `qwen3:1.7b` as the current local control; do not loosen the guard or change production model from this evidence. Pull prompt-shape next to reduce accepted punctuation/case churn and measure whether a stricter Ollama prompt preserves useful capitalization while avoiding low-value period drops and lowercasing.
- Follow-up: L2 prompt shape.

## Decision

implemented+verified. The current baseline is usable enough to keep measuring,
but the next evidence-backed lever is prompt shape, not guard policy, request
options, or model choice.
