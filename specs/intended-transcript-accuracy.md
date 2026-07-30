# Intended transcript accuracy

## Direction

Optimize for whether Epos outputs what the user intended to say, measured against
human-intended transcripts for saved `.wav` dogfood recordings. LLM polish remains
the final cleanup layer; it is not the primary lever for ASR misses that Apple
`SpeechTranscriber` never produced.

## Reference provenance correction

The legacy 114-row `ground-truth.jsonl` is not uniformly human-confirmed. Project
records document the first 35 rows as confirmed. Rows 36 through 114 were inferred
from recognizer and pipeline output during the 80-row and holdout expansions.
Those 79 rows remain useful historical regression evidence, but they are not
verified accuracy labels and must return to the human-review pool.

Until a provenance-bearing corpus replaces the legacy manifest:

- accuracy claims use only references explicitly marked `human_confirmed`;
- the historical 114-row scores are reported as legacy inferred-reference evidence;
- no new correction may be promoted solely from an inferred row;
- recognizer agreement, canonicalized text, and inserted text never create labels.

## 2026-06-03 ground-truth ASR pass

Ground truth source:

- `~/Library/Caches/Epos/recordings/ground-truth.jsonl` (`35` rows)

Eval artifacts:

- `.build/evals/speech-context-ground-truth35-asr-confidence-20260603.jsonl`
- `.build/evals/speech-context-ground-truth35-asr-after-foundationmodels-alias-20260603.jsonl`
- `.build/evals/dogfood-pipeline-ground-truth35-asr-direction-baseline-20260603.jsonl`
- `.build/evals/dogfood-pipeline-ground-truth35-asr-direction-canonicalizer-20260603.jsonl`

Findings:

- `AnalysisContext.contextualStrings` still did not change top raw transcripts:
  production `setContext`, initializer context, and project-expanded context all
  had `0` raw/canonicalized WER improvements and `0` regressions.
- Apple alternatives contain some oracle wins, but confidence is not a safe
  selector: the best alternatives all had lower confidence than the top
  transcript, including both wins and regressions.
- The safe production lever in this pass was the canonicalizer: measured aliases
  for branded `Foundation Models` article cleanup and the exact
  `seeing deprecate` -> `saying deprecate` miss.

Measured production result:

| Metric | Before | After |
|---|---:|---:|
| Mean raw WER | `0.083` | `0.083` |
| Mean canonicalized WER | `0.035` | `0.026` |
| Mean final output WER | `0.028` | `0.019` |
| Output WER wins | - | `3` |
| Output WER regressions | - | `0` |

Output WER wins:

| File | Before WER | After WER | Fix |
|---|---:|---:|---|
| `2026-06-02_17-56-07-723.wav` | `0.015` | `0.000` | Removed stray `the` before branded `Foundation Models` |
| `2026-06-02_18-03-27-951.wav` | `0.286` | `0.000` | `seeing deprecate` -> `saying deprecate`; removed stray `the` |
| `2026-06-02_18-04-11-605.wav` | `0.032` | `0.000` | Removed stray `the` before branded `Foundation Models` |

Current residual direction:

- Remaining high-WER rows are mostly true ASR semantic misses or human-style
  formatting choices, not LLM polish failures.
- Do not enable automatic alternative selection without a selector that beats the
  top transcript without regressions on ground-truth rows.
- Continue growing canonicalizer aliases only from measured, narrow,
  user-confirmed recurring misses.

## 2026-06-03 ground-truth 80 canonicalizer pass

Ground truth source:

- `~/Library/Caches/Epos/recordings/ground-truth.jsonl` (`80` rows)

Eval artifacts:

- `.build/evals/dogfood-pipeline-ground-truth80-current-20260603.jsonl`
- `.build/evals/dogfood-ground-truth80-residuals-current-20260603.md`
- `.build/evals/dogfood-pipeline-ground-truth80-canonicalizer-20260603.jsonl`
- `.build/evals/dogfood-ground-truth80-residuals-canonicalizer-20260603.md`

Measured production result:

| Metric | Before | After |
|---|---:|---:|
| Labeled rows | `80` | `80` |
| Mean raw WER | `0.070` | `0.070` |
| Mean canonicalized WER | `0.042` | `0.006` |
| Mean final output WER | `0.039` | `0.003` |
| Output WER wins | - | `18` |
| Output WER regressions | - | `0` |
| Residual rows | `20` | `4` |

Implemented safe fixes:

- Phrase-level NetSuite corrections for measured `next week login`, `next week
  ticket`, `Open that suite`, `Open next feed`, and comma-split
  `net, suite, login` shapes.
- Exact domain/app corrections for `Ipos app`, `team's message`, and
  `Stuff instructions`.
- Exact measured ASR phrase corrections for rows such as `3 litter code`,
  `history, seeing`, `not working progress`, and `They'd be closed phase one`.
- Numeric phrase corrections for measured `2 tickets` and `part 2` dogfood rows.

Residual categories after the pass:

| Category | Count | Rows | Action |
|---|---:|---|---|
| Apple ASR semantic miss | `3` | `Add to the ticket...`, missing `working`, trailing `And.` | No production fix without more examples; one unsafe exact rule was removed after a test caught overlap. |
| Polish/style-only leading word | `1` | leading `I` before `Think outside the box` | Do not loosen polish; accepted output is semantically close and removing leading `I` is not safe generally. |
| Canonicalizer opportunity | `0` | - | No remaining repeated safe deterministic correction in this 80-row slice. |
| LLM polish issue | `0` | - | Model mostly left ASR misses unchanged; prompt/model work is not the next lever from this evidence. |

## 2026-06-03 holdout 34 generalization pass

Ground truth source:

- `~/Library/Caches/Epos/recordings/ground-truth.jsonl` (`114` rows total)
- Locked baseline slice: first `80` manifest rows
- Holdout slice: appended `34` rows (`33` historical unseen rows plus `1`
  post-commit recording)

Eval artifacts:

- `.build/evals/speech-context-holdout-candidates-20260603.jsonl`
- `.build/evals/dogfood-pipeline-ground-truth-holdout34-current-20260603.jsonl`
- `.build/evals/dogfood-ground-truth-holdout34-residuals-current-20260603.md`
- `.build/evals/dogfood-pipeline-ground-truth-baseline80-current-20260603.jsonl`
- `.build/evals/dogfood-pipeline-ground-truth114-current-20260603.jsonl`
- `.build/evals/dogfood-pipeline-ground-truth-holdout34-canonicalizer-20260603.jsonl`
- `.build/evals/dogfood-ground-truth-holdout34-residuals-canonicalizer-20260603.md`
- `.build/evals/dogfood-pipeline-ground-truth-baseline80-canonicalizer-20260603.jsonl`
- `.build/evals/dogfood-pipeline-ground-truth114-canonicalizer-20260603.jsonl`

Measured production result:

| Slice | Raw WER | Canonicalized WER Before | Output WER Before | Canonicalized WER After | Output WER After |
|---|---:|---:|---:|---:|---:|
| Baseline80 | `0.070` | `0.006` | `0.003` | `0.006` | `0.003` |
| Holdout34 | `0.089` | `0.067` | `0.067` | `0.024` | `0.024` |
| Combined114 | `0.076` | `0.024` | `0.022` | `0.011` | `0.009` |

Holdout row-level result:

| Metric | Value |
|---|---:|
| Output WER wins | `8` |
| Output WER regressions | `0` |
| Unchanged rows | `26` |
| Residual rows before | `14` |
| Residual rows after | `6` |

Implemented safe fixes:

- Proper noun and acronym aliases: `Stas` -> `Stath`, `Semux` -> `CMUX`.
- File/domain aliases: `project.yamo` -> `project.yml`, raw `cloud.MD`
  phrase cleanup for `updates to CLAUDE.md`.
- Narrow phrase aliases for measured dogfood misses: `ping stuff`, `when stuff
  runs it`, `the read me and the agent's file`, `Use of agents as needed to
  keep your context window clean`, and `2 things`.

Residual categories after the pass:

| Category | Count | Rows | Action |
|---|---:|---|---|
| ASR semantic miss | `3` | `Latif`, `Lords`, `books` | No broad production fix; each can be a real word/name in other contexts. |
| Missing leading word / tense | `2` | missing `It`, `Drop` vs `Dropped` | Do not add generic leading-word or tense rewrites from one example. |
| Grammar-only polish | `1` | `enabled to check` vs `enabled, so check` | Do not loosen conservative polish or add grammar canonicalizer rules from one row. |

Direction:

- This holdout pass validates the canonicalizer as the current high-leverage
  production lever for measured domain misses.
- It does not validate LLM polish as the next lever: Ollama changed `0` holdout
  rows, and the remaining residuals are mostly ASR semantic misses or unsafe
  style/grammar rewrites.

## 2026-07-29 correction candidate gate

Use `scripts/correct <candidate.json>` to evaluate one `CorrectionRecord` before
adding it to production. The command reads the current-production arm of the
signed confirmed-corpus artifact
(`.build/evals/apple-presets-signed-confirmed75.jsonl`) and runs the repository
default correction dictionary with and without the candidate. It does not
retranscribe audio or read machine-local persisted correction rules.

The gate is re-enabled against the 75 human-confirmed rows. Slices come from each
artifact row's `referenceDesignation`, which the signed eval host copies from the
v2 corpus ledger: `legacy` (the 35 rows that developed the correction layer) is
the development slice, `holdout` (the 40 rows confirmed by listening in the
`scripts/confirm` session) is the promotion holdout. Nothing is order-derived and
no inferred row reaches the gate.

**A holdout row may never drive candidate development.** It exists only to pass
or fail a candidate. Reading holdout residuals to invent an alias, a threshold, or
a rule turns the holdout into a second development set and destroys the only
untouched reference evidence the project has.

A candidate can pass only when:

- the artifact holds exactly 35 legacy and 40 holdout rows, one row per file,
  none failed or empty;
- the candidate changes at least one row;
- confirmed development rows have zero WER regressions;
- the holdout has zero WER regressions and at least one WER improvement.

The signed Apple benchmark records both raw recognizer text and Epos's
deterministic production baseline: the active app correction dictionary followed
by the conservative stream cleaner. `scripts/audit` prefers that production score
when the artifact provides it and reports which score field it selected. Older
artifacts without production fields remain raw-recognizer evidence and must be
labeled as such.

Standalone numeric ordinals are part of the conservative stream baseline. The
114-row corpus contains two independent `1st` -> `first` misses, the transformation
preserves numeric meaning, and corpus evaluation must show no regressions before
it ships.

## 2026-07-29 unlabeled recording queue

Saved recordings without a human-confirmed intended transcript are useful for
finding uncertainty and recurring recognizer behavior, but they are not accuracy
ground truth. Epos must never copy its own transcript or an inferred transcript
into `ground-truth.jsonl` automatically.

Use `scripts/label` to rank one replay artifact into a bounded review queue. The
command selects exactly one `production-alternatives` row per recording and
prioritizes:

- word-level disagreement between the top transcript and Apple alternatives;
- low mean or minimum token confidence;
- a change made by the production canonicalizer;
- the same minimal top-versus-alternative difference recurring across recordings;
- disagreement among the three production recognizer modes.

Case and `. , ! ? ; :` punctuation do not count as recognizer disagreement.
Other symbols remain meaningful. Recognizer agreement is never evidence that a
transcript is correct.

The default 30-row queue contains the 24 highest-ranked recordings, three
additional canonicalizer-changed recordings, and three low-score controls. It
rejects incomplete corpus coverage, already-labeled files, missing recordings,
unsafe filenames, malformed replay rows, and accidental output replacement.
Queue rows have `status: "unreviewed"` and contain no proposed intended
transcript. Their provenance includes the source artifact hash, correction
dictionary fingerprint, and exact correction record IDs applied to the
recognizer output. The replay also records each WAV's SHA-256 digest. Queue
generation re-hashes every current WAV and rejects changed audio or inconsistent
replay metadata.

The v2 corpus ledger is the frozen development/holdout contract for the
correction promotion gate (`specs/evaluation-corpus.md`). Human-confirmed
transcripts from this queue reach the gate only through that ledger; never append
them silently to the legacy manifest. Existing queue output is never overwritten
unless `--replace` is explicit.
