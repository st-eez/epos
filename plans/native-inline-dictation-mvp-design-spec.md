# Native Inline Dictation MVP Design Spec

## Metadata

- Status: draft for implementation
- Date: 2026-05-27
- Owner: Epos
- Related shipped spec: `specs/native-text-insertion.md`

## Context

Epos currently shows live transcript text in its floating recording panel and inserts only final text into the focused app through the paste backend. That is reliable, but it is not native-feeling because the real document does not update while the user speaks.

The native path requires an InputMethodKit input method. The input method can access the active text-input client and use public APIs to set marked text for live partials and commit final text on release.

## Goals

- Make native mode feel like dictation inside the target text field, not dictation inside an Epos preview panel.
- Keep the current paste flow as a fallback for unsupported or inactive native mode.
- Prevent the Epos indicator from covering the text the user is editing.
- Keep the MVP small enough to implement and verify in slices.

## Non-goals

- Cloning Apple Dictation's exact UI.
- Candidate/alternative correction UI.
- Blue ambiguous-word styling.
- New hotkey customization.
- Removing the existing paste backend.
- Supporting every custom editor perfectly in the first release.

## Constraints & Assumptions

- Native insertion only works when the Epos input method is installed and selected.
- Some apps will provide incomplete or stale text geometry.
- Transcript text must not be written to logs.
- The menu bar app owns audio capture and transcription for the MVP.
- The input method owns only text-client calls and active-client geometry.
- If native mode is unavailable or unhealthy, Epos must fall back to today's transcript preview plus paste behavior.

## Requirements

1. In native mode, live dictation text appears inside the focused input box as marked/provisional text.
2. On `fn` release, Epos commits the corrected final transcript into that same input box.
3. In native mode, the floating Epos UI does not show the full transcript.
4. In native mode, the floating Epos UI is a compact recording/status indicator.
5. In fallback mode, the current transcript preview UI remains available because the target field is not updating live.
6. The status indicator avoids covering the caret or marked text when reliable geometry is available.
7. When geometry is unavailable or suspicious, the status indicator falls back to a small bottom-center pill.
8. Paste fallback remains available and keeps current clipboard-restore behavior.

## Proposed Design

### Product Behavior

Native mode:

- Hold `fn` to start recording.
- Epos starts audio capture and transcription.
- Partial transcript updates are sent to the input method as marked text.
- The focused text field shows those words inline.
- The Epos floating UI shrinks to a small status pill: mic state plus waveform.
- Release `fn` to finalize.
- The input method replaces the marked text with the corrected final transcript.
- The status pill disappears.

Fallback mode:

- Hold `fn` to start recording.
- The target app does not update live.
- The existing Epos panel shows live transcript preview.
- Release `fn` to paste the corrected final transcript.
- Clipboard restore behavior stays unchanged.

### UI Decision

Use two recording indicator modes:

```swift
enum RecordingIndicatorDisplayMode {
    case transcriptPreview
    case inlineStatus
}
```

`transcriptPreview` is the current larger panel with live transcript text.

`inlineStatus` is a compact pill. It shows:

- status dot
- live amplitude bars
- optional short state label only for non-obvious states, such as fallback or error

It does not show the transcript. The focused text field is the transcript surface.

### Placement Rules

For MVP, `inlineStatus` uses this placement order:

1. If native geometry is available and sane, place the pill near the caret or marked-text rect with at least 12 pt clearance.
2. Prefer below the caret; flip above when there is not enough room.
3. Nudge horizontally to keep the pill inside the visible screen.
4. If the calculated pill frame intersects the caret or marked text rect, move to the nearest non-overlapping side.
5. If geometry is missing, stale, off-screen, or too small to trust, use a bottom-center mini pill.

The fallback transcript preview keeps today's bottom-center placement.

### Native Insertion Architecture

MVP implementation keeps `TextInsertionBackend` as the app-facing boundary.

Expected concrete backends:

- `PasteTextInjector`: current fallback behavior.
- `NativeTextInsertionClient`: sends final and partial text operations to the active Epos input method.

The input method side owns calls to:

- `setMarkedText` for partial updates.
- `insertText` for final commit.
- `unmarkText` for cancel or failure.

The menu bar app owns audio capture, transcription, correction, hotkey handling, and settings. It cannot directly call text-input client APIs. It communicates with the input method through a local private app-to-input-method channel.

The input method owns:

- active text-input client access
- marked text updates
- final text commits
- caret or marked-text geometry

For MVP, use a local Unix domain socket resolved from the user's home/cache location at runtime, not a hardcoded absolute path. The input method hosts the listener while active; the menu bar app connects to it for native health checks, partial updates, cancel, and final commit.

The local channel carries transcript text at runtime only. It must not log payloads, persist payloads, or expose payloads outside the user's session.

## Interface Contracts

### App-side insertion protocol

```swift
protocol TextInsertionBackend {
    func insert(_ text: String)
}
```

For inline streaming, add a separate optional capability rather than forcing paste fallback to fake partials:

```swift
protocol LiveTextInsertionBackend: TextInsertionBackend {
    var supportsMarkedText: Bool { get }
    func updateMarkedText(_ text: String)
    func cancelMarkedText()
}
```

`PasteTextInjector.supportsMarkedText` is false by omission; it never streams partials.

### Indicator mode source

The coordinator exposes the display mode:

```swift
@Published private(set) var recordingDisplayMode: RecordingIndicatorDisplayMode
```

Mode selection:

- Native backend healthy and selected: `.inlineStatus`
- Native backend unavailable or failed: `.transcriptPreview`

## Acceptance Criteria

- With the Epos input method active in TextEdit, partial dictation appears inline as marked text.
- Releasing `fn` commits corrected final text in place without touching the pasteboard.
- During native inline dictation, the floating UI is compact and does not show the transcript.
- If caret geometry is unavailable, the compact indicator appears bottom-center and does not cover the text line.
- With native mode unavailable, Epos keeps today's live preview panel and paste insertion.
- No transcript text appears in diagnostic logs.

## Verification Commands

```sh
swift build -Xswiftc -warnings-as-errors
swift test
swiftlint --quiet
scripts/build-local-app.sh
```

Manual smoke for native mode:

```sh
scripts/install-local-app.sh
open /Applications/Epos.app
```

Then select the Epos input method, focus TextEdit, hold `fn`, dictate a short sentence, release `fn`, and confirm inline marked text commits without changing the pasteboard.

## Implementation Slices

### Slice 1: Indicator Display Modes

- Goal: Add `RecordingIndicatorDisplayMode` and render a compact `inlineStatus` variant.
- Behavior under test: transcript preview shows transcript; inline status omits transcript and keeps stable compact dimensions.
- Boundary: `RecordingIndicatorSurface`.
- Files likely touched: `Sources/Epos/UI/RecordingIndicator.swift`, `Tests/EposTests/SmokeTests.swift`.
- Red test name: `testInlineStatusIndicatorOmitsTranscript`.
- Fixture / harness: instantiate `RecordingIndicatorSurface`-level helpers and inspect derived display properties.
- Isolation rule: no app launch, no input method, no global state.
- Determinism rule: fixed state, transcript, and amplitude.
- Assertion contract: inline mode returns no transcript text and compact layout constants remain bounded.
- Green condition: tests pass and current transcript preview tests remain green.
- Smoke budget: none.
- Verification command: `swift test`.

### Slice 2: Indicator Placement Policy

- Goal: Extract a pure placement policy for compact native indicator positioning.
- Behavior under test: sane caret rect places nearby; overlap flips/nudges; missing geometry falls back bottom-center.
- Boundary: pure placement helper.
- Files likely touched: `Sources/Epos/UI/RecordingIndicatorController.swift`, `Tests/EposTests/SmokeTests.swift`.
- Red test name: `testInlineIndicatorFallsBackWhenCaretRectIsUnavailable`.
- Fixture / harness: fixed screen rect, pill size, caret rect options.
- Isolation rule: no `NSScreen`, no `NSPanel` in tests.
- Determinism rule: pure geometry inputs only.
- Assertion contract: returned frame is on screen and does not intersect protected caret rect when possible.
- Green condition: placement helper covers cursor-adjacent and fallback cases.
- Smoke budget: none.
- Verification command: `swift test`.

### Slice 3: Input Method Commit Spike

- Goal: Prove an Epos input method can commit a fixed diagnostic string into the active text client.
- Behavior under test: selected input method can call `insertText` without changing pasteboard.
- Boundary: new `EposInputMethod` target.
- Files likely touched: `project.yml`, `Sources/EposInputMethod/*`, install script or new helper script.
- Red test name: `testInputMethodBundleDeclaresServerAndController`.
- Fixture / harness: generated input-method bundle metadata plus TextEdit manual smoke.
- Isolation rule: no transcript pipeline, no audio capture.
- Determinism rule: fixed diagnostic string only.
- Assertion contract: text appears in TextEdit; pasteboard change count is unchanged.
- Green condition: installed input method commits fixed text.
- Smoke budget: single allowed smoke.
- Verification command: `scripts/build-local-app.sh` plus manual TextEdit smoke.

### Slice 4: Native Final Insertion Backend

- Goal: Route final transcript through native insertion when the input method is active; otherwise paste fallback.
- Behavior under test: coordinator chooses native backend when healthy, paste backend when unavailable.
- Boundary: `TextInsertionBackend` selection and backend health check.
- Files likely touched: `Sources/Epos/Inject/*`, `Sources/Epos/App/AppCoordinator.swift`, tests.
- Red test name: `testCoordinatorUsesPasteFallbackWhenNativeInsertionUnavailable`.
- Fixture / harness: fake native backend and fake paste backend.
- Isolation rule: no real input method in unit tests.
- Determinism rule: synchronous fake backend calls.
- Assertion contract: final text is sent exactly once to the selected backend.
- Green condition: unit tests cover native and fallback selection.
- Smoke budget: none.
- Verification command: `swift test`.

### Slice 5: Inline Marked Text Streaming

- Goal: Send partials to native marked text and commit final corrected text on release.
- Behavior under test: partial events call `updateMarkedText`; finalization calls `insert`; cancellation calls `cancelMarkedText`.
- Boundary: `LiveTextInsertionBackend`.
- Files likely touched: `Sources/Epos/App/AppCoordinator.swift`, `Sources/Epos/Inject/*`, tests.
- Red test name: `testNativeBackendReceivesPartialMarkedTextBeforeFinalCommit`.
- Fixture / harness: fake live backend recording method calls.
- Isolation rule: no speech engine, no real input method.
- Determinism rule: synthetic transcript events.
- Assertion contract: partials stream only when `supportsMarkedText`; paste backend never receives partials.
- Green condition: inline native mode streams marked text and fallback mode preserves current preview-only behavior.
- Smoke budget: none.
- Verification command: `swift test`.

## Alternatives Considered

- Keep the full transcript in the Epos floating UI for native mode: rejected as the primary UX because it duplicates the real text and competes with the input field.
- Stream partials through repeated paste: rejected because it risks corrupting selection, rich text state, undo history, and user typing.
- Cursor-adjacent UI only, no fallback placement: rejected because custom editors may provide bad geometry.

## Rollout & Rollback

- Ship native mode behind an internal backend health check first.
- Keep paste fallback as the default until the input method is verified across TextEdit, Safari/Chrome text fields, and one Electron/editor field.
- Rollback path is to disable native backend selection and keep `PasteTextInjector`.

## MVP Decisions

- Audio capture and transcription stay in the menu bar app for MVP.
- The input method stays narrow: client access, marked text, final commit, and geometry.
- The app-to-input-method channel is a local Unix domain socket resolved from user-local runtime paths, with transcript payloads never logged or persisted.
- The compact indicator supports cursor-adjacent placement when geometry is sane and uses bottom-center mini-pill fallback otherwise.
