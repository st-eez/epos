# Correction Dictionary Foundation

Status: CD-12 implemented; verified
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
Suggested records can now be scored by a non-mutating promotion gate before any
record is allowed to become active. Observable same-target user edits can update
existing evidence rows, and accepted blocker-free promotion assessments can be
persisted into the active correction dictionary. The Corrections window now
surfaces pending suggestions with recurrence/risk/evidence context, supports
accept/reject, and evidence rows can carry optional insertion target app/window
context for dogfood review.
Post-insertion edit capture now uses a sparse 2s/6s/12s/15s same-target
capture window instead of a single 1.5s check, so real dogfood edits have time
to be read without continuous polling.

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

## Slice 5

Slice ID: `CD-5`

Title: Risk scoring and promotion gate

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

Behavior under test: suggested correction records receive a promotion
assessment with recurrence evidence, negative evidence, conflicting suggestion
evidence, phrase risk, scope risk, and locked-baseline regression blockers.
Only assessments without blockers expose an active promoted record.

Seam under test:

```
CorrectionEvidenceStore.promotionAssessments
CorrectionPromotionGate.assess(...)
CorrectionPromotionAssessment.promotedRecord
```

Boundary:

- Score existing suggested records from CD-4 evidence.
- Require repeated positive edited-miss evidence before promotion.
- Block explicit no-change negative examples.
- Block conflicting canonical suggestions for the same alias.
- Score phrase ambiguity and app-scope risk.
- Block locked baseline rows that would change under the promoted record.
- No automatic activation.
- No UI changes.
- No ASR, polish-policy, or UserDefaults migration changes.

Red tests:

- `CorrectionPromotionGateTests.testPromotionGateBlocksUntilSuggestionRecurs`
- `CorrectionPromotionGateTests.testPromotionGateBlocksExplicitNegativeExamples`
- `CorrectionPromotionGateTests.testPromotionGateBlocksAmbiguousShortPhrases`
- `CorrectionPromotionGateTests.testPromotionGateBlocksLockedBaselineRegressions`
- `CorrectionPromotionGateTests.testPromotionGateScoresSingleAppEvidenceAsMediumScopeRisk`
- `CorrectionPromotionGateTests.testPromotionGateBlocksConflictingCanonicalSuggestions`
- `CorrectionPromotionGateTests.testEvidenceStoreExposesPromotionAssessmentsForSuggestions`

Verification command:

```
swift test --filter CorrectionPromotionGateTests
swift test --filter CorrectionEvidenceTests
swift test --filter CorrectionDictionaryCompilerTests
swift test --filter CorrectionDictionaryPersistenceTests
swift test --filter SmokeTests
swift build -Xswiftc -warnings-as-errors
swift test
swiftlint --quiet
```

Implementation notes:

- `CorrectionPhraseDiff` is shared by suggestion generation and promotion
  scoring so both paths extract the same replacement phrase.
- `CorrectionPromotionAssessment.promotedRecord` is nil until blockers are
  clear; promotion is still caller-controlled and non-persistent.
- Single-app positive evidence is scored as medium scope risk but is not blocked
  unless conflicting suggestion evidence makes scope risk high.

## Slice 6

Slice ID: `CD-6`

Title: Capture observed user edits

Goal: turn real post-insertion user edits into correction evidence without
changing runtime correction behavior.

Behavior under test: finalization evidence is recorded with a stable evidence
ID. When the same observable insertion target later shows that the inserted span
changed, the existing evidence row is updated with `userEditedTranscript`.
Opaque or mismatched targets do not create edit evidence.

Seam under test:

```
CorrectionEvidenceStore.record(_:) -> String
CorrectionEvidenceStore.recordUserEdit(evidenceID:userEditedTranscript:)
ProgressiveTranscriptInsertionSession.observedInsertedText()
AppCoordinator.recordCorrectionEvidence(...)
AppCoordinator.scheduleObservedUserEditCapture(...)
```

Boundary:

- Capture only same-target edits that preserve the original surrounding
  insertion context.
- Do not activate, promote, or persist correction records from the edit.
- Do not add UI.
- Do not add a history database or long-running transcript browser.
- Do not change ASR, polish policy, insertion behavior, or UserDefaults
  dictionary migration.

Files likely touched:

- `Sources/Epos/Speech/CorrectionEvidence.swift`
- `Sources/Epos/Inject/ProgressiveTranscriptInsertion.swift`
- `Sources/Epos/App/AppCoordinator.swift`
- `Tests/EposTests/CorrectionEvidenceTests.swift`
- `Tests/EposTests/InsertionTargetGuardTests.swift`

Red tests:

- `CorrectionEvidenceTests.testEvidenceStoreUpdatesExistingRowWithObservedUserEdit`
- `InsertionTargetGuardTests.testSessionObservesEditedInsertedSpanAfterFinish`
- `CorrectionEvidenceTests.testCoordinatorReturnsStableEvidenceIDForLaterEditCapture`
- `CorrectionEvidenceTests.testCoordinatorSchedulesObservedUserEditCapture`
- `InsertionTargetGuardTests.testSessionDoesNotObserveInsertedSpanForOpaqueTarget`

Fixture / harness: isolated `UserDefaults` suites, fake insertion target
observer, and existing coordinator test harness with `autoStart: false`.

Isolation rule: no real Accessibility calls, no real focused app, no live
keyboard events, no shared `UserDefaults.standard`.

Determinism rule: fixed recording IDs and explicit fake observer values; no
wall-clock assertions beyond existing stored timestamps.

Assertion contract: the updated evidence row keeps its original raw,
canonicalized, final inserted, and applied-rule fields, sets
`userEditedTranscript` only when the observed inserted span differs, and makes
existing suggestion generation see the edit.

Green condition:

```
swift test --filter CorrectionEvidenceTests
swift test --filter InsertionTargetGuardTests
swift test --filter CorrectionPromotionGateTests
swift test --filter SmokeTests
```

Refactor target: keep target-span extraction as a small pure helper or session
method; do not grow the coordinator into an edit-monitor state machine.

Smoke budget: none.

Verification command:

```
swift test --filter CorrectionEvidenceTests
swift test --filter InsertionTargetGuardTests
swift test --filter CorrectionPromotionGateTests
swift test --filter SmokeTests
swift build -Xswiftc -warnings-as-errors
swift test
swiftlint --quiet
```

## Slice 7

Slice ID: `CD-7`

Title: Persist accepted suggestion promotions

Goal: provide a non-UI promotion API that accepts a clear promotion assessment
and persists the promoted record into the active correction dictionary.

Behavior under test: when an assessment has no blockers, accepting it adds the
assessment's `promotedRecord` to the persisted dictionary and refreshes the live
canonicalizer. Blocked assessments and rejected suggestions do not change active
runtime rules.

Seam under test:

```
CorrectionStore.acceptPromotion(_:)
CorrectionPromotionAssessment.promotedRecord
CorrectionDictionary.saveRecords(_:to:)
```

Boundary:

- No UI changes.
- No automatic promotion.
- No bypass around `CorrectionPromotionGate`.
- No evidence capture changes.
- No ASR, polish-policy, or UserDefaults migration changes.

Files likely touched:

- `Sources/Epos/Speech/CorrectionStore.swift`
- `Tests/EposTests/CorrectionDictionaryPersistenceTests.swift`

Red tests:

- `CorrectionDictionaryPersistenceTests.testCorrectionStoreAcceptsPromotedSuggestion`
- `CorrectionDictionaryPersistenceTests.testCorrectionStoreRejectsBlockedPromotion`

Fixture / harness: isolated `UserDefaults` suites plus deterministic
`CorrectionEvidence` rows that produce a clear promotion assessment.

Isolation rule: no real Accessibility calls, no live dictation, no shared
`UserDefaults.standard`, and no UI editor interaction.

Determinism rule: fixed evidence IDs and explicit evidence rows; promotion
acceptance depends only on the supplied `CorrectionPromotionAssessment`.

Assertion contract: accepted blocker-free assessments append or replace the
promoted active record in the persisted dictionary and immediately update the
live canonicalizer; blocked assessments return false and leave records
unchanged.

Green condition:

```
swift test --filter CorrectionDictionaryPersistenceTests
swift test --filter CorrectionPromotionGateTests
swift test --filter CorrectionEvidenceTests
swift test --filter SmokeTests
```

Refactor target: keep promotion acceptance in `CorrectionStore`, not in the
compiler or evidence store.

Smoke budget: none.

Verification command:

```
swift test --filter CorrectionDictionaryPersistenceTests
swift test --filter CorrectionPromotionGateTests
swift test --filter CorrectionEvidenceTests
swift test --filter SmokeTests
swift build -Xswiftc -warnings-as-errors
swift test
swiftlint --quiet
```

## Future Slices

## Slice 8

Slice ID: `CD-8`

Title: Suggestion review model and resolution state

Goal: create a deterministic review model for suggested corrections and persist
rejected suggestions so accepted/rejected suggestions stop appearing as pending.

Behavior under test: unresolved promotion assessments become review items with
alias, canonical, evidence count, blocker/risk summary, and accept eligibility.
Accepted and rejected suggestion record IDs are filtered out of pending review
items.

Seam under test:

```
CorrectionSuggestionReviewItem.items(...)
CorrectionStore.rejectSuggestion(_:)
CorrectionStore.acceptPromotion(_:)
```

Boundary:

- No UI layout changes in this slice.
- No automatic promotion.
- No ASR or polish changes.
- No evidence mining changes beyond filtering resolved suggestion IDs.

Files likely touched:

- `Sources/Epos/Speech/CorrectionStore.swift`
- `Sources/Epos/UI/CorrectionSuggestionReviewItem.swift`
- `Tests/EposTests/CorrectionSuggestionReviewTests.swift`
- `Tests/EposTests/CorrectionDictionaryPersistenceTests.swift`

Red tests:

- `CorrectionSuggestionReviewTests.testReviewItemsExposeAcceptableAndBlockedSuggestions`
- `CorrectionSuggestionReviewTests.testReviewItemsHideAcceptedAndRejectedSuggestions`
- `CorrectionDictionaryPersistenceTests.testCorrectionStorePersistsRejectedSuggestion`

Fixture / harness: isolated `UserDefaults`, deterministic evidence rows, and
pure review item construction.

Isolation rule: no real UI, no Accessibility, no live app state, no shared
`UserDefaults.standard`.

Determinism rule: fixed evidence IDs, explicit evidence arrays, no clock
assertions.

Assertion contract: review items must preserve promotion assessment state,
accepted/rejected IDs must hide from pending items, and rejected records must not
compile into runtime rules.

Green condition:

```
swift test --filter CorrectionSuggestionReviewTests
swift test --filter CorrectionDictionaryPersistenceTests
swift test --filter CorrectionPromotionGateTests
```

Refactor target: keep UI-independent review logic outside the SwiftUI view.

Smoke budget: none.

Verification command:

```
swift test --filter CorrectionSuggestionReviewTests
swift test --filter CorrectionDictionaryPersistenceTests
swift test --filter CorrectionPromotionGateTests
swift test --filter SmokeTests
swift build -Xswiftc -warnings-as-errors
swift test
swiftlint --quiet
```

## Slice 9

Slice ID: `CD-9`

Title: Corrections UI suggestions section

Goal: make suggested corrections visible and actionable in the existing
Corrections window.

Behavior under test: the corrections editor receives a `CorrectionEvidenceStore`,
shows pending suggestion review items above manual rules, enables Accept only
when the promotion assessment can promote, and supports Reject for pending
suggestions.

Seam under test:

```
CorrectionsEditorView(store:evidenceStore:)
CorrectionSuggestionReviewItem
CorrectionStore.acceptPromotion(_:)
CorrectionStore.rejectSuggestion(_:)
```

Boundary:

- Keep the existing manual rule editor working.
- No new windows or history browser.
- No automatic promotion.
- No ASR, polish, or evidence capture changes.

Files likely touched:

- `Sources/Epos/App/EposApp.swift`
- `Sources/Epos/UI/CorrectionsEditorView.swift`
- `Sources/Epos/UI/CorrectionSuggestionRow.swift`
- `Tests/EposTests/SmokeTests.swift`

Red tests:

- `SmokeTests.testSuggestionReviewItemsBackCorrectionsEditorActions`

Fixture / harness: model-level UI action harness; runtime visual verification
via signed app build/install/open after implementation.

Isolation rule: unit tests avoid real SwiftUI inspection dependencies and use
isolated stores.

Determinism rule: deterministic evidence rows and no live AX/mic state in unit
tests.

Assertion contract: Accept persists an active rule and hides the suggestion;
Reject persists a rejected record and hides the suggestion; blocked suggestions
remain visible but not accept-eligible.

Green condition:

```
swift test --filter SmokeTests/testSuggestionReviewItemsBackCorrectionsEditorActions
swift build -Xswiftc -warnings-as-errors
```

Refactor target: keep view code thin by delegating review state to
`CorrectionSuggestionReviewItem`.

Smoke budget: single signed-app launch smoke.

Verification command:

```
swift test --filter CorrectionSuggestionReviewTests
swift test --filter CorrectionDictionaryPersistenceTests
swift test --filter SmokeTests
swift build -Xswiftc -warnings-as-errors
swift test
swiftlint --quiet
scripts/build-signed-app.sh
scripts/install-signed-app.sh
open /Applications/Epos.app
```

## Slice 10

Slice ID: `CD-10`

Title: Dogfood review evidence surface

Goal: make tomorrow-morning dogfood review trustworthy by showing why a
suggestion exists without turning the editor into a history browser.

Behavior under test: each suggestion review item exposes recurrence count,
positive evidence IDs, blocker names, risk names, and a bounded evidence example
that can be displayed in the row.

Seam under test:

```
CorrectionSuggestionReviewItem
CorrectionEvidenceStore.promotionAssessments
```

Boundary:

- Display only bounded examples and counts.
- No transcript history browser.
- No new persistence format.
- No ASR or polish changes.

Red tests:

- `CorrectionSuggestionReviewTests.testReviewItemsExposeEvidenceAndRiskSummary`

Verification command:

```
swift test --filter CorrectionSuggestionReviewTests
swift test --filter SmokeTests
swift build -Xswiftc -warnings-as-errors
swift test
swiftlint --quiet
```

## Slice 11

Slice ID: `CD-11`

Title: Dogfood context capture

Goal: capture lightweight app/window context in correction evidence when the
current insertion target exposes it, so dogfood review can tell whether a
suggestion is app-local.

Behavior under test: finalization evidence can include application bundle ID and
window title from the insertion target observer without requiring real AX in unit
tests.

Seam under test:

```
InsertionTargetObserver
AXInsertionTargetObserver
AppCoordinator.recordCorrectionEvidence(...)
CorrectionEvidence.applicationBundleIdentifier/windowTitle
```

Boundary:

- No URL scraping unless already exposed cheaply by the target.
- No broad AX tree walking.
- No ASR or polish changes.
- Context absence must be allowed.

Red tests:

- `CorrectionEvidenceTests.testCoordinatorCapturesInsertionTargetContext`

Verification command:

```
swift test --filter CorrectionEvidenceTests
swift test --filter InsertionTargetGuardTests
swift build -Xswiftc -warnings-as-errors
swift test
swiftlint --quiet
```

## Slice 12

Slice ID: `CD-12`

Title: Sparse post-insertion edit capture window

Goal: make real dogfood correction capture usable without adding continuous
watching or slowing dictation.

Behavior under test: after final insertion, Epos schedules a short sparse set of
same-target edit-capture checks across roughly 10-15 seconds. A user edit within
that window updates the existing correction evidence row; unchanged, unreadable,
or moved-focus targets do not record an edit. Pending checks are canceled when a
new recording starts.

Seam under test:

```
AppCoordinator.scheduleObservedUserEditCapture(...)
AppCoordinator.captureObservedUserEdit(...)
ProgressiveTranscriptInsertionSession.observedInsertedText()
CorrectionEvidenceStore.recordUserEdit(...)
```

Boundary:

- No continuous polling or long-lived document watching.
- No ASR, polish, canonicalizer, or suggestion scoring changes.
- No automatic promotion.
- No capture after the short window expires.
- Do not block insertion/finalization; checks stay delayed and sparse.

Files likely touched:

- `Sources/Epos/App/AppCoordinator.swift`
- `Tests/EposTests/CorrectionEvidenceTests.swift`
- `specs/correction-dictionary-foundation.md`

Red tests:

- `CorrectionEvidenceTests.testCoordinatorCapturesObservedUserEditAcrossSparseWindow`

Fixture / harness: unit test with `observedEditCaptureDelays` set to short
deterministic intervals, a fake insertion target observer, and async waiting
bounded to the test process.

Isolation rule: no real AX, no mic, no filesystem, no shared defaults.

Determinism rule: test controls delay values and observer values; no reliance on
wall-clock dogfood state.

Assertion contract: an edit made after the first unchanged check but before a
later scheduled check updates `userEditedTranscript` exactly once, and a
subsequent scheduled check after successful capture does not overwrite it.

Green condition:

```
swift test --filter CorrectionEvidenceTests/testCoordinatorCapturesObservedUserEditAcrossSparseWindow
swift test --filter CorrectionEvidenceTests
swift test --filter InsertionTargetGuardTests
```

Refactor target: keep the scheduling policy explicit and injectable; avoid
embedding timers in evidence storage or insertion session logic.

Smoke budget: no runtime smoke required unless production app wiring changes
beyond scheduler defaults.

Verification command:

```
swift test --filter CorrectionEvidenceTests
swift test --filter InsertionTargetGuardTests
swift test --filter SmokeTests
swift build -Xswiftc -warnings-as-errors
swift test
swiftlint --quiet
git diff --check
```

### Later: Rich Corrections UI Upgrade

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
- Implemented CD-5 risk scoring and promotion gate:
  `CorrectionPromotionGate` now assesses suggested records for recurrence,
  explicit no-change negatives, conflicting canonical suggestions, phrase risk,
  app-scope risk, and locked-baseline regressions. `CorrectionEvidenceStore`
  exposes promotion assessments without activating or persisting promoted
  records.
- Verification for CD-5: red `CorrectionPromotionGateTests`, then
  `swift test --filter CorrectionPromotionGateTests`,
  `swift test --filter CorrectionEvidenceTests`,
  `swift test --filter CorrectionDictionaryCompilerTests`,
  `swift test --filter CorrectionDictionaryPersistenceTests`,
  `swift test --filter SmokeTests`, `swift build -Xswiftc -warnings-as-errors`,
  full `swift test`, and `swiftlint --quiet`.
- CD-5 verifier found that duplicate evidence rows could fake recurrence.
  Added
  `CorrectionPromotionGateTests.testPromotionGateDoesNotCountDuplicateEvidenceAsRecurrence`
  and made recurrence scoring count distinct recording IDs, falling back to
  evidence IDs.
- Implemented CD-6 observed user-edit capture seam:
  `CorrectionEvidenceStore.record(_:)` returns a stable evidence ID,
  `CorrectionEvidenceStore.recordUserEdit(...)` updates existing evidence rows,
  `ProgressiveTranscriptInsertionSession.observedInsertedText()` extracts the
  inserted span from the guarded insertion context, `AppCoordinator.recordCorrectionEvidence(...)`
  returns the evidence ID, and `AppCoordinator.scheduleObservedUserEditCapture(...)`
  performs the bounded delayed same-target read after finalization.
- Verification for CD-6: red
  `CorrectionEvidenceTests.testEvidenceStoreUpdatesExistingRowWithObservedUserEdit`,
  `InsertionTargetGuardTests.testSessionObservesEditedInsertedSpanAfterFinish`,
  and `CorrectionEvidenceTests.testCoordinatorReturnsStableEvidenceIDForLaterEditCapture`,
  then verifier found that the production finalization path did not wire those
  seams together. Added
  `CorrectionEvidenceTests.testCoordinatorSchedulesObservedUserEditCapture` and
  `InsertionTargetGuardTests.testSessionDoesNotObserveInsertedSpanForOpaqueTarget`,
  wired finalization to `scheduleObservedUserEditCapture(...)`, then ran
  `swift test --filter CorrectionEvidenceTests`,
  `swift test --filter InsertionTargetGuardTests`,
  `swift test --filter CorrectionPromotionGateTests`,
  `swift test --filter SmokeTests`, `swift build -Xswiftc -warnings-as-errors`,
  full `swift test`, `swiftlint --quiet`, and `git diff --check`.
- Implemented CD-7 accepted promotion persistence:
  `CorrectionStore.acceptPromotion(_:)` accepts only assessments with a
  `promotedRecord`, appends or replaces the promoted active record in
  `CorrectionDictionary`, saves the dictionary payload, and refreshes the live
  canonicalizer.
- Verification for CD-7: red
  `CorrectionDictionaryPersistenceTests.testCorrectionStoreAcceptsPromotedSuggestion`
  and `CorrectionDictionaryPersistenceTests.testCorrectionStoreRejectsBlockedPromotion`,
  then `swift test --filter CorrectionDictionaryPersistenceTests`,
  `swift test --filter CorrectionPromotionGateTests`,
  `swift test --filter CorrectionEvidenceTests`,
  `swift test --filter SmokeTests`, `swift build -Xswiftc -warnings-as-errors`,
  full `swift test`, `swiftlint --quiet`, and `git diff --check`.
- Implemented CD-8 suggestion review model and resolution state:
  `CorrectionSuggestionReviewItem` turns promotion assessments into pending
  review rows, `CorrectionStore.rejectSuggestion(_:)` persists rejected
  suggested records, and manual-rule saves preserve accepted/rejected suggested
  records so resolved suggestions do not reappear.
- Implemented CD-9 Corrections UI suggestions section:
  `CorrectionsEditorView(store:evidenceStore:)` shows pending suggestions above
  manual rules, Accept promotes only blocker-free assessments, Reject persists a
  rejected record, and both actions hide the resolved suggestion.
- Implemented CD-10 dogfood review evidence surface:
  suggestion rows expose positive evidence IDs/counts, phrase/scope risk,
  blockers, a bounded before/after example, and optional app/window context.
- Implemented CD-11 lightweight insertion-target context capture:
  `InsertionTargetObserver` exposes optional app bundle ID and window title,
  `AXInsertionTargetObserver` captures them from the baseline focused target,
  `ProgressiveTranscriptInsertionSession` passes them through, and
  `AppCoordinator.recordCorrectionEvidence(...)` stores them on finalization
  evidence when available.
- Verification for CD-8 through CD-11: red focused tests first, then
  `swift test --filter CorrectionSuggestionReviewTests`,
  `swift test --filter CorrectionEvidenceTests`,
  `swift test --filter InsertionTargetGuardTests`,
  `swift test --filter CorrectionDictionaryPersistenceTests`,
  `swift test --filter SmokeTests`, `swift build -Xswiftc -warnings-as-errors`,
  full `swift test` (185 tests, 7 expected gated skips),
  `swiftlint --quiet`, `git diff --check`, `scripts/build-signed-app.sh`,
  `scripts/install-signed-app.sh`, `open /Applications/Epos.app`, and
  `codesign --verify --strict --verbose=2 /Applications/Epos.app`.
  Verifier rerun returned PASS after probing the stale accept path, repeated
  accept/reject actions, and manual-save preservation.
- Verifier found that a stale pre-rejection promotion assessment could
  reactivate a rejected suggested record. Added
  `CorrectionDictionaryPersistenceTests.testCorrectionStoreDoesNotAcceptStaleRejectedSuggestion`
  and made `CorrectionStore.acceptPromotion(_:)` refuse stale accepts when the
  current dictionary already has the same suggested record ID resolved to a
  non-suggested status. Post-fix verification reran
  `swift test --filter CorrectionDictionaryPersistenceTests`,
  `swift test --filter CorrectionSuggestionReviewTests`,
  `swift test --filter SmokeTests`, `swift build -Xswiftc -warnings-as-errors`,
  full `swift test` (186 tests, 7 expected gated skips),
  `swiftlint --quiet`, `git diff --check`, `scripts/build-signed-app.sh`,
  `scripts/install-signed-app.sh`, `open /Applications/Epos.app`, and
  `codesign --verify --strict --verbose=2 /Applications/Epos.app`.
- Implemented CD-12 sparse post-insertion edit capture:
  `AppCoordinator.defaultObservedEditCaptureDelays` now checks at
  2s/6s/12s/15s by default, `scheduleObservedUserEditCapture(...)` schedules
  sparse delayed checks instead of one 1.5s read, cancels prior pending checks
  when a new schedule starts, and cancels remaining checks after the first
  successful edit capture. `startRecording()` cancels pending capture checks
  once a new recording can start.
- Verification for CD-12: red
  `CorrectionEvidenceTests.testCoordinatorCapturesObservedUserEditAcrossSparseWindow`
  first failed because the coordinator only accepted a single
  `observedEditCaptureDelay`, then passed after introducing injectable
  `observedEditCaptureDelays`. Ran
  `swift test --filter CorrectionEvidenceTests`,
  `swift test --filter InsertionTargetGuardTests`,
  `swift test --filter SmokeTests`, `swift build -Xswiftc -warnings-as-errors`,
  full `swift test` (187 tests, 7 expected gated skips),
  `swiftlint --quiet`, `git diff --check`, `scripts/build-signed-app.sh`,
  `scripts/install-signed-app.sh`, `open /Applications/Epos.app`, and
  `codesign --verify --strict --verbose=2 /Applications/Epos.app`.
  Verifier returned PASS and found one low-risk direct-call edge case where
  `scheduleObservedUserEditCapture(..., session: nil)` did not cancel already
  pending checks. Moved cancellation before the nil-session return and added
  `CorrectionEvidenceTests.testCoordinatorNilObservedEditSessionCancelsPendingChecks`.
  Post-fix verification reran `swift test --filter CorrectionEvidenceTests`,
  `swift build -Xswiftc -warnings-as-errors`, full `swift test` (188 tests,
  7 expected gated skips), `swiftlint --quiet`, and `git diff --check`.
  Focused verifier rerun returned PASS, including an independent harness that
  confirmed nil-session scheduling cancels pending work without reading the
  target, sparse reads occur only at configured delays, first successful capture
  cancels later checks, and a new schedule cancels prior pending work.
