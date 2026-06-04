# Local Ollama Polish Experiment

Date: 2026-06-03

This is the control index for the local Ollama polish optimization loop. Keep it
short. Detailed attempts belong in focused lever files created during the goal;
raw rows belong in `.build/evals/*.jsonl`. Shipped behavior remains in
`specs/baseline.md`.

## Objective

Optimize local Ollama polish for Epos until every evidence-backed in-scope lever
has been implemented, rejected, or marked out of scope with a reason.

`qwen3:1.7b` is the baseline/control, not a permanent constraint. A different
local Ollama model is allowed only when evals show a meaningful quality gain and
resource checks show acceptable latency and active memory cost for frequent short
dictations on an 18GB M3 MacBook Pro.

## Stable Constraints

- Verify behavior from `Sources/`, `Tests/`, eval JSONL, command output, and
  resource measurements before acting on a hypothesis.
- Keep cloud/API polish, app UI changes, insertion behavior changes, and
  arbitrary large model pulls out of scope.
- Do not move `TranscriptCanonicalizer` ownership or deterministic cleanup
  ownership unless eval evidence proves a tiny scoped change is required and
  tests cover it.
- Production behavior may change only with JSONL-backed improvement, manual
  inspection, no observed meaning-risky accepted edits, and acceptable
  short-dictation latency/resource cost.
- Keep this index as pointers and status only; do not turn it into a transcript.

## Lever Index

The goal agent owns this table. Start by creating a baseline measurement lever,
then add new lever rows only when current evidence justifies them. Keep this as
a pointer table; put attempts, commands, examples, and decisions in each lever
file.

Lever files live under `specs/ollama-polish-levers/`; use
`specs/ollama-polish-levers/README.md` as the template.

| Lever | File | Status | Last decision |
| --- | --- | --- | --- |
| Baseline measurement | `specs/ollama-polish-levers/L1-baseline-measurement.md` | implemented+verified | Full static, raw-candidate, resource, and 111-recording dogfood baseline completed; next lever is prompt shape |
| Prompt shape | `specs/ollama-polish-levers/L2-prompt-shape.md` | implemented+verified | Conservative prompt reduced target19 churn and guard rejections, but one final-period drop remained |
| Final period guard | `specs/ollama-polish-levers/L3-final-period-guard.md` | implemented+verified | Existing terminal periods are guard-protected; Ollama production default is now the conservative prompt |
| Ground-truth 20 corrections | `specs/ollama-polish-levers/L4-ground-truth20-corrections.md` | implemented+verified | Seeded 20 human-confirmed transcripts exposed safe canonicalizer wins; exact ordinal guard allowance helps relaxed but conservative remains production default |
| Ground-truth 35 canonicalizer expansion | `specs/ollama-polish-levers/L5-ground-truth35-canonicalizer.md` | implemented+verified | Expanded manifest to 35 confirmed rows; added narrow canonicalizer rules that dropped production output WER from 0.062 to 0.035 |
| Residual error triage | `specs/ollama-polish-levers/L6-residual-error-triage.md` | implemented+verified | Generated a residual-only report over the 35-row eval; 11 rows remain, mostly prompt/model candidates rather than deterministic canonicalizer fixes |
| Residual model bakeoff | `specs/ollama-polish-levers/L7-residual-model-bakeoff.md` | implemented+verified | Added residual-row prompt/model bakeoff; qwen3:4b and prompt variants did not improve strict-gate WER after deterministic cleanup |
| Residual deterministic cleanup | `specs/ollama-polish-levers/L8-residual-deterministic-cleanup.md` | implemented+verified | Added exact ordinal and missing-`be` cleanup rules; 35-row output WER is now 0.028 with 3 deterministic WER wins and 0 output regressions |
| Ground-truth 80 canonicalizer expansion | `specs/ollama-polish-levers/L9-ground-truth80-canonicalizer.md` | implemented+verified | Expanded manifest to 80 inferred rows; added narrow domain/exact canonicalizer aliases that dropped output WER from 0.039 to 0.003 with 18 wins and 0 regressions |
| Holdout generalization pass | `specs/ollama-polish-levers/L10-holdout-generalization.md` | implemented+verified | Added 34 unseen holdout rows; scoped canonicalizer aliases dropped holdout output WER from 0.067 to 0.024 and combined 114-row output WER from 0.022 to 0.009 with no baseline80 regression |
| Primary accuracy refresh | `specs/ollama-polish-levers/L11-primary-accuracy-refresh.md` | implemented+verified | Current 114-row scoreboard remains raw/can/out mean WER 0.076/0.011/0.009; remaining headroom is alternatives/reranking, where Apple Speech alternatives contain perfect transcripts for 4 of 10 residual rows |

## Read First

- `specs/baseline.md`
- `specs/ollama-polish-levers/README.md`
- The lever file for the current checkpoint, once created
- Only the source/test files named by that lever unless the evidence points elsewhere

## Eval Artifacts

- Static raw candidate JSONL: `.build/evals/ollama-raw-candidate-*.jsonl`
- Static polisher JSONL: `.build/evals/ollama-polish-*.jsonl`
- Dogfood pipeline JSONL: `.build/evals/dogfood-pipeline-ollama-*.jsonl`
- Human transcript manifest, if used for saved-dogfood WER: `ground-truth.jsonl`
  beside the `.wav` recordings, or `EPOS_EVAL_GROUND_TRUTH=/path/to/file.jsonl`
- Final human report, if generated: `.build/evals/local-ollama-polish-summary.md`

Existing `.build/evals` files are orientation only. Rerun the relevant evals
before treating a result as completion evidence.

## Completion Criteria

The goal is complete only when:

- Static and saved-dogfood JSONL comparisons exist for the chosen variants.
- Each concrete lever row created in the index is implemented and verified,
  rejected with concrete evidence, or marked out of scope with a reason.
- Manual inspection covers every changed candidate, every strict guard rejection,
  and every case where a model did something deterministic cleanup could not do.
  If that is too many rows, inspect all guard rejections plus a documented
  bounded sample and explain why.
- Final summary includes counts, representative examples, decisions for each
  lever, final production state, resource findings, and remaining out-of-scope
  ideas.
- Required checks pass: `swift build -Xswiftc -warnings-as-errors`,
  `swift test`, `swiftlint --quiet`, relevant static evals, dogfood shadow evals
  when recordings are available, `ollama ps` after evals, resource checks,
  verifier subagent for nontrivial changes, and installed signed app testing if
  production behavior changed.

Do not declare complete because one eval or one test suite passed.
