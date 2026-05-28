# Stable Progressive Insertion Design Spec

## Metadata

- Status: initial implementation shipped; target guards remain backlog
- Date: 2026-05-28
- Owner: Epos
- Related shipped spec: `specs/baseline.md`
- Supersedes for default product path: selected InputMethodKit input-source insertion

## Context

The current baseline product is reliable because it keeps the focused app untouched while recording, then inserts the corrected final transcript through `PasteTextInjector` on `fn` release. That behavior is documented in `specs/baseline.md`: hold `fn`, record, show live partial text in Epos UI, release, then paste final text into the frontmost app.

The native-inline plan attempted to make partial text appear inside the target field by adding an InputMethodKit input method. That is technically valid for true marked text, but it requires the Epos input method to be installed and selected. Once selected, all user keyboard input and shortcuts are routed through Epos's input method controller. That violates the expected default UX: Epos should be a dictation app, not the user's active keyboard source.

Epos still needs better perceived streaming. The safer default path is stable progressive insertion: insert only words that are likely stable into the focused target while keeping the recognizer's volatile tail in the Epos overlay. This gives the user word-by-word progress without requiring input-source switching and without repeatedly rewriting unstable partials in arbitrary apps.

## Goals

- Stream stable word deltas into the target app while the user is dictating.
- Preserve normal keyboard shortcuts and input sources.
- Keep the current final paste behavior as the default fallback.
- Avoid mutating text that the recognizer may still revise.
- Preserve deterministic correction rules as much as possible before text is inserted.
- Keep transcript payloads out of logs, diagnostics, and persisted state.

## Non-goals

- Exact Apple Dictation behavior.
- Default production use of a selected Epos InputMethodKit input source.
- Blue underline, candidate selection, or ambiguous-word correction UI.
- Rewriting or deleting previously inserted text in arbitrary apps.
- Live progressive insertion into terminals for the first release.
- LLM polish, grammar rewrite, or filler-word removal.

## Constraints & Assumptions

- `SpeechTranscriber` partials are volatile. A partial may revise earlier words, punctuation, or spacing.
- `SpeechTranscriber` final segment events are more stable than partials, but may still arrive in chunks that are too coarse for Apple-Dictation-style progress.
- The current correction layer canonicalizes whole transcript strings. Streaming cannot blindly insert raw partial words and then expect final canonicalization to repair earlier text.
- Accessibility permission is required for synthetic text insertion into other apps.
- The target text field can change during recording. Progressive insertion must be anchored to the target captured at recording start.
- Some apps expose incomplete Accessibility information. Progressive insertion must degrade to overlay plus final paste when the target cannot be guarded.
- No scripts or configs may hardcode machine-specific absolute paths.

## Requirements

1. Epos does not require or prompt the user to select an Epos input method for default dictation.
2. During recording, Epos inserts only stable word-boundary deltas into the original focused target.
3. The unstable tail remains visible in the Epos recording overlay and is not inserted yet.
4. If progressive insertion is unavailable before any delta is inserted, Epos keeps the existing overlay plus final paste behavior.
5. If progressive insertion fails after deltas were inserted, Epos stops further live insertion, keeps showing the full transcript in the overlay, and avoids guessing destructive repairs.
6. On finalization, Epos inserts only the final suffix not already inserted, provided the final canonical text still extends the inserted canonical prefix.
7. If final canonical text does not extend the inserted canonical prefix, Epos must not delete or rewrite target text in MVP.
8. Terminals and unknown risky targets use final paste only in MVP.
9. Transcript text is never logged.

## Proposed Design

### Product Behavior

Default fallback path:

- Hold `fn`.
- Epos records and shows partial text in the overlay.
- Release `fn`.
- Epos canonicalizes the final transcript and inserts it through the existing paste backend.

Progressive path:

- Hold `fn` with a supported, guardable text target focused.
- Epos starts a progressive insertion session anchored to that target.
- On each partial, Epos computes a stable safe prefix.
- Epos canonicalizes the safe prefix and inserts only the new canonical delta.
- Epos keeps the volatile tail in the overlay.
- On final, Epos canonicalizes the full final transcript and inserts the remaining suffix if it extends the already-inserted prefix.

### Stability Model

Add a pure `StableTranscriptCommitter` that owns the text policy and has no AppKit, Accessibility, pasteboard, audio, or speech dependencies.

Inputs:

```swift
enum TranscriptSnapshotKind {
    case partial
    case final
}

struct TranscriptSnapshot {
    var text: String
    var kind: TranscriptSnapshotKind
}
```

Outputs:

```swift
struct StableCommitDecision: Equatable {
    var insertDelta: String
    var insertedCanonicalPrefix: String
    var displayTail: String
    var requiresRepair: Bool
}
```

Policy:

- Tokenize on word boundaries while preserving separators.
- For partial snapshots, commit only the longest prefix that:
  - ends on a word boundary,
  - has remained unchanged across a fixed number of consecutive snapshots,
  - leaves a trailing safety window of words uncommitted,
  - does not split a correction alias or the `dash dash <flag>` pattern.
- For final snapshots, consider the whole text safe.
- Canonicalize the safe raw prefix.
- Emit only the suffix beyond `insertedCanonicalPrefix`.
- If the new canonical safe prefix does not start with `insertedCanonicalPrefix`, set `requiresRepair = true` and emit no delta.

Initial conservative constants:

```swift
stablePartialSnapshotCount = 2
trailingSafetyWords = max(4, canonicalizer.maxAliasWordCount + 1)
```

The exact values should live in the committer, not in the coordinator, and be covered by tests.

### Correction Handling

The committer must call the current `TranscriptCanonicalizer` before inserting a stable delta. That keeps existing corrections such as `dash dash`, `/goal`, `$HOME`, and user aliases working for text that has not yet been inserted.

The MVP does not attempt destructive final repair. If final canonicalization would change a previously inserted prefix, Epos reports the mismatch internally as state, stops progressive insertion, and leaves the already-inserted text alone. A later feature can add selected-range repair only for targets that expose reliable Accessibility selection APIs.

### Insertion Architecture

`TextInsertionBackend` now has an optional session capability. The production backend is still `PasteTextInjector`, but it snapshots the clipboard once per dictation session and restores it after the session finishes. `ProgressiveTranscriptInsertionSession` owns the stable-prefix policy and sends exact text deltas to that insertion session.

Synthetic Unicode typing and target-aware guarding remain follow-up work. They should be added only after the stable-prefix policy and session lifecycle stay green.

### Target Guarding

At `fn` press, the progressive backend captures a target token:

- frontmost process identifier,
- focused Accessibility element when available,
- target role/subrole when available,
- selected range or focused value metadata when available.

Before each progressive delta and final suffix insertion, the backend verifies that the same target is still focused. If the guard fails before any text was inserted, the coordinator disables progressive insertion for the session and falls back to final paste. If the guard fails after text was inserted, the coordinator stops progressive insertion and does not paste the full final text over a potentially different target.

### Risk Gating

Progressive insertion is disabled for risky targets in MVP:

- Terminal, iTerm2, Warp, and other terminal bundle identifiers.
- Secure input contexts when detectable.
- Targets that cannot provide enough Accessibility information to establish a guard.
- Any app-specific denylist added through runtime config, not hardcoded machine paths.

## Interface Contracts

### Coordinator Contract

`AppCoordinator` remains the owner of recording state. It asks for a progressive session on recording start and feeds transcript snapshots to a pure committer:

```swift
func handlePartialTranscript(_ text: String)
func handleFinalTranscriptSegment(_ text: String)
func insertFinalTranscript(_ text: String)
```

Those existing methods can remain the seam, but their behavior changes:

- Partial handling updates `StableTranscriptCommitter`.
- If the committer emits a delta, the coordinator sends it to the progressive insertion session.
- Final insertion either inserts the final suffix through the progressive session or uses `TextInsertionBackend.insert` for full final paste when no progressive text was committed.

### Committable Prefix Contract

The committer is the only component allowed to decide what prefix is safe to insert. Backends only insert exact text deltas they are handed.

### Logging Contract

Logs may include character counts, state transitions, backend names, and boolean success/failure. Logs must not include transcript text, inserted deltas, target field contents, selected text, or clipboard contents.

## Acceptance Criteria

- With a supported text field focused, partial snapshots that stabilize across updates insert word-boundary text deltas before `fn` release.
- The overlay still shows the current volatile tail.
- Normal keyboard shortcuts continue to work because the system input source is unchanged.
- If the target app is a terminal, Epos does not stream live deltas and falls back to final paste.
- If the target changes before any progressive delta, Epos falls back to final paste.
- If the target changes after a progressive delta, Epos stops further insertion and does not paste the full final transcript into another target.
- Existing final paste behavior remains available and tested.
- No transcript text appears in diagnostic logs.

## Verification Commands

```sh
swift build -Xswiftc -warnings-as-errors
swift test
swiftlint --quiet
scripts/build-local-app.sh
```

Manual smoke for progressive mode:

```sh
scripts/install-local-app.sh
open /Applications/Epos.app
```

Then focus TextEdit or a browser text field, hold `fn`, speak a sentence slowly, and verify that stable words appear before release while the newest unstable words remain in the overlay. Repeat in Terminal and verify Epos uses final paste only.

## Implementation Slices

### Slice 1: Pure Stable Prefix Committer

- Slice ID: progressive-1
- Title: Pure stable prefix committer
- Goal: Add a deterministic component that converts transcript snapshots into safe insert deltas.
- Behavior under test: unchanged words across partial snapshots become insertable only after the stability threshold and trailing safety window.
- Seam under test: public `StableTranscriptCommitter.accept(_:)`.
- Boundary: pure Foundation type.
- Files likely touched: `Sources/Epos/Inject/StableTranscriptCommitter.swift`, `Tests/EposTests/SmokeTests.swift`.
- Red test name: `testStableCommitterWaitsForRepeatedPartialBeforeEmittingDelta`.
- Fixture / harness: fixed transcript snapshot sequence and default canonicalizer.
- Isolation rule: no AppKit, no Accessibility, no pasteboard, no audio, no speech engine.
- Determinism rule: event-count based stability only; no wall clock.
- Assertion contract: emitted deltas exactly match expected stable word prefixes and display tails.
- Green condition: committer emits no delta for first volatile partial, then emits the first stable word-boundary delta after repeated partials.
- Refactor target: keep tokenization and prefix state private to the committer.
- Smoke budget: none.
- Verification command: `swift test`

### Slice 2: Canonicalized Streaming Prefixes

- Slice ID: progressive-2
- Title: Canonicalized streaming prefixes
- Goal: Ensure progressive deltas preserve deterministic correction behavior before insertion.
- Behavior under test: aliases and developer-token shorthands are canonicalized before the delta is emitted, while unsafe trailing alias windows remain uncommitted.
- Seam under test: `StableTranscriptCommitter.accept(_:)` with custom `TranscriptCanonicalizer`.
- Boundary: pure Foundation type plus existing canonicalizer.
- Files likely touched: `Sources/Epos/Inject/StableTranscriptCommitter.swift`, `Sources/Epos/Speech/TranscriptCanonicalizer.swift`, `Tests/EposTests/SmokeTests.swift`.
- Red test name: `testStableCommitterLeavesAliasWindowUncommittedUntilSafe`.
- Fixture / harness: snapshots containing `dash dash verbose`, `slash goal`, and a custom multi-word alias.
- Isolation rule: no app launch or shared defaults; pass canonicalizer explicitly.
- Determinism rule: fixed rules and fixed snapshots.
- Assertion contract: emitted deltas contain canonical text and never split a known alias phrase.
- Green condition: canonicalized deltas match final canonicalizer output for committed prefixes.
- Refactor target: expose only minimal canonicalizer metadata needed for safe trailing window calculation.
- Smoke budget: none.
- Verification command: `swift test`

### Slice 3: Progressive Backend Protocol And Coordinator Wiring

- Slice ID: progressive-3
- Title: Coordinator progressive insertion wiring
- Goal: Let the coordinator use progressive insertion when available without changing fallback behavior.
- Behavior under test: partial snapshots feed the committer and emitted deltas go to a fake progressive session; final fallback still pastes full text when no progressive session exists.
- Seam under test: `AppCoordinator.handlePartialTranscript`, `handleFinalTranscriptSegment`, and `insertFinalTranscript`.
- Boundary: coordinator and insertion protocols.
- Files likely touched: `Sources/Epos/App/AppCoordinator.swift`, `Sources/Epos/Inject/TextInsertionBackend.swift`, `Sources/Epos/Inject/StableTranscriptCommitter.swift`, `Tests/EposTests/SmokeTests.swift`.
- Red test name: `testCoordinatorStreamsStableDeltaWhenProgressiveSessionIsAvailable`.
- Fixture / harness: fake progressive backend, fake final paste backend, synthetic transcript method calls.
- Isolation rule: no real input method, no real Accessibility, no speech engine.
- Determinism rule: synchronous fake backends.
- Assertion contract: progressive backend receives only emitted stable deltas; paste backend receives full final text only when no progressive text was committed.
- Green condition: existing fallback tests remain green and new progressive tests pass.
- Refactor target: keep state transitions readable in `AppCoordinator`; move streaming policy out of it.
- Smoke budget: none.
- Verification command: `swift test`

### Slice 4: Target Guard Abstraction

- Slice ID: progressive-4
- Title: Guard progressive insertion to one focused target
- Goal: Add a small target guard interface so progressive insertion never types into a different field.
- Behavior under test: same target allows deltas; changed target disables progressive insertion.
- Seam under test: `ProgressiveInsertionSession.insertStableText`.
- Boundary: fake target guard and session implementation.
- Files likely touched: `Sources/Epos/Inject/ProgressiveTargetGuard.swift`, `Sources/Epos/Inject/TextInsertionBackend.swift`, `Tests/EposTests/SmokeTests.swift`.
- Red test name: `testProgressiveSessionRejectsDeltaWhenFocusedTargetChanges`.
- Fixture / harness: fake guard returning stable, missing, and changed target states.
- Isolation rule: no real AX calls in unit tests.
- Determinism rule: fake guard responses are preprogrammed.
- Assertion contract: insertion is attempted only while the target guard reports the original target.
- Green condition: changed target prevents further progressive insertion.
- Refactor target: separate target identity from text event emission.
- Smoke budget: none.
- Verification command: `swift test`

### Slice 5: Synthetic Typing Injector Smoke

- Slice ID: progressive-5
- Title: Synthetic typing injector runtime smoke
- Goal: Implement the production progressive delta inserter for supported text fields.
- Behavior under test: a short Unicode text delta is inserted into TextEdit without changing the clipboard.
- Seam under test: `SyntheticTypingInjector.beginProgressiveInsertion`.
- Boundary: production AppKit/ApplicationServices adapter.
- Files likely touched: `Sources/Epos/Inject/SyntheticTypingInjector.swift`, `scripts/smoke-progressive-insertion.sh`, `Tests/EposTests/SmokeTests.swift`.
- Red test name: `testProgressiveSmokeScriptDoesNotSelectEposInputMethod`.
- Fixture / harness: script source assertion in unit tests plus one manual TextEdit smoke.
- Isolation rule: unit tests inspect script and adapter seams only; runtime behavior is covered by one smoke.
- Determinism rule: smoke uses fixed diagnostic text and restores clipboard if it reads it.
- Assertion contract: TextEdit receives the diagnostic text, current input source remains non-Epos, and pasteboard change count is unchanged.
- Green condition: unit tests pass and the manual smoke passes on the installed app.
- Refactor target: keep AX and CGEvent calls behind a narrow adapter.
- Smoke budget: single allowed smoke.
- Verification command: `swift test && scripts/smoke-progressive-insertion.sh`

### Slice 6: Risk Gating And Fallback

- Slice ID: progressive-6
- Title: Risk gating for terminals and unsupported targets
- Goal: Disable progressive insertion where live typing is risky or cannot be guarded.
- Behavior under test: terminal bundle identifiers and missing target identity use final paste only.
- Seam under test: progressive backend target classification.
- Boundary: target policy helper.
- Files likely touched: `Sources/Epos/Inject/ProgressiveTargetPolicy.swift`, `Sources/Epos/Inject/SyntheticTypingInjector.swift`, `Tests/EposTests/SmokeTests.swift`.
- Red test name: `testProgressiveTargetPolicyRejectsTerminalBundleIdentifiers`.
- Fixture / harness: fixed bundle identifiers and fake target metadata.
- Isolation rule: no real running apps in unit tests.
- Determinism rule: static metadata inputs only.
- Assertion contract: risky targets return `.finalPasteOnly`; supported text fields return `.progressiveAllowed`.
- Green condition: terminal and unsupported targets cannot start progressive sessions.
- Refactor target: keep denylist/config policy isolated from coordinator.
- Smoke budget: none.
- Verification command: `swift test`

## Alternatives Considered

- InputMethodKit marked text as default: rejected for the default product because it requires Epos to be selected as the active input source and routes normal keyboard input through Epos.
- Repeated paste of every partial: rejected because it churns the clipboard, disrupts undo history, and requires deleting/replacing unstable text in arbitrary apps.
- Type every partial raw word immediately: rejected because Speech partials revise earlier text and final canonicalization may change text already inserted.
- Do nothing until final paste: retained as fallback, but not sufficient for the desired streaming UX.

## Cross-Cutting Concerns

- Privacy: transcript text is runtime-only and must not be logged.
- Accessibility: progressive typing needs Accessibility permission. Existing permission prompts remain relevant.
- Performance: progressive deltas are short; synthetic typing should be rate-limited by stable commits, not every partial event.
- Undo behavior: inserted stable chunks may create multiple undo units. This is acceptable for MVP and preferable to destructive rewrites.
- International text: the first implementation should use Unicode string keyboard events and unit tests should include at least one non-ASCII smoke fixture at the pure committer layer.

## Rollout & Rollback

- Ship progressive insertion behind an internal setting or runtime feature flag first.
- Default to final paste until the TextEdit/browser smoke is stable.
- Rollback path: construct `AppCoordinator` with no progressive backend and keep `PasteTextInjector` as final insertion.
- Keep `EposInputMethod` out of the default install path or remove it before shipping this behavior as default.

## MVP Decisions

- Use a hidden developer feature flag for the first build. Do not expose this in the menu bar UI until TextEdit and browser text-field smoke tests pass.
- The first dogfood allowlist is TextEdit plus Safari/Chrome browser text fields. Native Notes/Mail can be added after the insertion and target-guard policy has survived the first smoke pass.
