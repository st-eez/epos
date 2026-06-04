# L12 Alternative Reranking Eval Prototype

Status: implemented+verified

## Why This Lever Exists

L11 showed the remaining quality headroom was no longer mostly correction UI or
LLM polish. Apple Speech alternatives contained perfect transcripts for some
current residual rows, but production always used Apple Speech's top transcript.

This slice adds eval-only scoring for a non-oracle alternative selection rule
before any production behavior change.

## Scope

- No production dictation behavior change.
- No UI change.
- No ASR replacement.
- No new persistence.
- No LLM polish change.
- Eval-only JSONL and summary fields for alternative reranking.

## Rule Under Test

`highestAlternativeMeanConfidence`

When Apple Speech emits transcript-level alternative candidates, choose the
alternative candidate with the highest mean transcription confidence. If no
candidate has confidence metadata, keep the top transcript.

This is intentionally non-oracle: it does not look at the human-intended
transcript. Human ground truth is used only afterward to score whether the
choice would have helped.

## Implementation

- `Tests/EposTests/SpeechContextEvalSupport.swift`
  - Added `AlternativeTranscriptReranker`.
  - Added `AlternativeTranscriptRerankingEvalResult`.
  - Added reranked win/regression computed fields to `SpeechContextEvalRow`.
- `Tests/EposTests/SpeechContextEvalTests.swift`
  - Scores the reranked selection for alternatives-enabled variants.
- `Tests/EposTests/SpeechContextEvalSummary.swift`
  - Reports oracle upper-bound mean WER and non-oracle reranked mean WER.
  - Reports selected/better/worse/perfect counts.
- `Tests/EposTests/SavedRecordingEvalSupportTests.swift`
  - Added focused unit coverage for the reranker and row scoring.

## Red Evidence

Command:

```sh
swift test --filter SavedRecordingEvalSupportTests > .build/evals/alternative-reranking-red.log 2>&1
```

Expected failure before implementation:

- `cannot find type 'AlternativeTranscriptRerankingEvalResult' in scope`
- `cannot find 'AlternativeTranscriptReranker' in scope`
- extra `alternativeReranking` row initializer argument

## Green Evidence

Focused unit command:

```sh
swift test --filter SavedRecordingEvalSupportTests > .build/evals/alternative-reranking-green-4.log 2>&1
```

Result:

- Passed.
- `13` tests, `0` failures.

Smoke command:

```sh
EPOS_RUN_CONTEXT_EVAL=1 \
EPOS_EVAL_RECORDING_FILES=2026-05-31_07-51-51-282.wav \
EPOS_EVAL_OUTPUT=.build/evals/alternative-reranking-smoke.jsonl \
swift test --filter SpeechContextEvalTests \
> .build/evals/alternative-reranking-smoke.log 2>&1
```

Result:

- Passed.
- Verified the JSONL contains `alternativeReranking`.

Residual10 command:

```sh
EPOS_RUN_CONTEXT_EVAL=1 \
EPOS_EVAL_RECORDING_FILES="2026-06-02_17-57-09-237.wav,2026-05-31_07-30-04-394.wav,2026-05-31_07-43-00-730.wav,2026-05-31_07-51-51-282.wav,2026-05-30_13-19-59-320.wav,2026-05-31_07-43-05-223.wav,2026-05-31_07-47-28-138.wav,2026-06-02_09-33-48-935.wav,2026-06-01_14-31-11-463.wav,2026-06-02_17-56-38-709.wav" \
EPOS_EVAL_OUTPUT=.build/evals/alternative-reranking-residual10-v2.jsonl \
swift test --filter SpeechContextEvalTests \
> .build/evals/alternative-reranking-residual10-v2.log 2>&1
```

Residual10 result for `production-alternatives`:

- Oracle alternatives better/perfect: `4/4`.
- Reranked selected/better/worse/perfect: `10/1/3/1`.
- Reranked canonicalized better/worse/perfect: `1/3/1`.

Full 114-row command:

```sh
EPOS_RUN_CONTEXT_EVAL=1 \
EPOS_EVAL_RECORDING_FILES="$(jq -r '.file' "$HOME/Library/Caches/Epos/recordings/ground-truth.jsonl" | paste -sd, -)" \
EPOS_EVAL_OUTPUT=.build/evals/alternative-reranking-full114-20260604.jsonl \
swift test --filter SpeechContextEvalTests \
> .build/evals/alternative-reranking-full114-20260604.log 2>&1
```

Full result for `production-alternatives`:

- Rows: `114`.
- Top raw mean WER / word errors: `0.075841` / `84`.
- Top canonicalized mean WER / word errors: `0.011416` / `13`.
- Oracle raw upper-bound mean WER / word errors: `0.062523` / `66`.
- Oracle canonicalized upper-bound mean WER / word errors: `0.008711` / `9`.
- Reranked raw mean WER / word errors: `0.101226` / `111`.
- Reranked canonicalized mean WER / word errors: `0.061439` / `64`.
- Oracle raw better rows: `15`.
- Oracle canonicalized better rows: `4`.
- Reranked selected rows: `113`.
- Reranked raw better/worse rows: `4/32`.
- Reranked canonicalized better/worse rows: `1/41`.

Full verification:

- `swift build -Xswiftc -warnings-as-errors`: passed.
- `swift test`: passed, `191` tests, `7` expected gated skips.
- `swiftlint --quiet`: passed.
- `git diff --check`: passed.
- Verifier subagent: `PASS`.

## Decision

Do not ship confidence-only alternative selection. The full-corpus oracle score
proves Apple Speech alternatives have real headroom, but the simple non-oracle
confidence rule creates far more regressions than wins.

The next alternatives slice should inspect the oracle-improved rows and rejected
confidence-reranked rows to design a stricter acceptance gate. A production gate
must beat current canonicalized output over all `114` ground-truth rows with no
meaning-risky regressions.
