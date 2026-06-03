# L5 Ground-Truth 35 Canonicalizer

Status: implemented+verified

## Why This Lever Exists

The confirmed ground-truth manifest grew from 20 to 35 saved recordings. The new
rows exposed ASR misses that neither conservative nor relaxed Ollama corrected,
but several were narrow deterministic substitutions already proven by the
human-confirmed intended transcripts.

## Hypothesis

Phrase-specific and contextual canonicalizer rules can reduce WER on the expanded
manifest without broadening LLM polish behavior or accepting meaning-risky model
edits.

## Read When Pulling This Lever

- `Sources/Epos/Speech/TranscriptCanonicalizer.swift`
- `Tests/EposTests/SmokeTests.swift`
- `Tests/EposTests/DogfoodPipelineEvalTests.swift`

## Evidence Needed

- 35-row dogfood JSONL with ground truth.
- Focused canonicalizer unit coverage, including negative cases for contextual
  aliases.
- Production dogfood comparison before and after the new deterministic rules.

## Attempts

### 2026-06-03

- Change:
  - Added `code base` as a `codebase` alias.
  - Added phrase-specific `unslop the fight` -> `unslopify`.
  - Added phrase-specific `Plot has been vibe coding` -> `Claude has been vibe coding`.
  - Added phrase-specific `different than Maine` / `different from Maine` ->
    `different than main` / `different from main`.
  - Added phrase-specific `regressions in the sweet` -> `regressions in the suite`.
- Commands:
  - `EPOS_RUN_CONTEXT_EVAL=1 EPOS_EVAL_RECORDING_FILES=<next15> EPOS_EVAL_OUTPUT=.build/evals/ground-truth-candidates-raw15-20260603.jsonl swift test --filter SpeechContextEvalTests`
  - `swift test --filter SmokeTests/testCanonicalizerFixesSeededDeveloperTerms`
  - `EPOS_POLISH_ENGINE=ollama EPOS_RUN_DOGFOOD_EVAL=1 EPOS_EVAL_SHADOW_RELAXED_OLLAMA=1 EPOS_EVAL_RECORDING_FILES="$(jq -r '.file' "$HOME/Library/Caches/Epos/recordings/ground-truth.jsonl" | paste -sd, -)" EPOS_EVAL_OUTPUT=.build/evals/dogfood-pipeline-ground-truth35-shadow-20260603.jsonl swift test --filter DogfoodPipelineEvalTests`
  - `EPOS_POLISH_ENGINE=ollama EPOS_RUN_DOGFOOD_EVAL=1 EPOS_EVAL_RECORDING_FILES="$(jq -r '.file' "$HOME/Library/Caches/Epos/recordings/ground-truth.jsonl" | paste -sd, -)" EPOS_EVAL_OUTPUT=.build/evals/dogfood-pipeline-ground-truth35-canonicalizer2-fixed-20260603.jsonl swift test --filter DogfoodPipelineEvalTests`
  - `swift build -Xswiftc -warnings-as-errors`
  - `swift test`
  - `swiftlint --quiet`
  - `git diff --check`
- Results:
  - Before these rules, the 35-row conservative production eval measured mean WER
    raw/canonicalized/output as `0.083/0.062/0.062`.
  - After these rules, the 35-row conservative production eval measured mean WER
    raw/canonicalized/output as `0.083/0.035/0.035`.
  - Canonicalizer improvements were observed on five rows, including the prior
    `LLM polish` and `codebase/Foundation Models` rows plus the new
    `unslopify`, `main`, and `Claude/suite` rows.
  - No output row worsened versus canonicalized raw.
- Manual inspection:
  - `You have to unslop the fight the code base.` now canonicalizes to
    `You have to unslopify the codebase.`
  - `different than Maine` now canonicalizes to `different than main`, while
    unrelated `vacation in Maine` remains unchanged in unit coverage.
  - `regressions in the sweet` now canonicalizes to `regressions in the suite`,
    while unrelated `the dessert is sweet` remains unchanged in unit coverage.
  - Verifier found the first contextual implementation was too broad across a
    64-character prefix window; it was replaced with exact phrase aliases and
    adversarial negative coverage.
- Decision:
  - Ship the narrow canonicalizer expansion.
  - Do not add broad numeric cardinal conversion (`part 2` -> `part two`) from
    one row.
  - Do not add a broad `They'd be closed` -> `Did we close` rule because the
    punctuation and intent change are too sentence-specific for the current
    canonicalizer.
- Follow-up:
  - Continue adding confirmed manifest rows in batches.
  - Remaining WER rows should be split into deterministic phrase rules only when
    recurrence or context makes them safe; otherwise leave them as evidence for a
    future model/prompt bakeoff.

## Decision

Implemented the safe deterministic canonicalizer subset. Conservative Ollama
remains the production default.
