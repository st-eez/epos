# Current accuracy and performance evidence

The signed saved-audio replay on October 1, 2026 (October 2 UTC) verifies 67 exact
production outputs across 75 human-confirmed recordings, with 9 word errors across 963
reference words. Production micro WER is **0.9346%**. It establishes recognition
and deterministic cleanup accuracy for this frozen corpus and dictionary.
Microphone capture, live release latency, screen paint, and insertion into daily
target apps require separate measurements.

## Confirmed production baseline

| Slice | Recordings | Reference words | Raw word errors | Production word errors | Production micro WER | Exact production rows |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Development | 35 | 478 | 29 | 3 | 0.6276% | 32 |
| Frozen holdout | 40 | 485 | 15 | 6 | 1.2371% | 35 |
| All confirmed | 75 | 963 | 44 | 9 | 0.9346% | 67 |

Micro WER divides total word errors by total reference words; it is not the
average of each recording's WER. Cleanup improved 20 rows and regressed none.
The production arm had no empty transcripts or thrown errors. All 75 rows join
the authoritative corpus by filename, audio digest, and human-confirmed intended
reference. The audit selects `productionOutputTranscriptScore` and reports
`verifiedAccuracy=true`.

Only the 35 confirmed development recordings were inspected for correction
invention. Their three residual categories each occur once: a missing function
word, an extra terminal conjunction, and an extra leading pronoun. None supplies
a recurring safe rule with independent positive and negative examples. No new
correction was added. Holdout residual text remained unread; only aggregate
holdout scores were inspected. Labels and the existing promotion gate remain
unchanged: zero development or holdout regressions and at least one holdout
improvement after a candidate is frozen.

## Performance measurements

The [preparation experiment](../specs/analyzer-preparation-experiment.md) compared
three fresh-analyzer strategies across six recordings and two repeats. All 36
paced trials produced identical cleaned output. Preparing ahead improved the
paired median first-result time by 2.1 ms while preparation itself took about
29 ms. The result does not justify a standby analyzer lifecycle, so production
continues to create an analyzer for each hold.

[Stage timing](diagnostics.md#stage-timing) now separates startup, useful display
publication, acknowledged preview, accepted final writes, and delivery readback.
The saved-audio hosts bypass recording sessions and target fields. Current live
release-to-field latency remains unmeasured by these experiments.

## Replay fidelity and controls

The `speech-progressive-fast` production arm shares the live
`Transcriber.speechPreset`, including confidence attributes, and
`analysisContext` builder. One persisted dictionary snapshot supplies recognition
vocabulary and every arm's canonicalization plus stream cleanup. The baseline
requested 44 canonical terms. All 375 analyzer context readbacks matched their
requests; the four comparison arms received no context.

| Unhinted control | Production word errors | Production micro WER | Exact rows | Empty rows |
| --- | ---: | ---: | ---: | ---: |
| `speech-progressive-quality` | 22 | 2.2845% | 62 | 0 |
| `speech-final` | 22 | 2.2845% | 62 | 0 |
| `dictation-short` | 99 | 10.2804% | 27 | 1 |
| `dictation-long` | 96 | 9.9688% | 28 | 1 |

Each control covered all 75 references. The empty dictation results remain in
the denominator and are scored as deletions. No arm recorded a thrown error,
but the two empty control results made the complete host exit with status 1.
The production arm's complete nonempty coverage passed independently. These
comparisons vary preset and context together, so they do not isolate the effect
of vocabulary bias.

## Dated provenance

The run started at `2026-10-02T01:47:43Z` under the installed `com.steez.Epos`
identity, bundle version 1. Source revision was
`f7118f7a5e59623eb275497e1696a54b2b02de60`, with a clean source tree. It used
**Debug, `-Onone`**, SDK `macosx27.0`, and macOS 27.0 build `26A428` on arm64.
These scores do not establish Release performance or a speed gain.

The regenerated v2 ledger has 682 regular WAVs: 75 confirmed references, 79
inferred references, and 528 unlabeled recordings. Frozen membership and the
confirmation ratchet passed. The private replay preserves all 46 dictionary
records, requested context, actual context readback, and build metadata. Audio,
transcripts, dictionary records, and generated artifacts remain outside Git.

| Evidence | SHA-256 |
| --- | --- |
| Installed executable | `7767593a4367c00d0727d97f23558e83d226bfe2bc2e79e8b4031fafff2c84f2` |
| Corpus ledger | `b293b661c6f28c28abb8fdac964f0d7dc964976ef548bd55a8f398e7cbd53ad6` |
| Dictionary records | `a5bc678d65cffe752c9c90c1ed8da65920b4ed9211d29cd026de34194d947428` |
| Replay artifact | `76ab1f686a31fef449711fdbeddd7179527150b4a6819129e7a02313b005d903` |

The historical confirmed75 artifact still joins all references and records 10
production word errors with 67 exact rows. Its missing context and build
provenance prevent attributing the one-error difference to a particular change.
The default 114 artifact fails authoritative reference joining and cannot
establish verified current accuracy.

## Reproduce and verify

The private artifact is
`.build/evals/apple-presets-signed-confirmed75-f7118f7-20261002.jsonl`; the ledger
is `.build/evals/evaluation-corpus-v2-20261002.jsonl`. To audit those files:

```sh
scripts/audit \
  --eval .build/evals/apple-presets-signed-confirmed75-f7118f7-20261002.jsonl \
  --eval-arm speech-progressive-fast \
  --corpus .build/evals/evaluation-corpus-v2-20261002.jsonl --json
```

A fresh run requires the intended signed build and a unique output filename.
Run after the ordinary app process has ended, using the
[signing workflow](development.md):

```sh
SWIFT_TESTING_ENABLED=1 EPOS_DIAGNOSTIC_LOGS=0 \
EPOS_RUN_SIGNED_APPLE_PRESET_EVAL=1 \
EPOS_EVAL_CORPUS="$PWD/.build/evals/evaluation-corpus-v2-20261002.jsonl" \
EPOS_EVAL_OUTPUT="$PWD/.build/evals/apple-presets-signed-confirmed75-new.jsonl" \
/Applications/Epos.app/Contents/MacOS/Epos
```

Strict Swift build, the four isolated evaluation snapshot tests, SwiftLint,
audit self-tests, corpus tests, shell syntax, and project generation passed.
The tests cover frozen vocabulary and cleanup, dictionary reconstruction,
unhinted controls, context-readback refusal, and legacy artifact decoding.
Deliberately dropping forwarded vocabulary made the regression fail; restoring
committed source returned all four tests to passing. The integrated verification
also passed 389 tests with 3 skips and no failures. The
[latency instrumentation](diagnostics.md) establishes measurable software
boundaries; this saved-audio accuracy run bypasses delivery and claims no
performance improvement.
