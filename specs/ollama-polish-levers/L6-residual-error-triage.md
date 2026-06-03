# L6 Residual Error Triage

Status: implemented+verified

## Why This Lever Exists

The 35-row ground-truth eval now measures true transcript quality, but the next
polish change should be chosen from the remaining WER rows instead of by
guessing. A residual-only report makes the remaining errors reviewable without
replaying audio.

## Hypothesis

Classifying rows where final output still has nonzero WER will separate safe
deterministic fixes from prompt/model failures, guard issues, ASR misses, and
ground-truth ambiguity.

## Read When Pulling This Lever

- `scripts/dogfood-residual-report.py`
- `Tests/EposTests/DogfoodPipelineEvalTests.swift`
- `.build/evals/dogfood-ground-truth35-residuals-20260603.md`

## Evidence Needed

- Residual Markdown report generated from the latest 35-row dogfood JSONL.
- Row-by-row classification of every nonzero-output-WER row.
- A concrete decision on the next implementation lever.

## Attempts

### 2026-06-03

- Change:
  - Added `scripts/dogfood-residual-report.py`, a post-hoc Markdown report
    generator for `DogfoodPipelineEvalTests` JSONL artifacts.
  - Generated `.build/evals/dogfood-ground-truth35-residuals-20260603.md`
    from `.build/evals/dogfood-pipeline-ground-truth35-canonicalizer2-fixed-20260603.jsonl`.
  - Classified every residual row below.
- Commands:
  - `python3 -m py_compile scripts/dogfood-residual-report.py`
  - `scripts/dogfood-residual-report.py .build/evals/dogfood-pipeline-ground-truth35-canonicalizer2-fixed-20260603.jsonl --output .build/evals/dogfood-ground-truth35-residuals-20260603.md`
- Results:
  - Rows/scored/residual: `35/35/11`.
  - Mean WER raw/canonicalized/output remained `0.083/0.035/0.035`.
  - Output vs canonicalized raw: `same=35`; current polish did not improve or
    worsen WER against ground truth beyond deterministic canonicalization.
  - Residual outcomes: `applied=2`, `guardRejected=1`, `sameText=8`.
- Manual classification:

| File | Residual | Class | Decision |
| --- | --- | --- | --- |
| `2026-06-02_10-37-07-234.wav` | `They'd be closed` vs `Did we close` | ASR semantic miss | Do not canonicalize. Too meaning-risky without recurrence; use as prompt/model bakeoff row. |
| `2026-06-02_18-03-27-951.wav` | `seeing deprecate the Foundation Models` vs `saying deprecate Foundation Models` | Prompt/model candidate | Do not canonicalize yet. A stronger polish model should repair the ungrammatical phrase and maybe drop the article. |
| `2026-06-02_10-30-34-747.wav` | `1st` vs `first` | Deterministic policy candidate | Consider a scoped ordinal-normalization lever. Needs negative tests around dates, ranks, issue names, and literal typed ordinals. |
| `2026-06-02_17-56-38-709.wav` | `It'd be add ... And.` vs `It would add ...` | Prompt/model candidate; guard not primary | Do not relax the guard from this row. The rejected candidate only changed punctuation and still missed the intended repair. |
| `2026-06-02_15-36-43-967.wav` | `1st` vs `first` | Deterministic policy candidate | Same as the other `1st` row. |
| `2026-06-02_10-30-14-938.wav` | `part 2` vs `part two` | Deterministic policy candidate | Lower priority than ordinals. Treat as style policy, not transcription safety, unless more rows recur. |
| `2026-06-02_13-37-31-026.wav` | `redundant, and you can remove` vs `redundant and what you can remove` | Prompt/model candidate | Use for stronger grammar-repair bakeoff; not safe as deterministic phrase replacement. |
| `2026-06-02_17-57-09-237.wav` | leading `I` retained | Prompt/model candidate | Removing a leading first-person token can change meaning; evaluate through model bakeoff only. |
| `2026-06-02_14-30-54-846.wav` | `seems to getting` vs `seems to be getting` | Prompt/model candidate | Good low-risk grammar-repair bakeoff row. |
| `2026-06-02_18-04-11-605.wav` | extra `the` before `Foundation Models` | Ground-truth/style ambiguity | Low priority; semantically acceptable output. Do not optimize production around article-only WER yet. |
| `2026-06-02_17-56-07-723.wav` | extra `the` before `Foundation Models` after canonicalization | Ground-truth/style ambiguity | Low priority; semantically acceptable output. Do not add article deletion rule. |

- Decision:
  - The next real implementation lever should be a targeted prompt/model bakeoff
    on the residual rows, scored against ground truth.
  - Do not add more deterministic canonicalizer rules yet except possibly a
    separate scoped ordinal-normalization lever.
  - Do not relax the sentence-boundary guard based on the current guard-rejected
    row; the rejected candidate was not actually closer to ground truth.
- Follow-up:
  - Build a residual-row prompt/model bakeoff that runs conservative, relaxed,
    and any candidate local model/prompt against these 11 rows and reports WER
    improvement, guard accept/reject rate, and meaning-risky changes.

## Decision

Residual triage is complete. The next polish improvement should target
prompt/model behavior on the residual set, while keeping deterministic
canonicalizer changes limited to separately justified policy rules.
