# L3 Final Period Guard

Status: implemented+verified

## Why This Lever Exists

L1 and L2 dogfood evidence showed repeated low-value accepted edits where Qwen
removed an existing terminal period. The conservative prompt reduced this but
did not eliminate it: target19 conservative v2 still changed a long transcript
ending `And.` to `And`.

The retention guard already rejects `?` and `!` removal through symbol usage,
but `.` is intentionally unbudgeted so final-period deletion can pass. A tiny
guard rule can reject dropping an existing final period while preserving the
current ability to add a period to raw text that lacks one.

## Hypothesis

Rejecting candidates that remove an existing final period will eliminate the
remaining low-value accepted period drops without blocking useful casing fixes or
deterministic filler cleanup.

## Read When Pulling This Lever

- `Sources/Epos/Speech/TranscriptPolisherGuard.swift`
- `Tests/EposTests/TranscriptPolisherGuardTests.swift`
- `Tests/EposTests/TranscriptPolisherTests.swift`
- `.build/evals/dogfood-pipeline-ollama-prompt-shape-strict-target19-20260603.jsonl`
- `.build/evals/dogfood-pipeline-ollama-prompt-shape-conservative-v2-target19-20260603.jsonl`

## Evidence Needed

- Unit tests proving final-period removal rejects, while adding a final period to
  raw text without one still passes when content is retained.
- Static polish JSONL with the chosen prompt variant after the guard change.
- Targeted saved-dogfood JSONL over the same 19-recording slice used by L2.
- Manual inspection of changed outputs and guard rejections.
- Resource check with `ollama ps` after evals.

## Attempts

### 2026-06-03

- Change: Added a retention-guard check that rejects candidates when raw text
  ends in `.` but the polished candidate does not. This preserves the existing
  behavior that can accept a restored final period when raw text has no final
  period. After JSONL comparison, promoted the Ollama production default prompt
  from `strict` to `conservative`; strict remains selectable for eval
  comparison.
- Commands:
  - `swift test --filter TranscriptPolisherGuardTests`
  - `swift test --filter TranscriptPolisherTests`
  - `EPOS_RUN_OLLAMA_POLISH_EVAL=1 EPOS_OLLAMA_EVAL_PROMPT_STYLES=strict,conservative EPOS_EVAL_OUTPUT=.build/evals/ollama-polish-final-period-guard-20260603.jsonl swift test --filter 'OllamaPolishEvalTests/testQwenPolishOverCorpus'`
  - `EPOS_POLISH_ENGINE=ollama EPOS_OLLAMA_PROMPT_STYLE=strict EPOS_RUN_DOGFOOD_EVAL=1 EPOS_EVAL_SHADOW_RELAXED_OLLAMA=1 EPOS_EVAL_RECORDING_FILES="$(cat .build/evals/ollama-prompt-shape-target-recordings-20260603.txt)" EPOS_EVAL_OUTPUT=.build/evals/dogfood-pipeline-ollama-final-period-guard-strict-target19-20260603.jsonl swift test --filter 'DogfoodPipelineEvalTests'`
  - `EPOS_POLISH_ENGINE=ollama EPOS_OLLAMA_PROMPT_STYLE=conservative EPOS_RUN_DOGFOOD_EVAL=1 EPOS_EVAL_SHADOW_RELAXED_OLLAMA=1 EPOS_EVAL_RECORDING_FILES="$(cat .build/evals/ollama-prompt-shape-target-recordings-20260603.txt)" EPOS_EVAL_OUTPUT=.build/evals/dogfood-pipeline-ollama-final-period-guard-conservative-target19-20260603.jsonl swift test --filter 'DogfoodPipelineEvalTests'`
  - `EPOS_POLISH_ENGINE=ollama EPOS_RUN_DOGFOOD_EVAL=1 EPOS_EVAL_SHADOW_RELAXED_OLLAMA=1 EPOS_EVAL_RECORDING_FILES="$(cat .build/evals/ollama-prompt-shape-target-recordings-20260603.txt)" EPOS_EVAL_OUTPUT=.build/evals/dogfood-pipeline-ollama-final-production-target19-20260603.jsonl swift test --filter 'DogfoodPipelineEvalTests'`
  - `swift test --filter OllamaPolishEngineTests`
  - `swift test --filter PolishEngineFactoryTests`
  - `jq -s ... .build/evals/ollama-polish-final-period-guard-20260603.jsonl`
  - `jq -s ... .build/evals/dogfood-pipeline-ollama-final-production-target19-20260603.jsonl`
  - `jq -r ... .build/evals/dogfood-pipeline-ollama-final-production-target19-20260603.jsonl` to inspect every accepted change, guard rejection, and relaxed-shadow difference.
  - `ollama ps`
- Results:
  - Guard unit tests passed, including rejection of `And.` -> `And`,
    `Not sure you should ask.` -> `Not sure you should ask`, and the long
    `... And.` target-recording case.
  - Static strict/conservative eval: 40 rows, all engine calls `success`.
    Conservative cold/prewarm outcomes each deterministicCleanup=2,
    sameText=8, guardRejected=0. Strict cold/prewarm each had applied=1,
    deterministicCleanup=1, guardRejected=1, sameText=7.
  - Target19 post-guard strict dogfood: applied=2, guardRejected=12,
    sameText=5, mean polish 0.428s, max 0.731s.
  - Target19 post-guard conservative dogfood: applied=2, guardRejected=4,
    sameText=13, mean polish 0.503s, max 0.866s.
  - Target19 production-default dogfood, without `EPOS_OLLAMA_PROMPT_STYLE`,
    reported `polish prompt style: conservative` and matched the conservative
    shape: applied=2, guardRejected=4, sameText=13, mean polish 0.489s, max
    0.868s.
  - `ollama ps` was empty after eval completion.
- Manual inspection:
  - Accepted production changes were the two useful casing fixes:
    `? seems` -> `? Seems` and `Improvements` -> `improvements`.
  - The final-period guard rejected the remaining low-value deletion:
    long transcript ending `And.` -> `And`, with
    `sentence-boundary-changed boundaryDiffs=.:2->1,?:2->2,!:0->0`.
  - Other production rejections remained appropriate: `/no_think` insertion,
    dropped lead-in (`An example from yesterday was...` -> `I said...`), and
    dropped/lowercased `Okay` in a canonicalizer-owned `CLAUDE.md` case.
  - Shadow-relaxed differences did not produce a better safe output: ordinal
    normalization and lead-in removals stayed rejected, while production output
    remained unchanged.
- Decision: Implemented and verified. Keep the final-period guard and make the
  conservative prompt the Ollama production default.
- Follow-up: No new in-scope lever is justified by current evidence. Larger
  model bakeoffs, relaxed guard acceptance, spoken-symbol conversion, and
  canonicalizer ownership changes remain out of scope without new evidence.

## Decision

implemented+verified. Existing terminal periods are now protected by the guard,
and Ollama production polish defaults to the conservative prompt.
