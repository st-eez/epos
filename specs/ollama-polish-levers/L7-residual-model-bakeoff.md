# L7 Residual Model Bakeoff

Status: implemented+verified

## Why This Lever Exists

L6 classified the remaining 35-row dogfood residuals and found several rows
that looked like prompt/model candidates rather than canonicalizer mistakes.
The existing static eval could only show whether polish safely cleaned Apple's
transcript; it could not score residual model output against the human intended
transcript.

## Hypothesis

Running prompt and model variants only on residual dogfood rows will identify a
local Ollama variant that improves WER after the strict production guard.

## Read When Pulling This Lever

- `Tests/EposTests/OllamaPolishEvalTests.swift`
- `Tests/EposTests/OllamaRawCandidateEvalSupport.swift`
- `.build/evals/ollama-residual-bakeoff-qwen17b-qwen4b-post-be-cleaner-20260603.jsonl`

## Evidence Needed

- Residual bakeoff JSONL scored against `humanIntendedTranscript`.
- Per-variant candidate and strict-gate WER deltas against canonicalized raw.
- Manual inspection of any candidate improvement or guard rejection.
- Resource sanity check with `ollama ps` after the run.

## Attempts

### 2026-06-03

- Change:
  - Added gated `testResidualRowsPromptModelBakeoff`.
  - The test loads dogfood pipeline JSONL, filters rows with ground truth and
    nonzero output WER, runs configured prompt/model variants, logs raw model
    candidate plus strict-gate output, and scores both against the human
    intended transcript.
  - Added `EPOS_RUN_OLLAMA_RESIDUAL_BAKEOFF`,
    `EPOS_OLLAMA_RESIDUAL_SOURCE`, and `EPOS_OLLAMA_EVAL_MODELS`.
- Commands:
  - `swift test --filter OllamaPolishEvalTests/testResidualRowsPromptModelBakeoff`
  - `EPOS_RUN_OLLAMA_RESIDUAL_BAKEOFF=1 EPOS_OLLAMA_RESIDUAL_SOURCE=.build/evals/dogfood-pipeline-ground-truth35-ordinal-cleaner-20260603.jsonl EPOS_EVAL_OUTPUT=.build/evals/ollama-residual-bakeoff-qwen17b-post-ordinal-20260603.jsonl swift test --filter OllamaPolishEvalTests/testResidualRowsPromptModelBakeoff`
  - `ollama pull qwen3:4b`
  - `EPOS_RUN_OLLAMA_RESIDUAL_BAKEOFF=1 EPOS_OLLAMA_EVAL_MODELS=qwen3:4b EPOS_OLLAMA_RESIDUAL_SOURCE=.build/evals/dogfood-pipeline-ground-truth35-ordinal-cleaner-20260603.jsonl EPOS_EVAL_OUTPUT=.build/evals/ollama-residual-bakeoff-qwen4b-post-ordinal-20260603.jsonl swift test --filter OllamaPolishEvalTests/testResidualRowsPromptModelBakeoff`
  - `EPOS_RUN_OLLAMA_RESIDUAL_BAKEOFF=1 EPOS_OLLAMA_EVAL_MODELS=qwen3:1.7b,qwen3:4b EPOS_OLLAMA_RESIDUAL_SOURCE=.build/evals/dogfood-pipeline-ground-truth35-be-cleaner-20260603.jsonl EPOS_EVAL_OUTPUT=.build/evals/ollama-residual-bakeoff-qwen17b-qwen4b-post-be-cleaner-20260603.jsonl swift test --filter OllamaPolishEvalTests/testResidualRowsPromptModelBakeoff`
  - `ollama ps`
- Results:
  - Ungated skip path passed.
  - On the post-ordinal 9-row source, `qwen3:1.7b` produced no candidate or
    strict-gate WER improvement.
  - On the post-ordinal 9-row source, `qwen3:4b` strict/relaxed candidates
    fixed `seems to getting` -> `seems to be getting`, but the strict guard
    correctly rejected the helper-word insertion as `content-tokens-changed`.
    Gate WER stayed flat.
  - After deterministic cleanup removed that row from the residual set, the
    combined 8-row bakeoff showed `gateBetter=0` and `gateWorse=0` for every
    qwen3:1.7b and qwen3:4b prompt/prewarm variant.
  - qwen3:4b conservative/relaxed produced worse candidates on at least one
    row; the guard caught them, but there was no production gain to justify the
    larger model.
  - `ollama ps` was empty after evals.
- Manual inspection:
  - The only true candidate gain was the missing `be` row, which is better
    handled by a narrow deterministic policy than by switching production to
    qwen3:4b.
  - Remaining rows are mostly ASR semantic misses, ground-truth/style
    ambiguity, or meaning-risky grammar rewrites.
- Decision:
  - Keep qwen3:1.7b as the production Ollama baseline.
  - Do not change production prompt style or model size from this evidence.
  - Keep the residual bakeoff harness as the next model-bakeoff gate.
- Follow-up:
  - Future model tests should run this residual harness first, then dogfood,
    and should not be considered useful unless strict-gate output improves WER.

## Decision

Residual model/prompt bakeoff is implemented. Current evidence rejects a
qwen3:4b production switch and rejects prompt changes as an immediate polish
improvement.
