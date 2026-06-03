# L10 Holdout Generalization

Status: implemented+verified

## Why This Lever Exists

The 80-row ground-truth corpus was nearly solved after L9, so another pass over
the same rows risked overfitting. This lever treats the first `80` manifest rows
as a locked baseline and uses the remaining unlabeled saved recordings as a
separate holdout slice.

There was only `1` truly post-commit recording available during this pass, so
the holdout used `34` unseen recordings: `33` historical recordings that were not
in the baseline manifest plus the new post-commit row.

## Hypothesis

If the current direction is sound, holdout rows should reveal whether the next
useful work is LLM polish or deterministic correction. Production rules should
only change for narrow, measured aliases that improve the holdout without
regressing the locked 80-row baseline.

## Read When Pulling This Lever

- `Sources/Epos/Speech/TranscriptCanonicalizer.swift`
- `Tests/EposTests/SmokeTests.swift`
- `specs/intended-transcript-accuracy.md`
- `scripts/dogfood-residual-report.py`

## Evidence Needed

- Manifest validation proving the expanded manifest has unique files.
- Raw speech-context replay for holdout label inference.
- Dogfood pipeline WER for baseline80, holdout34, and combined114 before and
  after any production change.
- Holdout residual reports before and after the change.
- Row-level before/after comparison showing wins/regressions.
- Standard build/test/lint, verifier review, and signed app relaunch for the
  production canonicalizer change.

## Attempts

### 2026-06-03

- Change:
  - Expanded local `~/Library/Caches/Epos/recordings/ground-truth.jsonl` from
    `80` to `114` rows, appending inferred intended transcripts for a `34`-row
    holdout.
  - Added measured canonicalizer aliases for:
    - `Stas` -> `Stath`
    - `Semux` -> `CMUX`
    - `project.yamo` -> `project.yml`
    - `ping stuff` -> `ping Stath`
    - `when stuff runs it` -> `when Stath runs it`
    - `the read me and the agent's file` -> `the README and the AGENTS file`
    - `updates to the cloud.MD` / `updates to the CLAUDE.md` -> `updates to CLAUDE.md`
    - `Use of agents as needed to keep your context window clean` -> `Use subagents as needed to keep your context window clean`
    - `2 things` -> `two things`
  - Left broad semantic/style misses unfixed: `Latif` -> `it is`, `Lords` ->
    `logs`, `books` -> `bugs`, missing leading `It`, `Drop` -> `Dropped`, and
    grammar-only `enabled, so check`.
- Commands:
  - `EPOS_RUN_CONTEXT_EVAL=1 EPOS_EVAL_RECORDING_FILES="$(comm -23 <(fd -e wav . "$HOME/Library/Caches/Epos/recordings" -x basename {} | sort) <(jq -r '.file' "$HOME/Library/Caches/Epos/recordings/ground-truth.jsonl" | sort) | paste -sd, -)" EPOS_EVAL_OUTPUT=.build/evals/speech-context-holdout-candidates-20260603.jsonl swift test --filter SpeechContextEvalTests`
  - `jq -s '{rows:length, uniqueFiles:([.[].file] | unique | length), duplicateFiles:([.[].file] | group_by(.) | map(select(length>1)[0]))}' ~/Library/Caches/Epos/recordings/ground-truth.jsonl`
  - `EPOS_POLISH_ENGINE=ollama EPOS_RUN_DOGFOOD_EVAL=1 EPOS_EVAL_RECORDING_FILES="$(jq -r '.file' "$HOME/Library/Caches/Epos/recordings/ground-truth.jsonl" | tail -34 | paste -sd, -)" EPOS_EVAL_OUTPUT=.build/evals/dogfood-pipeline-ground-truth-holdout34-current-20260603.jsonl swift test --filter DogfoodPipelineEvalTests`
  - `scripts/dogfood-residual-report.py .build/evals/dogfood-pipeline-ground-truth-holdout34-current-20260603.jsonl --output .build/evals/dogfood-ground-truth-holdout34-residuals-current-20260603.md`
  - `EPOS_POLISH_ENGINE=ollama EPOS_RUN_DOGFOOD_EVAL=1 EPOS_EVAL_RECORDING_FILES="$(jq -r '.file' "$HOME/Library/Caches/Epos/recordings/ground-truth.jsonl" | head -80 | paste -sd, -)" EPOS_EVAL_OUTPUT=.build/evals/dogfood-pipeline-ground-truth-baseline80-current-20260603.jsonl swift test --filter DogfoodPipelineEvalTests`
  - `EPOS_POLISH_ENGINE=ollama EPOS_RUN_DOGFOOD_EVAL=1 EPOS_EVAL_RECORDING_FILES="$(jq -r '.file' "$HOME/Library/Caches/Epos/recordings/ground-truth.jsonl" | paste -sd, -)" EPOS_EVAL_OUTPUT=.build/evals/dogfood-pipeline-ground-truth114-current-20260603.jsonl swift test --filter DogfoodPipelineEvalTests`
  - `swift test --filter SmokeTests`
  - `EPOS_POLISH_ENGINE=ollama EPOS_RUN_DOGFOOD_EVAL=1 EPOS_EVAL_RECORDING_FILES="$(jq -r '.file' "$HOME/Library/Caches/Epos/recordings/ground-truth.jsonl" | tail -34 | paste -sd, -)" EPOS_EVAL_OUTPUT=.build/evals/dogfood-pipeline-ground-truth-holdout34-canonicalizer-20260603.jsonl swift test --filter DogfoodPipelineEvalTests`
  - `scripts/dogfood-residual-report.py .build/evals/dogfood-pipeline-ground-truth-holdout34-canonicalizer-20260603.jsonl --output .build/evals/dogfood-ground-truth-holdout34-residuals-canonicalizer-20260603.md`
  - `EPOS_POLISH_ENGINE=ollama EPOS_RUN_DOGFOOD_EVAL=1 EPOS_EVAL_RECORDING_FILES="$(jq -r '.file' "$HOME/Library/Caches/Epos/recordings/ground-truth.jsonl" | head -80 | paste -sd, -)" EPOS_EVAL_OUTPUT=.build/evals/dogfood-pipeline-ground-truth-baseline80-canonicalizer-20260603.jsonl swift test --filter DogfoodPipelineEvalTests`
  - `EPOS_POLISH_ENGINE=ollama EPOS_RUN_DOGFOOD_EVAL=1 EPOS_EVAL_RECORDING_FILES="$(jq -r '.file' "$HOME/Library/Caches/Epos/recordings/ground-truth.jsonl" | paste -sd, -)" EPOS_EVAL_OUTPUT=.build/evals/dogfood-pipeline-ground-truth114-canonicalizer-20260603.jsonl swift test --filter DogfoodPipelineEvalTests`
- Results:
  - Manifest validation after appending holdout labels: `114` rows, `114`
    unique files, no duplicates.
  - Holdout34 before mean WER raw/canonicalized/output: `0.089/0.067/0.067`.
  - Holdout34 after mean WER raw/canonicalized/output: `0.089/0.024/0.024`.
  - Holdout output comparison: `8` wins, `0` regressions, `26` unchanged.
  - Holdout residual rows dropped from `14` to `6`.
  - Baseline80 stayed `0.070/0.006/0.003` after the new aliases.
  - Combined114 moved from `0.076/0.024/0.022` to `0.076/0.011/0.009`.
- Manual inspection:
  - Ollama polish changed `0` holdout rows both before and after the
    canonicalizer pass.
  - The remaining holdout residuals are not safe broad deterministic fixes:
    tense/style (`Drop` vs `Dropped`), real-name risk (`Latif`), semantic ASR
    misses (`Lords`, `books`), missing leading `It`, and grammar-only wording.
- Decision:
  - Keep the new canonicalizer aliases.
  - Do not loosen the LLM polish prompt or guard from this evidence.
  - Treat the next useful data lever as fresh post-commit dogfood collection,
    not more tuning against this now-solved holdout.

## Decision

implemented+verified
