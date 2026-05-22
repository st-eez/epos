# SteezFlow — Baseline Spec

Date: 2026-05-22

A clean-sheet rebuild of SteezFlow as a minimal dictation app on top of Apple's `SpeechTranscriber` (macOS 26+). No WhisperKit, no MLX, no personal dictionary, no LLM polish, no filler detector. Those become post-baseline candidates, not baseline requirements.

## Product

Hold fn → record → see indicator with live partial text → release → final transcript pastes into the frontmost app. That is the whole product.

## Constraints

- macOS 26.0+ only. The baseline drops every earlier OS; `SpeechTranscriber` is the entire reason for the rebuild.
- Apple Silicon only.
- On-device. No network at runtime except the one-time `SpeechTranscriber` locale asset download via `AssetInventory`.
- Single locale per install (start with `en-US`); locale switching is a post-baseline concern.
- Target footprint: under ~50 MB resident while idle, under ~100 MB while transcribing. Bakeoff measured `SpeechTranscriber` at ~27 MB RSS.
- ~2,000 LOC ceiling for the baseline. If a module pushes past that, cut scope, do not grow the budget.

## Non-Goals (baseline)

Explicitly out of scope. Each is a candidate for a later, opt-in module:

- Personal dictionary / custom vocabulary
- LLM grammar polish (MLX/Qwen3 etc.)
- Filler-word detection
- Persistent transcription history
- Multiple model choices in settings
- Multi-locale switching UI
- Onboarding wizard beyond a single permissions screen
- Push-to-talk *and* toggle modes — baseline ships push-to-talk only
- Agent-specific modes (Codex prompt, Cursor chat, etc.)
- Cloud transcription fallback
- Deterministic developer-token rewriter (`"dash dash"` → `--`). The bakeoff shows we'll want this back eventually; baseline ships without it and we re-add as the first post-baseline feature once we have failure data from real use.

## Architecture

Ten source modules, one test target. Flat layout, no subsystem folders beyond what's listed.

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
  Audio/
    AudioCapture.swift          # AVAudioEngine input tap -> AnalyzerInput stream
  Hotkey/
    FnHotkey.swift              # NSEvent global monitor for fn press/release
  UI/
    RecordingIndicator.swift    # floating window: waveform + live partial text
    MenuBarView.swift           # MenuBarExtra: status, quit, open permissions
  Inject/
    TextInjector.swift          # paste via NSPasteboard + CGEvent cmd-v, restore clipboard
```

That is the whole tree. No `Core/`, no `Utilities/`, no `Models/` folder of empty types.

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
     -> TextInjector.paste(finalText) into frontmost app
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
- Latest partial transcript text, single line, truncated.
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

`os.Logger` only. One subsystem (`com.steez.SteezFlow`), categories per module. No ring buffer, no `StateHistory`, no on-disk log files in baseline.

### Settings

A single `UserDefaults`-backed struct with at most: launch-at-login bool, install locale string. Surfaced in the menu bar popover, no separate Settings window.

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

1. Deterministic developer-token rewriter (`"dash dash"` → `--`, `"dot env"` → `.env`, camelCase identifiers). First thing to re-add after baseline ships, based on real failure samples.
2. Toggle/hands-free recording mode alongside push-to-talk.
3. Persistent transcription history (in-memory first, opt-in disk later).
4. Personal dictionary with spoken→corrected mappings.
5. Locale switching UI + multi-asset management.
6. LLM polish (local MLX) as opt-in per-recording.
7. Filler-word detection.
8. Audio device hot-swap handling.
9. Agent-specific modes (Codex / Claude Code / Cursor).
10. Custom hotkey binding UI.

Each is a separate spec when its turn comes. None block the baseline.
