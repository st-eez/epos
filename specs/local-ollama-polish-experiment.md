# Local Ollama Polish Experiment

Date: 2026-06-03

This is a working experiment ledger, not the product source of truth. Shipped
behavior remains documented in `specs/baseline.md`, and current behavior must be
verified in `Sources/` and `Tests/` before changes.

## Objective

Optimize local Ollama polish for Epos until every evidence-backed in-scope lever
has been implemented, rejected, or declared out of scope with a concrete reason.
Use `qwen3:1.7b` as the baseline/control, but allow a different local Ollama
model only when evals prove a meaningful quality gain and resource checks show
acceptable latency and active memory cost for frequent short dictations on an
18GB M3 MacBook Pro.

## Verified Current State

- `specs/baseline.md` says local Ollama polish is environment-selected with
  `EPOS_POLISH_ENGINE=ollama`, defaults to `qwen3:1.7b`, and remains off by
  default in normal production behavior.
- `OllamaPolishPrompt` currently has `strict` and `relaxed` prompt styles.
  `strict` reuses the FoundationModels-compatible prompt; `relaxed` is eval-only
  probing for broader Qwen capability.
- `OllamaHTTPPolishClient` sends `stream: false`, `think: false`,
  `keep_alive`, JSON schema output with one `cleaned` field, temperature, and
  `num_ctx`.
- `TranscriptPolisher` canonicalizes raw text, attempts model polish when
  enabled/available, canonicalizes the candidate, applies the strict retention
  guard, and falls back to deterministic cleanup or raw text on failures,
  timeouts, or guard rejection.
- `TranscriptDeterministicCleaner` removes only guard-provable hard fillers and
  comma-delimited opening `so`/`like`; it deliberately does not own broad polish.
- `TranscriptCanonicalizer` owns spoken-symbol and user correction canonicalization.
  Do not move that ownership into model polish without specific evidence and
  tests.
- Read-only setup inventory on 2026-06-03 found installed Ollama models:
  `qwen3:1.7b` only, size reported by Ollama as 1.4 GB. `ollama ps` was empty.
- Existing stale eval artifacts are present and useful for orientation only:
  `.build/evals/ollama-raw-candidate-relaxed.jsonl` has 20 rows,
  `.build/evals/dogfood-pipeline-ollama-latest11-raw-candidate-shadow.jsonl` has
  11 rows, and `.build/evals/ollama-polish-strict-relaxed.jsonl` has 40 rows.
  Rerun evals before treating any result as completion evidence.

## Read First

- `specs/baseline.md`
- `Sources/Epos/Speech/OllamaPolishPrompt.swift`
- `Sources/Epos/Speech/OllamaPolishEngine.swift`
- `Sources/Epos/Speech/OllamaHTTPPolishClient.swift`
- `Sources/Epos/Speech/TranscriptPolisher.swift`
- `Sources/Epos/Speech/TranscriptPolisherGuard.swift`
- `Sources/Epos/Speech/TranscriptDeterministicCleaner.swift`
- `Tests/EposTests/OllamaPolishEvalTests.swift`
- `Tests/EposTests/OllamaRawCandidateEvalSupport.swift`
- `Tests/EposTests/DogfoodPipelineEvalTests.swift`

## Scope

Allowed:

- Eval-only prompt variants and prompt structure changes.
- Eval diagnostics and JSONL fields needed to isolate failure modes.
- Ollama request options that do not create an unacceptable active footprint.
- Timeout/prewarm/keep-alive behavior when measured against short dictation cost.
- Local model comparison when the candidate model is plausibly compatible with
  frequent short dictation on this machine.
- Narrow guard relaxation only for edit classes proven safe by evals and tests.
- Production behavior changes only after JSONL-backed improvement, manual
  inspection, no observed meaning-risky accepted edits, and acceptable resource
  cost.

Not allowed without a new product decision:

- Cloud/API polish.
- App UI changes.
- Insertion behavior changes.
- Moving `TranscriptCanonicalizer` ownership into model polish.
- Casual changes to deterministic cleanup ownership.
- Pulling clearly large models incompatible with frequent short dictation on this
  machine.

## Evidence Required Per Eval Row

Each row must be enough to separate model capability from pipeline suppression:

- Raw transcript.
- Model name and relevant request/prompt variant.
- Raw model candidate.
- Canonicalized candidate.
- Strict guard accepted/rejected.
- Guard rejection reason and diff.
- Deterministic cleanup output.
- Whether model output changed anything beyond deterministic cleanup.
- Whether filler/disfluency remains.
- Latency and model/error outcome.
- Manual risk note for changed candidates, guard rejections, and model-only
  improvements.

## Product Behaviors To Cover

The final evidence must explicitly cover:

- Punctuation cleanup.
- Filler/disfluency cleanup.
- Light grammar cleanup.
- Recognition-fix attempts.
- Deterministic-cleanup-equivalent edits.
- Guard-suppressed edits.
- Meaning-risky edits.
- Latency and active resource cost for short and normal dictations.
- Post-run keep-alive/unload behavior.

## Starting Eval Commands

Use these as starting points; update this section if the harness changes.

```sh
EPOS_RUN_OLLAMA_RAW_CANDIDATE_EVAL=1 \
EPOS_OLLAMA_MODEL=qwen3:1.7b \
EPOS_EVAL_OUTPUT=.build/evals/ollama-raw-candidate-lanes.jsonl \
swift test --filter OllamaPolishEvalTests/testRelaxedRawCandidatesBypassPolisherOverCorpus
```

```sh
EPOS_POLISH_ENGINE=ollama \
EPOS_OLLAMA_MODEL=qwen3:1.7b \
EPOS_RUN_DOGFOOD_EVAL=1 \
EPOS_EVAL_SHADOW_RELAXED_OLLAMA=1 \
EPOS_EVAL_OUTPUT=.build/evals/dogfood-pipeline-ollama-lanes.jsonl \
swift test --filter DogfoodPipelineEvalTests/testSavedRecordingsThroughProductionPolishPipeline
```

## Resource Checks

Record commands and observations for:

- `ollama list` before model comparison.
- `ollama ps` before, during, and after evals.
- Active memory during short and normal polish runs.
- Elapsed latency for short transcripts and normal dogfood recordings.
- Whether keep-alive/prewarm improves latency enough to justify active memory cost.

## Lever Ledger

Update this table after every checkpoint. Do not leave an in-scope lever at
`open` when declaring the goal complete.

| ID | Lever | Hypothesis | Change made | Evidence command/artifact | Decision | Follow-up |
| --- | --- | --- | --- | --- | --- | --- |
| L1 | Baseline rerun | Current relaxed Qwen behavior must be remeasured before optimization. | None yet | Pending static + dogfood JSONL rerun | open | Establish control metrics |
| L2 | Prompt breadth/wording | The relaxed prompt may be too broad or weak for `qwen3:1.7b`. | None yet | Pending prompt-variant evals | open | Compare targeted variants |
| L3 | Prompt format/schema | JSON schema, role layout, or instruction shape may suppress capability. | None yet | Pending request/prompt-format eval | open | Compare to baseline |
| L4 | Request options | `think`, temperature, `num_ctx`, or related options may affect quality/latency. | None yet | Pending option eval with resource notes | open | Reject options that add unacceptable cost |
| L5 | Strict gate suppression | The model may produce useful edits that are rejected by the guard. | None yet | Pending raw candidate + guard reason analysis | open | Relax only proven-safe edit classes |
| L6 | Deterministic overlap | Deterministic cleanup may already cover the safe useful part. | None yet | Pending model-vs-deterministic comparison | open | Keep deterministic floor if true |
| L7 | Model choice | `qwen3:1.7b` may be too weak; another local model may be better. | None yet | Pending installed/compatible model comparison | open | Halt before clearly large pulls |
| L8 | Timeout/prewarm/keep-alive | Runtime policy may hide usable quality or make short dictation too costly. | None yet | Pending latency/resource comparison | open | Tune only if evidence supports |

## Checkpoint Log

Append dated entries here with commands, row counts, examples, decisions, and the
remaining lever queue.

## Completion Criteria

Completion requires:

- JSONL-backed comparisons over the static corpus and saved dogfood recordings.
- At least one full lever-loop iteration after baseline measurement.
- Manual inspection of every changed candidate, every strict guard rejection, and
  every case where a model did something deterministic cleanup could not do. If
  there are too many changed rows, inspect all guard rejections plus a documented
  bounded sample and explain why.
- Every in-scope lever in the ledger is implemented and verified, rejected with
  concrete evidence, or declared out of scope with a reason.
- Final summary includes counts, examples, decisions for each lever, final
  production state, resource findings, and remaining out-of-scope ideas.
- Required checks pass: `swift build -Xswiftc -warnings-as-errors`, `swift test`,
  `swiftlint --quiet`, relevant static evals, dogfood shadow evals when saved
  recordings are available, `ollama ps` after evals, resource checks, verifier
  subagent for nontrivial changes, and installed signed app test if production
  behavior changed.

The work is not complete if only one prompt/config/model was tried, only latest
dogfood recordings were run without justification, raw candidates or guard
reasons were not logged, resource impact was not measured, manual inspection did
not happen, production behavior changed without eval proof, or a known in-scope
lever remains unresolved.
