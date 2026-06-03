# L2 Prompt Shape

Status: implemented+verified

## Why This Lever Exists

The L1 full dogfood baseline over 111 saved recordings showed all Ollama engine
calls succeeding with acceptable short-dictation latency, but manual inspection
found avoidable accepted churn:

- Useful accepted edits: sentence-initial capitalization after punctuation and
  proper casing fixes such as `Improvements` -> `improvements`.
- Low-value accepted edits: terminal period drops on short fragments and
  complete commands, plus one initial lowercase change (`Follow up...` ->
  `follow up...`).
- Correct guard rejections: word drops, `/no_think` insertion, question mark
  removal, ordinal normalization, and compression.

The strict guard is doing important safety work. The next lever should try to
shape Qwen's candidate before the guard, rather than accepting more candidate
classes.

## Hypothesis

A more conservative Ollama strict prompt can reduce terminal-punctuation and
initial-case churn while preserving the useful safe capitalization fixes, without
increasing guard rejections, latency, or risky accepted edits.

## Read When Pulling This Lever

- `Sources/Epos/Speech/OllamaPolishPrompt.swift`
- `Sources/Epos/Speech/FoundationModelsPolishPrompt.swift`
- `Sources/Epos/Speech/TranscriptPolisher.swift`
- `Sources/Epos/Speech/TranscriptPolisherGuard.swift`
- `Tests/EposTests/OllamaPolishEvalTests.swift`
- `Tests/EposTests/DogfoodPipelineEvalTests.swift`
- `.build/evals/ollama-polish-baseline-20260603.jsonl`
- `.build/evals/ollama-raw-candidate-baseline-20260603.jsonl`
- `.build/evals/dogfood-pipeline-ollama-baseline-all-20260603.jsonl`

## Evidence Needed

- Eval-only conservative prompt variant implemented without changing production
  default behavior until JSONL evidence supports it.
- Static polish JSONL comparing baseline strict/relaxed against the conservative
  prompt.
- Saved-dogfood JSONL over a targeted 10-20 recording slice covering baseline
  production changes, guard rejections, relaxed-shadow differences, and clean
  controls. Do not replay all 111 recordings for every lever.
- Manual inspection of every changed candidate and every guard rejection.
- Resource check with `ollama ps` after evals.
- Decision: promote prompt to production, keep eval-only, or reject.

## Attempts

### 2026-06-03

- Change: Added an eval-only `conservative` Ollama prompt style, static prompt-style
  selection via `EPOS_OLLAMA_EVAL_PROMPT_STYLES`, dogfood prompt selection via
  `EPOS_OLLAMA_PROMPT_STYLE`, prompt-style JSONL fields for dogfood rows, and
  targeted saved-recording selection via `EPOS_EVAL_RECORDING_FILES`. Production
  default remains unchanged.
- Commands:
  - `swift test --filter OllamaPolishEngineTests`
  - `swift test --filter DogfoodPipelineEvalTests`
  - `swift test --filter SavedRecordingEvalSupportTests`
  - `EPOS_RUN_OLLAMA_POLISH_EVAL=1 EPOS_OLLAMA_EVAL_PROMPT_STYLES=strict,conservative,relaxed EPOS_EVAL_OUTPUT=.build/evals/ollama-polish-prompt-shape-20260603.jsonl swift test --filter 'OllamaPolishEvalTests/testQwenPolishOverCorpus'`
  - `EPOS_RUN_OLLAMA_POLISH_EVAL=1 EPOS_OLLAMA_EVAL_PROMPT_STYLES=strict,conservative EPOS_EVAL_OUTPUT=.build/evals/ollama-polish-prompt-shape-conservative-v2-20260603.jsonl swift test --filter 'OllamaPolishEvalTests/testQwenPolishOverCorpus'`
  - Target file list saved to `.build/evals/ollama-prompt-shape-target-recordings-20260603.txt` with 19 recordings covering L1 production changes, guard rejections, relaxed-shadow differences, and clean controls.
  - `EPOS_POLISH_ENGINE=ollama EPOS_OLLAMA_PROMPT_STYLE=strict EPOS_RUN_DOGFOOD_EVAL=1 EPOS_EVAL_SHADOW_RELAXED_OLLAMA=1 EPOS_EVAL_RECORDING_FILES="$(cat .build/evals/ollama-prompt-shape-target-recordings-20260603.txt)" EPOS_EVAL_OUTPUT=.build/evals/dogfood-pipeline-ollama-prompt-shape-strict-target19-20260603.jsonl swift test --filter 'DogfoodPipelineEvalTests'`
  - `EPOS_POLISH_ENGINE=ollama EPOS_OLLAMA_PROMPT_STYLE=conservative EPOS_RUN_DOGFOOD_EVAL=1 EPOS_EVAL_SHADOW_RELAXED_OLLAMA=1 EPOS_EVAL_RECORDING_FILES="$(cat .build/evals/ollama-prompt-shape-target-recordings-20260603.txt)" EPOS_EVAL_OUTPUT=.build/evals/dogfood-pipeline-ollama-prompt-shape-conservative-v2-target19-20260603.jsonl swift test --filter 'DogfoodPipelineEvalTests'`
  - `jq -s ... .build/evals/ollama-polish-prompt-shape-conservative-v2-20260603.jsonl`
  - `jq -s ... .build/evals/dogfood-pipeline-ollama-prompt-shape-strict-target19-20260603.jsonl`
  - `jq -s ... .build/evals/dogfood-pipeline-ollama-prompt-shape-conservative-v2-target19-20260603.jsonl`
  - `jq -r ... .build/evals/dogfood-pipeline-ollama-prompt-shape-conservative-v2-target19-20260603.jsonl` to inspect every changed output and guard rejection.
  - `ollama ps`
- Results:
  - Static strict/conservative v2: 40 rows, all engine calls `success`. Strict cold/prewarm outcomes each applied=1, deterministicCleanup=1, guardRejected=1, sameText=7. Conservative cold/prewarm outcomes each deterministicCleanup=2, sameText=8, guardRejected=0.
  - Static prewarm latency: strict mean 0.432s, conservative mean 0.451s.
  - Target19 strict dogfood: applied=8, guardRejected=6, sameText=5, mean polish 0.431s, max 0.892s.
  - Target19 conservative v2 dogfood: applied=3, guardRejected=3, sameText=13, mean polish 0.492s, max 0.804s.
  - Conservative v2 preserved the useful casing fixes for `seems` -> `Seems` and `Improvements` -> `improvements`, and it avoided strict's bad lowercase/period churn on `Follow up...`, `Open next feed...`, `And.`, `Not sure...`, and `So let's see if.`.
  - `ollama ps` was empty after eval completion; active target eval poll again showed `qwen3:1.7b` at 1.8 GB / 2048 context while loaded.
- Manual inspection:
  - Changed conservative v2 outputs: two useful casing fixes and one remaining low-value terminal-period drop on a long transcript ending `And.`.
  - Conservative v2 guard rejections were appropriate: `/no_think` insertion, dropped lead-in (`An example from yesterday was...` -> `I said...`), and dropped/lowercased `Okay` in a canonicalizer-owned `CLAUDE.md` case.
  - Model-only improvements not covered by deterministic cleanup were the two casing fixes. Conservative v2 retained those while reducing low-value output churn.
- Decision: Implemented and verified as an eval lever. Do not treat prompt shape alone as complete production proof because Qwen still accepted one final-period drop despite explicit prompt text. Carry the conservative prompt forward, but pull L3 to enforce final-period preservation in the guard before promoting a production behavior change.
- Follow-up: L3 final-period guard.

## Decision

implemented+verified. Conservative prompt shape is better than strict on the
targeted slice, but not sufficient alone because one final-period drop remained.
