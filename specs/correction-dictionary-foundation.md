# Correction Dictionary Foundation

Status: CD-1 implemented; Slice 2 pending decision
Created: 2026-06-03

This spec is the handoff guide for improving Epos' correction foundation without
forgetting the end goal. Future sessions should update this file as slices land,
as evidence changes, or as a slice is rejected.

## End Goal

Make Epos' baseline dictation output better while keeping the live path local,
low-overhead, and safe:

```
Apple SpeechTranscriber
  -> deterministic correction dictionary
  -> guarded final polish/cleanup
  -> stable insertion
```

The end state is not "more regexes forever" and not "generic LLM rewrite." The
end state is a richer correction system that can represent terms, phrase
replacements, snippets, spoken commands, scopes, provenance, and measured
evidence, then compile only accepted safe records into the deterministic
runtime canonicalizer.

## Current Decision

Keep `TranscriptCanonicalizer` as the runtime authority. Add a higher-level
`CorrectionDictionary` / `CorrectionRecord` layer above it.

Do not replace Apple `SpeechTranscriber`.
Do not loosen the LLM polish guard as part of this work.
Do not introduce SQLite or persistent transcription history in Slice 1.

## Evidence

Confirmed Wispr Flow evidence:

- Flow has first-class `History`, `Dictionary`, and `Polish` schemas.
- `History` separates raw ASR text from formatted/final text and includes
  edited/pasted text, audio chunks, app/url/context fields, timing, language,
  logprob, fallback/external-ASR hooks, and transcript command metadata.
- `Dictionary` is richer than Epos' current rule model: phrase, replacement,
  manual/source fields, snippet support, usage/frequency-ish fields, and
  provenance/sync shape.
- Local Flow data showed dictionary/history/audio/timing fields populated.
- Local Flow data did not show active external ASR or fallback ASR output, and
  the local `Polish` table was empty.

Confirmed Epos evidence:

- Epos uses Apple `SpeechAnalyzer` + `SpeechTranscriber`.
- `TranscriptCanonicalizer` is intentionally narrow deterministic cleanup:
  `TranscriptCanonicalizer.Rule(canonical, aliases, contexts)`.
- `CorrectionStore` persists the canonicalizer rules through `UserDefaults`.
- Existing ground-truth dogfood evals show deterministic domain corrections
  produced most measured WER improvement without regressions.
- qwen3 residual repair bakeoffs did not improve the latest residual set and
  sometimes regressed before the strict guard blocked the output.

Implication: the next architectural lever is a richer deterministic correction
model and evidence path, not ASR replacement or a generic local LLM repairer.

## Goals

- Preserve current dictation behavior while changing the correction model.
- Represent corrections as records with type, source, scope, status, and
  provenance instead of flat canonicalizer rules.
- Compile accepted records into `[TranscriptCanonicalizer.Rule]`.
- Keep the canonicalizer fast, deterministic, and testable.
- Create a clean place for later sessions to add observed edit evidence and
  candidate-rule promotion.

## Non-goals

- No runtime transcription-history database in Slice 1.
- No cloud or external ASR fallback.
- No model/prompt change.
- No broad grammar rewrite rules.
- No automatic acceptance of mined corrections.
- No UI redesign in Slice 1 beyond what is required to keep existing behavior.

## Proposed Architecture

Target shape:

```
CorrectionDictionary
  -> CorrectionRecord[]
  -> CorrectionRuleCompiler
  -> TranscriptCanonicalizer.Rule[]
  -> TranscriptCanonicalizer
```

`TranscriptCanonicalizer` remains the execution engine. The dictionary layer is
the product model.

### CorrectionRecord

Records should be able to represent at least:

- `lexicon`: proper nouns, brands, acronyms, file names.
- `replacement`: measured spoken phrase -> intended phrase.
- `snippet`: manual expansion only; not enabled by mining by default.
- `spokenCommand`: command/symbol text such as `/goal`, `--`, `$HOME`.
- `formattingPolicy`: future deterministic formatting rule, not Slice 1.

Core fields for the long-term model:

- stable `id`
- `kind`
- `canonical` / replacement text
- aliases or heard phrases
- optional contexts / scopes
- `source`: built-in, manual, suggested, imported, mined
- `status`: active, disabled, suggested, rejected
- `createdAt`, `updatedAt`
- `lastSeenAt`, `lastUsedAt`
- `seenCount`, `usedCount`, `acceptedCount`, `rejectedCount`
- optional examples by recording/session reference, added in a later slice

Slice 1 does not need every field to be persisted. It should define the model
well enough that adding the evidence path later does not require replacing it.

### Compiler

The compiler maps active safe records into canonicalizer rules.

Required properties:

- Preserve today's default canonicalizer output exactly.
- Preserve rule order where order affects replacement.
- Preserve contextual rule behavior.
- Preserve `canonicalVocabularyStrings`.
- Preserve `speechContextualStrings`.
- Exclude disabled, suggested, and rejected records from runtime rules.
- Keep snippet and future formatting records out of canonicalizer rules unless
  they have an explicit safe compile path.

## Slice 1 / Preslice

Slice ID: `CD-1`

Title: Correction record compiler equivalence

Goal: introduce the dictionary model and compiler without changing runtime
dictation behavior.

Behavior under test: current default correction rules compiled from
`CorrectionRecord` produce the same canonicalizer behavior, same rule order,
same vocabulary strings, and same speech-context strings as today's
`TranscriptCanonicalizer.defaultRules`.

Seam under test: pure Swift API:

```
CorrectionDictionary.defaultRecords
CorrectionRuleCompiler.compile(records:)
TranscriptCanonicalizer(rules:)
```

Boundary:

- Add model/compiler files under `Sources/Epos/Speech/`.
- Add focused unit tests under `Tests/EposTests/`.
- Keep `AppCoordinator`, `CorrectionStore`, and UI behavior unchanged unless a
  minimal adapter is required.
- No app launch, no network, no real audio, no home-directory state.

Files likely touched:

- `Sources/Epos/Speech/CorrectionDictionary.swift`
- `Sources/Epos/Speech/CorrectionRuleCompiler.swift`
- `Sources/Epos/Speech/TranscriptCanonicalizer.swift`
- `Tests/EposTests/CorrectionDictionaryCompilerTests.swift`
- Possibly `Sources/Epos/Speech/CorrectionStore.swift` only if needed for a
  no-behavior-change adapter.

Red tests:

- `CorrectionDictionaryCompilerTests.testDefaultRecordsCompileToCurrentDefaultRules`
- `CorrectionDictionaryCompilerTests.testCompiledCanonicalizerMatchesDefaultCanonicalizer`
- `CorrectionDictionaryCompilerTests.testCompiledVocabularyMatchesDefaultVocabulary`
- `CorrectionDictionaryCompilerTests.testSuggestedDisabledAndRejectedRecordsDoNotCompile`

Fixture / harness:

- In-memory records only.
- Test phrases should cover current built-in categories:
  - proper nouns / acronyms
  - files and extensions
  - developer symbols
  - contextual phrase rules
  - phrase-order overlap such as NetSuite variants

Isolation rule:

- Do not read or write `UserDefaults`.
- Do not depend on the user's real correction rules.
- Do not read saved recordings.

Determinism rule:

- No clock, filesystem, process env, locale mutation, network, ASR, or LLM calls.

Assertion contract:

- Compiled rules equal current default rules or produce an explicitly documented
  order-preserving equivalent.
- Canonicalization outputs match for representative phrases.
- Vocabulary arrays match exactly.
- Inactive records never affect compiled rules.

Green condition:

- `swift test --filter CorrectionDictionaryCompilerTests`
- `swift test --filter SmokeTests/testCanonicalizer`
  for the existing canonicalizer smoke coverage.

Refactor target:

- `TranscriptCanonicalizer.defaultRules` should either remain the compatibility
  source of truth or delegate to compiled `CorrectionDictionary.defaultRecords`.
  Do not leave two divergent default-rule lists.

Smoke budget:

- none

Verification command:

```
swift test --filter CorrectionDictionaryCompilerTests
swift test --filter SmokeTests
```

Decision gate after Slice 1:

- If equivalence is clean, proceed to Slice 2.
- If equivalence requires awkward compatibility code or changes behavior, stop
  and update this spec before continuing.

## Future Slices

### Slice 2: Store-backed CorrectionDictionary

Move the persisted correction source from flat canonicalizer rules toward
dictionary records while preserving user data migration.

Do not choose SQLite here by default. Start with the smallest durable format
that preserves current behavior and can migrate the existing `UserDefaults`
payload safely.

### Slice 3: Correction Evidence Capture

Add a local evidence path for future rule suggestions:

- raw ASR
- canonicalized output
- final inserted output
- user edit / pasted delta where observable
- app/window/url context where accessible
- rule ids applied
- guard/polish outcome

This is where the Flow-like history substrate starts to matter. It is not
Slice 1.

### Slice 4: Candidate Rule Miner

Mine repeated safe misses into suggested records. Suggested records do not
compile into runtime rules until accepted.

Success requires:

- recurrence evidence
- negative examples
- app/context scope when needed
- zero-regression eval against locked baseline rows

### Slice 5: Corrections UI Upgrade

Expose record status, source, scope, usage, snippets, and suggested corrections
without turning the editor into a history browser.

## Update Protocol

Each future session that works on this area must update this file before
handoff:

- Update `Status` if the current slice changed.
- Add a dated entry to `Session Log`.
- Record new artifacts, eval files, or commands.
- Move completed or rejected work out of "Future Slices" ambiguity.
- If a slice changes behavior, record the exact before/after and verification.

Do not let this spec become a transcript dump. Link artifacts and summarize the
decision.

## Session Log

### 2026-06-03

- Created this guide after Wispr Flow architecture investigation, Epos eval
  review, and native subagent second opinion.
- Decision: pursue `CorrectionDictionary -> compiler -> TranscriptCanonicalizer`
  as Slice 1 only if it preserves current behavior exactly.
- Open point: decide in implementation whether `TranscriptCanonicalizer` keeps
  `defaultRules` as compatibility source of truth or delegates to compiled
  `CorrectionDictionary.defaultRecords`.
- Implemented CD-1 as behavior-preserving scaffolding:
  `CorrectionDictionary.defaultRecords` derives from
  `TranscriptCanonicalizer.defaultRules`, and `CorrectionRuleCompiler` compiles
  active lexicon/replacement/spoken-command records into canonicalizer rules.
- Verification for CD-1: red test first, then
  `swift test --filter CorrectionDictionaryCompilerTests`,
  `swift test --filter SmokeTests`, `swift build -Xswiftc -warnings-as-errors`,
  full `swift test`, and `swiftlint --quiet`.
- Slice 2 should not proceed until it decides whether `defaultRecords` becomes
  the source of truth or remains a compatibility projection from
  `TranscriptCanonicalizer.defaultRules`.
