# SteezFlow — Baseline Spec

Date: 2026-05-22 · Revised: 2026-05-26 (added "Shipped Since Baseline"; see that section)

A clean-sheet rebuild of SteezFlow as a minimal dictation app on top of Apple's `SpeechTranscriber` (macOS 26+). No WhisperKit, no MLX, no LLM polish, no filler detector. Those become post-baseline candidates, not baseline requirements. A deterministic, user-editable correction layer has since shipped on top of this baseline — see "Shipped Since Baseline".

## Product

Hold fn → record → see indicator with live partial text → release → final transcript pastes into the frontmost app. That is the whole product.

## Constraints

- macOS 26.0+ only. The baseline drops every earlier OS; `SpeechTranscriber` is the entire reason for the rebuild.
- Apple Silicon only.
- On-device. No network at runtime except the one-time `SpeechTranscriber` locale asset download via `AssetInventory`.
- Single locale per install (start with `en-US`); locale switching is a post-baseline concern.
- Target footprint: under ~50 MB resident while idle, under ~100 MB while transcribing. Bakeoff measured `SpeechTranscriber` at ~27 MB RSS.
- Keep modules under ~250 LOC each (see `CLAUDE.md`) rather than policing one global budget. The core dictation path held to the original ~2,000 LOC target; the correction layer, opt-in audio capture, and diagnostic sink shipped on top of it (see "Shipped Since Baseline"), so the whole app now runs larger. Cut scope at the module level.

## Non-Goals (baseline)

Explicitly out of scope. Each is a candidate for a later, opt-in module:

- LLM grammar polish (MLX/Qwen3 etc.)
- Filler-word detection
- Persistent transcription history
- Multiple model choices in settings
- Multi-locale switching UI
- Onboarding wizard beyond a single permissions screen
- Push-to-talk *and* toggle modes — baseline ships push-to-talk only
- Agent-specific modes (Codex prompt, Cursor chat, etc.)
- Cloud transcription fallback

## Shipped Since Baseline

Built and validated after the original baseline and promoted from the backlog. Listed here so the source of truth matches the code — these are part of the app, not aspirational.

- **Correction layer** (`Speech/TranscriptCanonicalizer.swift`, `UI/CorrectionsEditorView.swift`, `CorrectionDraft.swift`, `CorrectionDraftRow.swift`). Deterministic spoken→canonical rewriting applied to the final transcript before paste: user-editable alias→canonical rules with optional context guards, plus built-in developer-token normalization (`dash dash` → `--`, `slash goal` → `/goal`, `dollar home` → `$HOME`). Backlog #1 + #4. Rules persist under their own `UserDefaults` key and are edited in a dedicated Corrections window. Exposed rules only — not grammar or style rewriting.
- **Opt-in audio sample capture** (`Audio/DogfoodTap.swift`). Per-recording `.wav` capture to the app cache as local eval material. Off by default, gated by `Settings.saveAudioSamples`; recordings that produced no transcript are discarded.
- **On-disk diagnostic log** (`Diagnostics/SteezFlowLogger.swift` → `DiagnosticLogSink`). Mirrors `os.Logger` events to a size-capped, rotated app-owned log under `~/Library/Caches/SteezFlow/logs/` (writes direct events instead of polling the unified-log store). Privacy-aware: no transcript text. Disable with `STEEZFLOW_DIAGNOSTIC_LOGS=0`.

## Architecture

Flat layout, one test target, no subsystem folders beyond what's listed. The core dictation path is below; the correction layer, opt-in capture, and diagnostic sink (see "Shipped Since Baseline") extend it.

```
Sources/SteezFlow/
  App/
    SteezFlowApp.swift          # @main, scenes, dependency wiring
    AppCoordinator.swift        # state machine: idle <-> recording <-> finalizing
  Permissions/
    PermissionsGate.swift       # mic + speech + accessibility, request + status
  Speech/
    AssetManager.swift          # SpeechTranscriber locale asset reserve + download
    Transcriber.swift           # SpeechAnalyzer + SpeechTranscriber wrapper
    TranscriptCanonicalizer.swift  # deterministic spoken->canonical correction rules (Shipped Since Baseline)
  Audio/
    AudioCapture.swift          # AVAudioEngine input tap -> AnalyzerInput stream
    DogfoodTap.swift            # opt-in per-recording .wav capture (Shipped Since Baseline)
  Hotkey/
    FnHotkey.swift              # NSEvent global monitor for fn press/release
  UI/
    RecordingIndicator.swift    # floating window: waveform + live partial text
    MenuBarView.swift           # MenuBarExtra: status, quit, open permissions
    CorrectionsEditorView.swift # correction-rule editor window (+ CorrectionDraft, CorrectionDraftRow)
  Inject/
    TextInjector.swift          # paste via NSPasteboard + CGEvent cmd-v, restore clipboard
  Diagnostics/
    SteezFlowLogger.swift       # os.Logger + on-disk DiagnosticLogSink (Shipped Since Baseline)
```

No `Core/`, no `Utilities/`, no `Models/` folder of empty types. (Settings, the indicator controller, and small view styles also live under `App/` and `UI/`; the tree above lists the load-bearing modules.)

### Data flow

```
FnHotkey.press
  -> AppCoordinator.startRecording
     -> AudioCapture.start (16 kHz mono Float32 buffers)
     -> Transcriber.start (SpeechAnalyzer + SpeechTranscriber module)
     -> RecordingIndicator.show
  // streams partial transcripts -> RecordingIndicator
FnHotkey.release
  -> AppCoordinator.finishRecording
     -> AudioCapture.stop
     -> Transcriber.finalize -> String
     -> RecordingIndicator.hide
     -> TranscriptCanonicalizer.canonicalize(finalText)   # correction layer, Shipped Since Baseline
     -> TextInjector.paste(corrected) into frontmost app
```

### Coordinator state

Three states, nothing more:

- `idle`
- `recording` (audio + transcription streaming, indicator visible)
- `finalizing` (input stopped, awaiting final result, then paste)

No retry loop, no circuit breaker, no error recovery state. Errors log + reset to `idle` + brief indicator flash. The v1 `RecordingStateMachine` (`Sources/SteezFlow/Core/StateMachine/`) is intentionally not ported — its surface is larger than the baseline needs.

## Key Technical Decisions

### Apple Speech: `SpeechAnalyzer` + `SpeechTranscriber` module

Use the new (macOS 26) `SpeechAnalyzer` pipeline with a `SpeechTranscriber` module — *not* the legacy `SFSpeechRecognizer` and *not* `DictationTranscriber`. The bakeoff has already justified this (`specs/local-transcription-direction.md:82`).

Lifecycle:

1. First launch: `PermissionsGate` requests mic + speech recognition + accessibility.
2. `AssetManager` checks `AssetInventory` for the install locale; if missing, downloads and reserves. Reservation is process-scoped, so reserve on every app launch.
3. Per recording: build a fresh `SpeechAnalyzer` with one `SpeechTranscriber` module configured for the install locale, partial results on. Feed `AnalyzerInput` from the audio tap. Read `Result` stream for partial + final.

### Hotkey: fn-only, push-to-talk

Default and only binding in the baseline: hold fn to record, release to finalize.

Implementation: `NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged)`, watch `event.modifierFlags.contains(.function)`. Pattern already proven in `Sources/SteezFlow/Hotkey/HotkeyManager.swift:184` — port that single function, drop the rest of `HotkeyManager`.

Known collision: macOS system dictation also defaults to fn (single-press or double-press depending on user setting). The baseline does not try to suppress system dictation and does not detect it in-app. The install instructions tell the user to set System Settings → Keyboard → Dictation → Shortcut to "Off". No in-app remapping UI and no first-run detection in the baseline. (Primary developer machine: already disabled.)

### Audio capture

`AVAudioEngine` input node tap at native input format, converted to 16 kHz mono Float32 with `AVAudioConverter` for the analyzer input. No device hot-swap handling in baseline — if the user changes input device mid-recording, the recording ends. Hot-swap handling (`AudioDeviceManager` in v1) is a post-baseline add.

### Recording indicator

A single `NSPanel` (borderless, non-activating, floats above all) with:

- Live amplitude bar from the audio tap (RMS over a small window).
- Latest transcript preview, up to five lines, rolling from the front so newest text stays visible.
- Subtle "recording" affordance (color, not text).

No frontmost-app icon, no waveform history, no draggable position in baseline. Centered above the active screen's bottom edge, fixed.

### Text injection

`NSPasteboard` write → synthesize `cmd+v` via `CGEvent` → restore previous clipboard contents after a short delay. Same approach as v1 `TextInjector` but stripped of paste-strategy abstraction. Requires Accessibility permission.

### Concurrency

- Audio capture on its dedicated `AVAudioEngine` thread.
- Transcription stream consumed on a `Task` owned by `AppCoordinator`.
- UI updates marshaled to the main actor.
- No custom queues, no `OperationQueue`, no actor sprawl. `AppCoordinator` is `@MainActor`.

### Logging

`os.Logger` for unified logging — one subsystem (`com.steez.SteezFlow`), categories per module — mirrored to an app-owned, size-capped, rotated on-disk `DiagnosticLogSink` (see "Shipped Since Baseline"; it writes direct events to disk instead of polling the unified-log store). No ring buffer, no `StateHistory`.

### Settings

A single `UserDefaults`-backed struct: launch-at-login bool, install locale string, and a `saveAudioSamples` bool (opt-in audio capture). Surfaced in the menu bar popover. Correction rules persist separately under their own `UserDefaults` key and are edited in the Corrections window.

## Build & Project Layout

- Swift Package + a thin Xcode app target (same shape as v1) so we can sign + entitle + bundle.
- Entitlements: microphone, speech recognition, accessibility, hardened runtime. No sandbox in the baseline (paste injection wants accessibility, and there is no App Store target).
- One scheme: `SteezFlowMacApp`. One test scheme: `SteezFlowTests`.
- Lint: `swiftlint` with the v1 config copied verbatim.

## Testing

Test what would silently break, skip the rest.

- `AssetManager`: status reporting (`missing`, `downloading`, `ready`, `reserved`) — mock `AssetInventory`.
- `Transcriber`: feeds a known-good wav, asserts a non-empty final string — integration test, only runs when locale asset is installed (`XCTSkipIf`).
- `AppCoordinator`: state transitions on synthetic hotkey events with a fake transcriber + fake injector.
- `TextInjector`: clipboard save/restore round-trip.
- Hotkey, audio capture, indicator UI: not unit tested; verified by running the app.

Target: < 30 tests total. If we cross that, we are testing implementation, not behavior.

## Repository

This repo is the greenfield rebuild of SteezFlow. The prior implementation lives at `~/Projects/Personal/steezflow` (99 Swift files, 28 specs, 16.7K LOC) and stays on disk as reference only — not a dependency, not a submodule, not something this repo imports from. The only v1 code worth porting verbatim is the fn-key monitor and the paste injector, both small enough to retype. v1 remains available until this rebuild is daily-driver stable.

## Acceptance — Baseline Done

All of:

- Holding fn while a text field is focused produces the spoken text in that field on release, end-to-end, in under 500 ms after release for a 10-second utterance.
- Indicator appears within 100 ms of fn press and disappears within 100 ms of release.
- Idle RSS under 50 MB after 5 minutes; transcribing RSS under 100 MB.
- Cold launch to "ready for first recording" under 2 seconds (excluding first-run asset download).
- App quits cleanly with no leaked audio engine or analyzer.
- Survives 50 consecutive recordings without restart.

Anything beyond this list is post-baseline.

## Backlog (post-baseline)

Tracked here so we do not lose them, in rough priority order:

1. ~~Deterministic developer-token rewriter (`"dash dash"` → `--`, `"dot env"` → `.env`).~~ **Shipped** as the correction layer (see "Shipped Since Baseline"). camelCase-identifier handling is still open.
2. Toggle/hands-free recording mode alongside push-to-talk.
3. Persistent transcription history (in-memory first, opt-in disk later).
4. ~~Personal dictionary with spoken→corrected mappings.~~ **Shipped** as user-editable correction rules (see "Shipped Since Baseline").
5. Locale switching UI + multi-asset management.
6. LLM polish (local MLX) as opt-in per-recording.
7. Filler-word detection.
8. Audio device hot-swap handling.
9. Agent-specific modes (Codex / Claude Code / Cursor).
10. Custom hotkey binding UI.

Each is a separate spec when its turn comes. None block the baseline.
