# Correction Dictionary Foundation

Status: CD-4 implemented; CD-5 pending
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

Keep `TranscriptCanonicalizer` as the runtime execution engine, with
`CorrectionDictionary.defaultRecords` owning built-in correction definitions.
User-saved rules now persist as dictionary records while the existing flat
canonicalizer rule API remains a compatibility surface for the editor and
legacy payload migration.
Finalization evidence is captured into a bounded local store and edited-miss
evidence can produce suggested inactive records.

Do not replace Apple `SpeechTranscriber`.
Do not loosen the LLM polish guard as part of this work.
Do not introduce SQLite or persistent transcription history in CD-2.

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

## Slice 2

Slice ID: `CD-2`

Title: Make CorrectionDictionary the default rule source

Goal: move built-in correction definitions into `CorrectionRecord` form and
derive `TranscriptCanonicalizer.defaultRules` from the compiler.

Behavior under test: no user-facing correction behavior changes; today's
default canonicalizer output, vocabulary strings, speech context strings, and
flat saved-rule behavior remain unchanged.

Seam under test:

```
CorrectionDictionary.defaultRecords
CorrectionRuleCompiler.compile(records:)
TranscriptCanonicalizer.defaultRules
TranscriptCanonicalizer.load(from:)
```

Boundary:

- Move built-in default definitions into `CorrectionDictionary.defaultRecords`.
- Derive `TranscriptCanonicalizer.defaultRules` from compiled default records.
- Preserve existing flat `UserDefaults` rule save/load behavior.
- No UI changes.
- No `UserDefaults` migration yet.
- No learning, mining, scoring, ASR, or polish changes.

Red test:

- `CorrectionDictionaryCompilerTests.testBuiltInSpokenCommandRecordsCarryRecordSemantics`

Verification command:

```
swift test --filter CorrectionDictionaryCompilerTests
swift test --filter SmokeTests
swift build -Xswiftc -warnings-as-errors
swift test
swiftlint --quiet
```

## Slice 3

Slice ID: `CD-3`

Title: Persist CorrectionDictionary records

Goal: move the persisted correction source from flat canonicalizer rules toward
dictionary records while preserving existing flat-rule behavior and migration.

Behavior under test: saving rules through the current `CorrectionStore` writes a
dictionary-record payload, `TranscriptCanonicalizer.load(from:)` reads compiled
dictionary records, and current/legacy flat payloads still migrate with the same
runtime behavior.

Seam under test:

```
CorrectionStore.save(_:)
CorrectionDictionary.load(from:)
CorrectionDictionary.saveRecords(_:to:)
TranscriptCanonicalizer.load(from:)
TranscriptCanonicalizer.saveRules(_:to:)
```

Boundary:

- Add a `UserDefaults`-backed dictionary record payload.
- Keep the existing flat canonicalizer rule API as compatibility.
- Migrate versioned flat stored rules as replacement records.
- Migrate legacy unversioned flat custom rules before built-in defaults.
- No UI changes.
- No ASR, polish, learning, mining, evidence capture, scoring, or promotion
  changes.

Red tests:

- `CorrectionDictionaryPersistenceTests.testCorrectionStoreSavesRulesAsDictionaryRecords`
- `CorrectionDictionaryPersistenceTests.testTranscriptCanonicalizerLoadsPersistedDictionaryRecords`
- `CorrectionDictionaryPersistenceTests.testDictionaryMigratesVersionedFlatRulesAsReplacementRecords`
- `CorrectionDictionaryPersistenceTests.testDictionaryMigratesLegacyFlatRulesBeforeDefaults`

Verification command:

```
swift test --filter CorrectionDictionaryPersistenceTests
swift test --filter CorrectionDictionaryCompilerTests
swift test --filter SmokeTests
swift build -Xswiftc -warnings-as-errors
swift test
swiftlint --quiet
```

Implementation notes:

- `CorrectionDictionary.recordsDefaultsKey` is the new authoritative dictionary
  persistence key.
- `TranscriptCanonicalizer.rulesDefaultsKey` remains as a compatibility mirror
  and migration source for existing flat payloads.
- The Corrections editor still edits flat `TranscriptCanonicalizer.Rule` rows;
  a later UI upgrade can expose record metadata.

Do not choose SQLite here by default. Start with the smallest durable format
that preserves current behavior and can migrate the existing `UserDefaults`
payload safely.

## Slice 4

Slice ID: `CD-4`

Title: Correction evidence capture / candidate suggestions

Add a local evidence path for future rule suggestions:

- raw ASR
- canonicalized output
- final inserted output
- user edit / pasted delta where observable
- app/window/url context where accessible
- rule ids applied
- guard/polish outcome

This is where the Flow-like history substrate starts to matter. It is not CD-2
or CD-3.

Behavior under test: each finalized transcript can record raw ASR text,
canonicalized output, final inserted output, applied rule IDs, and polish/guard
outcome into a bounded local store. When edited-miss evidence includes a
user-edited transcript, the deterministic suggester can create inactive
`CorrectionRecord` suggestions.

Seam under test:

```
CorrectionEvidenceStore.record(_:)
CorrectionCandidateSuggester.suggestedRecords(from:)
CorrectionDictionary.appliedRecordIDs(in:)
AppCoordinator.recordCorrectionEvidence(...)
```

Boundary:

- Capture finalization evidence after polish/insertion decision.
- Persist a bounded local evidence list.
- Add a deterministic phrase-diff suggester for edited miss evidence.
- Suggested records use `source: .suggested` and `status: .suggested`.
- Suggested records do not compile into runtime canonicalizer rules.
- No UI changes.
- No ASR, polish-policy, persistence-migration, scoring, or promotion-gate
  changes.

Red tests:

- `CorrectionEvidenceTests.testEvidenceStorePersistsRecentFinalizationEvidence`
- `CorrectionEvidenceTests.testEditedMissEvidenceCreatesSuggestedRecordThatDoesNotCompile`
- `CorrectionEvidenceTests.testCoordinatorCapturesCorrectionEvidenceAtFinalization`

Verification command:

```
swift test --filter CorrectionEvidenceTests
swift test --filter CorrectionDictionaryPersistenceTests
swift test --filter CorrectionDictionaryCompilerTests
swift test --filter SmokeTests
swift build -Xswiftc -warnings-as-errors
swift test
swiftlint --quiet
```

Implementation notes:

- `CorrectionEvidenceStore.evidenceDefaultsKey` stores recent local evidence in
  `UserDefaults` with a bounded count.
- Runtime capture currently observes finalization data; user edit deltas are a
  model/API field for future observable edit hooks.
- `CorrectionCandidateSuggester` creates deterministic one-span phrase
  replacement suggestions from evidence that already contains a user-edited
  transcript.

## Future Slices

### CD-5: Risk Scoring And Promotion Gate

Mine repeated safe misses into suggested records. Suggested records do not
compile into runtime rules until accepted.

Success requires:

- recurrence evidence using CD-4 observations
- negative examples
- app/context scope when needed
- zero-regression eval against locked baseline rows

Score suggested records for recurrence, scope risk, phrase ambiguity, negative
examples, and locked-eval regressions before allowing promotion to active
runtime rules.

### Later: Corrections UI Upgrade

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
- Implemented CD-2 as the source-of-truth flip:
  `CorrectionDictionary.defaultRecords` now owns the built-in correction
  definitions, command-token defaults carry `.spokenCommand` record semantics,
  and `TranscriptCanonicalizer.defaultRules` derives from
  `CorrectionRuleCompiler.compile(records: CorrectionDictionary.defaultRecords)`.
- Verification for CD-2: red
  `CorrectionDictionaryCompilerTests.testBuiltInSpokenCommandRecordsCarryRecordSemantics`,
  then `swift test --filter CorrectionDictionaryCompilerTests`,
  `swift test --filter SmokeTests`, `swift build -Xswiftc -warnings-as-errors`,
  full `swift test`, and `swiftlint --quiet`.
- Implemented CD-3 dictionary-backed persistence:
  `CorrectionDictionary` now loads/saves versioned record payloads,
  `CorrectionStore.save(_:)` persists edited rules as dictionary records,
  `TranscriptCanonicalizer.load(from:)` compiles loaded records, and flat
  stored-rule payloads migrate into dictionary records while preserving current
  behavior.
- Verification for CD-3: red
  `CorrectionDictionaryPersistenceTests`, then
  `swift test --filter CorrectionDictionaryPersistenceTests`,
  `swift test --filter CorrectionDictionaryCompilerTests`,
  `swift test --filter SmokeTests`, `swift build -Xswiftc -warnings-as-errors`,
  full `swift test`, and `swiftlint --quiet`.
- Implemented CD-4 evidence capture and suggestions:
  `CorrectionEvidenceStore` now persists bounded finalization evidence,
  `AppCoordinator` records raw/canonicalized/inserted transcript evidence after
  polish/insertion decisions, `CorrectionDictionary.appliedRecordIDs(in:)`
  reports active correction records that match the raw transcript, and
  `CorrectionCandidateSuggester` creates inactive suggested replacement records
  from edited-miss evidence.
- Verification for CD-4: red `CorrectionEvidenceTests`, then
  `swift test --filter CorrectionEvidenceTests`,
  `swift test --filter CorrectionDictionaryPersistenceTests`,
  `swift test --filter CorrectionDictionaryCompilerTests`,
  `swift test --filter SmokeTests`, `swift build -Xswiftc -warnings-as-errors`,
  full `swift test`, and `swiftlint --quiet`.
- CD-4 verifier found that applied-rule evidence over-reported contextual rules.
  Added `CorrectionEvidenceTests.testAppliedRuleIDsRespectContextualRules` and
  made `CorrectionDictionary.appliedRecordIDs(in:)` preserve canonicalizer
  context gating.
- CD-4 verifier also found that applied-rule evidence under-reported cascaded
  canonicalizer rules. Added
  `CorrectionEvidenceTests.testAppliedRuleIDsIncludeCascadedRules` and made
  applied-ID tracking simulate the canonicalizer's sequential replacements.
