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
