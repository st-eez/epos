# Intended transcript accuracy

## Direction

Optimize for whether Epos outputs what the user intended to say, measured against
human-intended transcripts for saved `.wav` dogfood recordings. LLM polish remains
the final cleanup layer; it is not the primary lever for ASR misses that Apple
`SpeechTranscriber` never produced.

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
