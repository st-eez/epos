# Recognition bias & transcriber choice: decision

**Decision (2026-05-28, updated 2026-06-02):** Epos uses Apple
`SpeechTranscriber` + the `TranscriptCanonicalizer` post-hoc correction layer. It
does **not** use `DictationTranscriber` or a custom language model. Domain-jargon
accuracy is still improved primarily by growing the canonicalizer's alias list.
The live path now also passes the same correction vocabulary as lightweight
`AnalysisContext.contextualStrings` because it is bounded, local, and cheap, but
current saved-recording evals show no measurable transcript improvement from
that recognizer hint.

This doc records the empirical justification that `baseline.md` references.

## Question

Can Apple's recognition biasing fix domain jargon (CMUX, Stath, CLAUDE.md,
project.yml) *at the source*, so we rely less on the correction layer?

## Findings

### 1. `SpeechTranscriber` cannot consume a custom language model (SDK primary source)

`SFSpeechLanguageModel.h` (MacOSX26.5 SDK) documents exactly two consumers of the
custom-LM `Configuration`: legacy `SFSpeechRecognitionRequest.customizedLanguageModel`
and new-API `DictationTranscriber.ContentHint.customizedLanguage(modelConfiguration:)`.
`SpeechTranscriber`'s only context knobs are `AnalysisContext.contextualStrings`
(+ opaque `userData`). So any custom-LM test is also a transcriber switch — the LM
benefit is confounded with the cost of leaving `SpeechTranscriber`.

### 2. `contextualStrings` is safe but currently not an accuracy lever

Replayed 6 real recordings with vs without `setContext` (9 canonical terms; path
confirmed firing in logs). Output was byte-identical on every recording. The
light-hint API does not move the needle here.

Replayed the full 111 saved-recording corpus again with the production
alias-inclusive context list. Output was still byte-identical on every recording:
raw changed 0, canonicalized changed 0, vocabulary hit gains 0. The live path
keeps the hint wired because it costs little and may help future SDKs or future
utterances, but correctness must not depend on it.

### 3. Custom LM on `DictationTranscriber` is real, but loses on net accuracy

Pre-registered fair test: `DictationTranscriber` across all real presets, punctuation
on, `PhraseCount` + multi-pronunciation matrix, weight sweep, canonicalizer-on-top.
Metric: mean word-error-rate (WER) vs user-confirmed ground truth + spurious-insertion
count, over 6 recordings.

| Stack | mean WER | spurious |
|---|---|---|
| SpeechTranscriber + canonicalizer (production aliases) | **0.15** | 0 |
| SpeechTranscriber + canonicalizer (default rules only) | 0.19 | 0 |
| DictationTranscriber + best LM (raw or +canon) | 0.22 | 0 |
| DictationTranscriber, no LM (longDictation / progressiveLongDictation) | 0.31 | 0 |

The incumbent wins even after removing its overfitting edge: 0.19 uses only default
canonicalizer rules — netting out the aliases derived from these very clips — and
still beats 0.22.

### 4. Why `DictationTranscriber` loses

Whole-sentence garbling ("Stath pushed the fix to" → "Start push to fix to") — an
engine-quality issue independent of vocabulary, worse across every preset. The LM's
source wins (e.g. CMUX recovery) are exactly what the canonicalizer already fixes via
aliases.

Honest nuance: the custom LM had two genuine source wins the canonicalizer
structurally can't match — exact `project.yml` and `README` ("read me", not aliased).
Both marginal.

## Consequences

- The real accuracy lever is **growing the canonicalizer alias list** as new
  mishearings surface. Remaining gaps (e.g. "Semux"→CMUX, "Stas"→Stath) are alias
  adds, not a transcriber switch.
- `AnalysisContext.contextualStrings` is an auxiliary, best-effort recognizer
  hint. It should use the alias-inclusive correction vocabulary, while polish
  prompts should use canonical spellings only.
- Unsolved by every approach tested: "stuff"→Stath (a common word, deliberately not
  aliased to avoid corrupting normal speech).

## What would flip this decision

Re-evaluate on a future SDK if either:

- `SpeechTranscriber` gains custom-LM support, or
- `DictationTranscriber` transcription quality catches up.

To revisit, rebuild the eval harness (a one-time artifact, since removed) per this
methodology:

- Offline replay over the saved `.wav` recordings (`~/Library/Caches/Epos/recordings/`),
  deterministic.
- Arms: A `SpeechTranscriber`/no-bias, B `DictationTranscriber`/no-LM (isolates switch
  cost), C `DictationTranscriber`/+LM (isolates LM benefit).
- Score net WER vs user-confirmed ground truth + spurious count — not just token
  recovery.
- Include a load positive-control (model file exists AND arm C ≠ arm B output) so a
  null result can't be a silent "LM didn't load".
- `CustomPronunciation` phonemes must validate against
  `SFCustomLanguageModelData.supportedPhonemes(locale:)` or they no-op silently; no
  G2P API exists, so phonemes are a hand-built bounded matrix.

The kept eval `Tests/EposTests/SpeechContextEvalTests.swift` (gated
`EPOS_RUN_CONTEXT_EVAL=1`) exercises the production `Transcriber.start(contextualStrings:)`
hook and is the starting point for such a harness.
