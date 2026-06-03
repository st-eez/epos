# L4 Ground-Truth 20 Corrections

Status: implemented+verified

## Why This Lever Exists

The saved-recording dogfood harness can now score against a human transcript
manifest. A 20-row manifest under `~/Library/Caches/Epos/recordings/ground-truth.jsonl`
was spot-checked by Steve, so current changes can be measured against intended
words instead of only against Apple Speech output.

## Hypothesis

High-confidence recurring ASR misses should be handled by deterministic
canonicalizer rules, while the polish guard can safely allow exact numeric
ordinal normalization. The production Ollama prompt should not be broadened to
relaxed unless relaxed improves WER without accepted meaning-risky output.

## Read When Pulling This Lever

- `Sources/Epos/Speech/TranscriptCanonicalizer.swift`
- `Sources/Epos/Speech/TranscriptPolisherGuard.swift`
- `Sources/Epos/Speech/OllamaPolishPrompt.swift`
- `Sources/Epos/Speech/FoundationModelsPolishPrompt.swift`
- `Tests/EposTests/SmokeTests.swift`
- `Tests/EposTests/TranscriptPolisherGuardTests.swift`
- `Tests/EposTests/TranscriptPolisherTests.swift`

## Evidence Needed

- 20-row dogfood JSONL with ground truth.
- Focused unit coverage for added canonicalizer rules and exact ordinal guard
  behavior.
- Conservative and relaxed dogfood comparisons.

## Attempts

### 2026-06-03

- Change:
  - Added canonicalizer rules for `LOL polish` -> `LLM polish`, `foundation models`
    / `foundational models` -> `Foundation Models`, and `code basis` -> `codebase`.
  - Allowed one-way exact guard matching from standalone numeric ordinals
    (`1st`, `21st`) to matching ordinal words (`first`, `twenty-first`).
  - Updated conservative Ollama and Foundation Models prompts to state that
    standalone numeric ordinal conversion is allowed cleanup.
- Commands:
  - `swift test --filter SmokeTests/testCanonicalizerFixesSeededDeveloperTerms`
  - `swift test --filter TranscriptPolisherGuardTests`
  - `swift test --filter TranscriptPolisherTests/testPolishAcceptsExactNumericOrdinalNormalization`
  - `EPOS_POLISH_ENGINE=ollama EPOS_RUN_DOGFOOD_EVAL=1 EPOS_EVAL_RECORDING_FILES="$(jq -r '.file' "$HOME/Library/Caches/Epos/recordings/ground-truth.jsonl" | paste -sd, -)" EPOS_EVAL_OUTPUT=.build/evals/dogfood-pipeline-ground-truth20-canonicalizer-20260603.jsonl swift test --filter DogfoodPipelineEvalTests`
  - `EPOS_POLISH_ENGINE=ollama EPOS_RUN_DOGFOOD_EVAL=1 EPOS_EVAL_RECORDING_FILES=2026-06-02_15-36-43-967.wav EPOS_EVAL_OUTPUT=.build/evals/dogfood-pipeline-ground-truth-ordinal-single-required-20260603.jsonl swift test --filter DogfoodPipelineEvalTests`
  - `EPOS_POLISH_ENGINE=ollama EPOS_OLLAMA_PROMPT_STYLE=relaxed EPOS_RUN_DOGFOOD_EVAL=1 EPOS_EVAL_RECORDING_FILES="$(jq -r '.file' "$HOME/Library/Caches/Epos/recordings/ground-truth.jsonl" | paste -sd, -)" EPOS_EVAL_OUTPUT=.build/evals/dogfood-pipeline-ground-truth20-relaxed-ordinal-20260603.jsonl swift test --filter DogfoodPipelineEvalTests`
  - `EPOS_POLISH_ENGINE=ollama EPOS_RUN_DOGFOOD_EVAL=1 EPOS_EVAL_SHADOW_RELAXED_OLLAMA=1 EPOS_EVAL_RECORDING_FILES="$(jq -r '.file' "$HOME/Library/Caches/Epos/recordings/ground-truth.jsonl" | paste -sd, -)" EPOS_EVAL_OUTPUT=.build/evals/dogfood-pipeline-ground-truth20-final-shadow-20260603.jsonl swift test --filter DogfoodPipelineEvalTests`
- Results:
  - Conservative before this lever: mean WER raw/canonicalized/output
    `0.070/0.053/0.053`.
  - After canonicalizer rules, conservative mean WER became `0.070/0.034/0.034`;
    output never worsened versus canonicalized raw.
  - Conservative still did not convert `1st` -> `first`, even after the guard and
    prompt allowed it.
  - Relaxed with the strict guard converted `1st` -> `first`; full 20-row relaxed
    mean WER became `0.070/0.034/0.030`, with one output row better than
    canonicalized raw and zero accepted output rows worse than canonicalized raw.
  - Relaxed also attempted to drop `Okay` once; the guard rejected it and kept raw.
  - Guard tests reject malformed numeric ordinal surfaces such as `11st` ->
    `eleventh` and `22th` -> `twenty-second`.
- Manual inspection:
  - `LLM polish / cleanup.` is now exact after canonicalization.
  - The long `codebase` / `Foundation Models` row dropped from `0.059` raw WER to
    `0.015` canonicalized/output WER.
  - The relaxed-only ordinal win is real, but relaxed remains more willing to
    propose meaning-risky deletion candidates.
- Decision:
  - Ship the canonicalizer rules and exact ordinal guard allowance.
  - Keep conservative as the production Ollama default.
  - Keep relaxed as an eval/shadow candidate until a larger ground-truth set proves
    its accepted output quality gain outweighs extra guard churn.
- Follow-up:
  - Expand the human-confirmed manifest beyond 20 rows before changing the
    production Ollama prompt style.
  - Investigate remaining WER rows separately: `seeing` vs `saying`, extra `the`,
    leading `I`, `It'd be add`, missing `be`, and `redundant, and you can remove`.

## Decision

Implemented the safe deterministic and guard changes. Relaxed prompt remains
diagnostic-only.
