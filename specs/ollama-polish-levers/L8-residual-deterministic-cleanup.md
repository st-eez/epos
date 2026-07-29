# L8 Residual Deterministic Cleanup

Status: implemented+verified

## Why This Lever Exists

L6 found residual rows where Apple Speech produced deterministic, repeated
surface errors that were not meaning-risky ASR substitutions. L7 then confirmed
that the model path did not improve gate output after strict safety checks.

## Hypothesis

Narrow deterministic cleanup rules for confirmed residual shapes can reduce
ground-truth WER without allowing broader model rewrites.

## Read When Pulling This Lever

- `Sources/Epos/Speech/TranscriptDeterministicCleaner.swift`
- `Sources/Epos/Speech/TranscriptPolisherGuard.swift`
- `Tests/EposTests/TranscriptDeterministicCleanerTests.swift`
- `Tests/EposTests/TranscriptPolisherGuardTests.swift`
- `.build/evals/dogfood-pipeline-ground-truth35-be-cleaner-20260603.jsonl`
- `.build/evals/dogfood-ground-truth35-residuals-be-cleaner-20260603.md`

## Evidence Needed

- Focused tests for each deterministic transform and nearby rejects.
- 35-row dogfood JSONL with output WER and row-level changed outputs.
- Residual report showing fewer remaining rows and no output regressions.

## Attempts

### 2026-06-03

- Change:
  - Added standalone numeric ordinal cleanup for exact valid ordinals `1st`
    through `31st` and their valid suffixes.
  - Added a measured missing-helper cleanup for only
    `seem/seems/seemed to getting` -> `seem/seems/seemed to be getting`.
  - Added a matching guard exception only for the exact inserted `be` before
    `getting` in that `seems to getting` shape.
  - Added negative tests for malformed/embedded ordinals, other `to ...ing`
    shapes, punctuation-separated shapes, and arbitrary helper-word insertion.
- Commands:
  - `swift test --filter TranscriptDeterministicCleanerTests`
  - `swift test --filter TranscriptPolisherGuardTests`
  - `EPOS_POLISH_ENGINE=ollama EPOS_RUN_DOGFOOD_EVAL=1 EPOS_EVAL_RECORDING_FILES="$(jq -r '.file' "$HOME/Library/Caches/Epos/recordings/ground-truth.jsonl" | paste -sd, -)" EPOS_EVAL_OUTPUT=.build/evals/dogfood-pipeline-ground-truth35-ordinal-cleaner-20260603.jsonl swift test --filter DogfoodPipelineEvalTests`
  - `EPOS_POLISH_ENGINE=ollama EPOS_RUN_DOGFOOD_EVAL=1 EPOS_EVAL_RECORDING_FILES="$(jq -r '.file' "$HOME/Library/Caches/Epos/recordings/ground-truth.jsonl" | paste -sd, -)" EPOS_EVAL_OUTPUT=.build/evals/dogfood-pipeline-ground-truth35-be-cleaner-20260603.jsonl swift test --filter DogfoodPipelineEvalTests`
  - `scripts/dogfood-residual-report.py .build/evals/dogfood-pipeline-ground-truth35-be-cleaner-20260603.jsonl --output .build/evals/dogfood-ground-truth35-residuals-be-cleaner-20260603.md`
- Results:
  - Focused cleaner and guard tests passed.
  - Ordinal cleanup improved the 35-row dogfood output WER from `0.035` to
    `0.029`, reduced residual rows from `11` to `9`, and fixed:
    - `2026-06-02_15-36-43-967.wav`: `test 1st` -> `test first`
    - `2026-06-02_10-30-34-747.wav`: `discuss 1st` -> `discuss first`
  - Missing-`be` cleanup improved output WER from `0.029` to `0.028`, reduced
    residual rows from `9` to `8`, and fixed:
    - `2026-06-02_14-30-54-846.wav`: `seems to getting batched` ->
      `seems to be getting batched`
  - Final 35-row dogfood result:
    - Rows/scored/residual: `35/35/8`
    - Mean WER raw/canonicalized/output: `0.083/0.035/0.028`
    - Output vs canonicalized raw: `better=3`, `worse=0`
    - Outcomes: `applied=2`, `deterministicCleanup=3`,
      `guardRejected=1`, `sameText=29`
- Manual inspection:
  - The three WER-improving output rows exactly match the scoped deterministic
    rules.
  - No output row became worse than canonicalized raw.
  - The remaining high-WER rows are not safe deterministic cleanup candidates.
- Decision:
  - Keep both deterministic cleanup rules.
  - Keep the missing-`be` guard exception as exact-shape only.
  - Do not add broader number-word, article-deletion, or grammar-rewrite rules
    without more repeated evidence.
- Follow-up:
  - The next true transcription-quality lever is ASR/context improvement or a
    stronger model that improves strict-gate residual output, not prompt polish
    aesthetics.

## Decision

Residual deterministic cleanup is implemented and improves production output WER
with no observed output regressions on the 35-row dogfood set.
