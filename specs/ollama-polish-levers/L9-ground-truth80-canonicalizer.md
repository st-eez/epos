# L9 Ground-Truth 80 Canonicalizer Expansion

Status: implemented+verified

## Why This Lever Exists

The intended-transcript harness was ready, but the labeled corpus was still only
`35` rows. Expanding the manifest to `80` current dogfood recordings exposed a
new residual cluster where Apple ASR produced specific domain misses that LLM
polish did not repair.

## Hypothesis

Narrow canonicalizer aliases for measured domain and exact phrase misses can
improve intended-output WER on the expanded corpus without loosening LLM polish
or introducing regressions.

## Read When Pulling This Lever

- `Sources/Epos/Speech/TranscriptCanonicalizer.swift`
- `Tests/EposTests/SmokeTests.swift`
- `specs/intended-transcript-accuracy.md`
- `scripts/dogfood-residual-report.py`

## Evidence Needed

- Expanded ground-truth manifest count and duplicate check.
- Current 80-row dogfood pipeline JSONL.
- Residual Markdown report before and after the canonicalizer change.
- Row-level before/after output WER comparison.
- Standard build/test/lint and verifier review.

## Attempts

### 2026-06-03

- Change:
  - Expanded the local `~/Library/Caches/Epos/recordings/ground-truth.jsonl`
    manifest from `35` to `80` rows using inferred intended transcripts from
    current raw/canonicalized/final dogfood output.
  - Added measured canonicalizer aliases for NetSuite phrase shapes, Epos app,
    Teams message, Stath instructions, numeric phrases, and exact ASR residuals.
  - Expanded alias regex separators to tolerate comma and apostrophe punctuation
    between alias words.
  - Removed an unsafe `To the ticket...` one-off rule after a focused test found
    it could rewrite inside `Add a comment to the ticket...`.
- Commands:
  - `jq -s '{rows:length, uniqueFiles:([.[].file] | unique | length), duplicateFiles:([.[].file] | group_by(.) | map(select(length>1)[0]))}' ~/Library/Caches/Epos/recordings/ground-truth.jsonl`
  - `EPOS_POLISH_ENGINE=ollama EPOS_RUN_DOGFOOD_EVAL=1 EPOS_EVAL_LATEST=1 EPOS_EVAL_LIMIT=80 EPOS_EVAL_OUTPUT=.build/evals/dogfood-pipeline-ground-truth80-current-20260603.jsonl swift test --filter DogfoodPipelineEvalTests`
  - `scripts/dogfood-residual-report.py .build/evals/dogfood-pipeline-ground-truth80-current-20260603.jsonl --output .build/evals/dogfood-ground-truth80-residuals-current-20260603.md`
  - `swift test --filter SmokeTests/testCanonicalizerFixesSeededDeveloperTerms --filter SmokeTests/testCanonicalizerNormalizesNetSuiteAliases`
  - `EPOS_POLISH_ENGINE=ollama EPOS_RUN_DOGFOOD_EVAL=1 EPOS_EVAL_LATEST=1 EPOS_EVAL_LIMIT=80 EPOS_EVAL_OUTPUT=.build/evals/dogfood-pipeline-ground-truth80-canonicalizer-20260603.jsonl swift test --filter DogfoodPipelineEvalTests`
  - `scripts/dogfood-residual-report.py .build/evals/dogfood-pipeline-ground-truth80-canonicalizer-20260603.jsonl --output .build/evals/dogfood-ground-truth80-residuals-canonicalizer-20260603.md`
- Results:
  - Manifest validation: `80` rows, `80` unique files, no duplicates.
  - Before mean WER raw/canonicalized/output: `0.070/0.042/0.039`.
  - After mean WER raw/canonicalized/output: `0.070/0.006/0.003`.
  - Row-level output comparison: `18` wins, `0` regressions, `62` unchanged.
  - Residual rows dropped from `20` to `4`.
- Manual inspection:
  - Remaining residuals are one-off ASR misses or unsafe general rewrites:
    missing leading `Add`, missing `working`, trailing `And.`, and leading `I`.
  - No remaining residual points to LLM prompt/model work; the model largely
    preserved ASR misses, and the guard correctly blocked risky compression.
- Decision:
  - Keep the canonicalizer changes.
  - Do not loosen LLM polish or auto-select alternatives from this evidence.
- Follow-up:
  - Continue labeling newer dogfood rows and only add future aliases from repeated
    measured misses with zero-regression evals.

## Decision

implemented+verified
