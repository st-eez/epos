# Epos — Baseline Spec

Date: 2026-05-22 · Revised: 2026-06-03 (eval-only raw relaxed Ollama candidate logging added; eval-only relaxed Ollama shadow prompt added for dogfooding; local Ollama polish engine added behind environment config; 2026-05-29 opt-in on-device LLM polish stage added; 2026-05-28 live self-correcting keystroke insertion reconciles on every partial for lowest latency, recording HUD slimmed to a pill; see "Shipped Since Baseline")

A clean-sheet rebuild of Epos as a minimal dictation app on top of Apple's `SpeechTranscriber` (macOS 26+). No WhisperKit, no MLX, no filler detector. Those were post-baseline candidates, not baseline requirements. A deterministic, user-editable correction layer and an opt-in on-device LLM polish stage have since shipped on top of this baseline — see "Shipped Since Baseline".

## Product

Hold fn → record → words stream live into the frontmost app as you speak, self-correcting when the recognizer revises a word → release → the field holds the final transcript. A small recording pill shows listening state; the text itself lives in the focused field. That is the whole product.

## Constraints

- macOS 26.0+ only. The baseline drops every earlier OS; `SpeechTranscriber` is the entire reason for the rebuild.
- Apple Silicon only.
- On-device. No network at runtime except the one-time `SpeechTranscriber` locale asset download via `AssetInventory`.
- Single locale per install (start with `en-US`); locale switching is a post-baseline concern.
- Target footprint: under ~50 MB resident while idle, under ~100 MB while transcribing. Bakeoff measured `SpeechTranscriber` at ~27 MB RSS.
- Keep modules under ~250 LOC each (see `CLAUDE.md`) rather than policing one global budget. The core dictation path held to the original ~2,000 LOC target; the correction layer, opt-in audio capture, and diagnostic sink shipped on top of it (see "Shipped Since Baseline"), so the whole app now runs larger. Cut scope at the module level.

## Non-Goals (baseline)

Explicitly out of scope. Each is a candidate for a later, opt-in module:

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

- **Correction layer** (`Speech/TranscriptCanonicalizer.swift`, `UI/CorrectionsEditorView.swift`, `CorrectionDraft.swift`, `CorrectionDraftRow.swift`). Deterministic spoken→canonical rewriting applied to the transcript before it is typed (both streamed partials and finals): user-editable alias→canonical rules with optional context guards, plus built-in developer-token normalization (`dash dash` → `--`, `slash goal` → `/goal`, `dollar home` → `$HOME`). Backlog #1 + #4. Rules persist under their own `UserDefaults` key and are edited in a dedicated Corrections window. Exposed rules only — not grammar or style rewriting.
- **Opt-in audio sample capture** (`Audio/DogfoodTap.swift`). Per-recording `.wav` capture to the app cache as local eval material. Off by default, gated by `Settings.saveAudioSamples`; recordings that produced no transcript are discarded.
- **On-disk diagnostic log** (`Diagnostics/EposLogger.swift` → `DiagnosticLogSink`). Mirrors `os.Logger` events to a size-capped, rotated app-owned log under `~/Library/Caches/Epos/logs/` (writes direct events instead of polling the unified-log store). This is a local dogfood/debug surface and may include transcript text where needed to evaluate recognition and polish behavior, including transcript timing text and rejected polish candidates. Disable with `EPOS_DIAGNOSTIC_LOGS=0`.
- **Target-aware insertion guards** (`Inject/InsertionTargetGuard.swift`, wired into `Inject/ProgressiveTranscriptInsertion.swift`). Backlog #11. Stops the self-correcting backspace from ever deleting characters that aren't ours when the on-screen field stops matching the session's private model — focus moving mid-recording, or the field mutating text on its own (autocorrect, autocomplete/suggestions in search boxes and iMessage, IntelliSense bracket/indent insertion). At session start the session captures the focused Accessibility element as "home" (`kAXFocusedUIElementAttribute` off the system-wide element). Two checks, by cost: a cheap focus-identity comparison (`CFEqual` of the current focused element vs home) runs on every reconcile; the expensive full-value read (`kAXValueAttribute`) is gated to the pre-delete moment only — an append lands at the caret and corrupts nothing, so only a backspace pays for the read, which keeps the recognizer's ~1.2s/1s cadence the floor with no added throttle. The guard *decision* is a pure function (`InsertionTargetGuard.decide`, unit-tested) over `(expected committedText, observation)`: focus changed → **abort** (cancel the session in place, no cleanup backspacing — that would itself be the corruption); on-screen value no longer ends with what we believe we typed (`!observed.hasSuffix(committedText)`, conservative so a field-inserted trailing char falls back safely) → **stop and append-only**; otherwise proceed. Both terminal states latch: once aborted or in append-only, the session never backspaces again, because `committedText` no longer models the screen. The append-only fallback types only the new tail past the last commit — it can't corrupt existing text and does not reintroduce clipboard paste. AX I/O is bounded with `AXUIElementSetMessagingTimeout` so a wedged accessibility server can't stall the main-actor reconcile. The Accessibility reads themselves aren't headlessly testable (they need the installed signed app dictating into real apps); only the pure decision and the session's latch behavior under a fake observer are unit-tested.
- **Opt-in polish** (`Speech/TranscriptPolisher.swift`, `Speech/TranscriptDeterministicCleaner.swift`, `Speech/FoundationModelsPolishEngine.swift`, `Speech/OllamaPolishEngine.swift`, `Speech/OllamaPolishPrompt.swift`, `Speech/OllamaHTTPPolishClient.swift`, `Speech/PolishEngineFactory.swift`; wired in `App/AppCoordinator.swift`, toggled in `UI/MenuBarView.swift`). Backlog #6. When `Settings.polishEnabled` is on, a deterministic hard-filler cleanup removes only guard-proven disfluencies (`um`, `uh`, `er`, `hmm`, plus comma-delimited opening `so`/`like`) and deliberately preserves ambiguous phrases such as "you know" and bare `so`/`like`. The default polish engine remains FoundationModels guided generation (`SystemLanguageModel` + `respond(to:generating:)` filling a single `@Generable` field, greedy/temperature-0, the Stage-1 tuned prompt), which may lightly fix capitalization/spacing without changing meaning. For local-model dogfooding, `EPOS_POLISH_ENGINE=ollama` switches the same `PolishEngine` seam to Ollama, defaulting to `qwen3:1.7b` and honoring `EPOS_OLLAMA_MODEL`; production Ollama uses the conservative Qwen prompt and the same guard/fallback policy, including rejection when a candidate removes an existing final period, while evals can select strict/conservative/relaxed prompt styles and can run an opt-in relaxed Qwen prompt in shadow mode (`EPOS_EVAL_SHADOW_RELAXED_OLLAMA=1`) to record the raw candidate, canonicalized candidate, strict guard decision, and strict-gate output in JSONL without changing inserted output. A text-only raw candidate eval (`EPOS_RUN_OLLAMA_RAW_CANDIDATE_EVAL=1`) bypasses `TranscriptPolisher` entirely and applies canonicalization plus the strict guard only as diagnostics, so model capability can be separated from pipeline suppression. The real polish request uses `keep_alive: 0` so the model unloads after finalization, while per-recording prewarm may keep it warm briefly to reduce finalize latency. Spoken-symbol conversion (e.g. "dash dash" → "--") is *not* a polish concern: the prompt tells the model to leave such words alone and the guard treats them as content, so it is owned solely by `TranscriptCanonicalizer`, which runs on both the raw and polished text. The cleaned result feeds the existing `acceptFinalTranscript` reconcile, so it erases-and-retypes the live raw dictation to the cleaned text and the deterministic canonicalizer still runs downstream as the authoritative jargon fix — no new insertion mechanism. Default **off**; when off the path is the raw transcript byte-for-byte after canonicalization. **Always-safe fallback**: any model failure, unavailability, throw, timeout, or content-retention guard rejection falls back to deterministic cleanup when it changed only guard-proven fillers, otherwise to the raw transcript, so the user never loses their words. The guard is the defense against the model over-compressing, reordering, or adding content — after allowed filler removal, the polished content-token sequence must match the raw content-token sequence exactly. Polish runs once on the final transcript (not streamed during recording); the per-recording polisher snapshots the current toggle and correction vocabulary at `startRecording`, the engine is prewarmed with that same vocabulary, and because the polish `await` happens while `state == .finalizing` (before `resetToIdle()`), the recording indicator stays visible through the polish window. The gate/guard/fallback policy is unit-tested behind a `PolishEngine` seam with fakes; live model calls and the live erase-and-retype need the installed signed app plus the selected local engine. Stage 1 (offline probe, `specs/llm-polish-probe.md`) established that guided generation is the only viable FoundationModels mechanism — plain instruction-only prompting composes, refuses, and blows the context window.
- **Live self-correcting insertion** (`Inject/ProgressiveTranscriptInsertion.swift`, `Inject/TextInsertionBackend.swift`). During recording Epos types the canonicalized transcript straight into the focused field via synthesized Unicode keystrokes (`KeystrokeTextInjector`, `CGEventKeyboardSetUnicodeString`) — each delta in its own ordered keyboard event, no clipboard. Every update — volatile partial and authoritative per-segment final alike — reconciles with a minimal edit: it backspaces the suffix that diverges from the new target and retypes the corrected remainder, so the freshest words appear with the lowest latency the recognizer allows and a revision corrects the field in place. This replaced the original clipboard-paste backend, whose streamed `cmd+v` raced garbled output; the never-rewrite policy, which stranded mis-recognized words and dropped the corrected tail; and the append-only-partials policy, which held the newest words back by ~1 confirmation cycle (measured ~1s of added latency on the trailing edge) to avoid the live churn reconciling-on-partials can show when the recognizer revises a word it already emitted.

## Architecture

Flat layout, one test target, no subsystem folders beyond what's listed. The core dictation path is below; the correction layer, opt-in capture, and diagnostic sink (see "Shipped Since Baseline") extend it.

```
Sources/Epos/
  App/
    EposApp.swift               # @main, scenes, dependency wiring
    AppCoordinator.swift        # state machine: idle <-> recording <-> finalizing
  Permissions/
    PermissionsGate.swift       # mic + speech + accessibility, request + status
  Speech/
    AssetManager.swift          # SpeechTranscriber locale asset reserve + download
    Transcriber.swift           # SpeechAnalyzer + SpeechTranscriber wrapper
    TranscriptCanonicalizer.swift  # deterministic spoken->canonical correction rules (Shipped Since Baseline)
    TranscriptPolisher.swift    # opt-in polish gate/guard/fallback policy + PolishEngine seam (Shipped Since Baseline)
    TranscriptDeterministicCleaner.swift  # guard-proven hard-filler cleanup (Shipped Since Baseline)
    FoundationModelsPolishEngine.swift  # real PolishEngine: FoundationModels guided generation (Shipped Since Baseline)
    OllamaPolishEngine.swift   # optional local Ollama PolishEngine, env-selected for dogfooding (Shipped Since Baseline)
    OllamaPolishPrompt.swift   # conservative production + strict/conservative/relaxed eval Ollama prompts (Shipped Since Baseline)
    OllamaHTTPPolishClient.swift  # Ollama HTTP transport/schema for local polish (Shipped Since Baseline)
    PolishEngineFactory.swift  # chooses FoundationModels by default, Ollama via env config (Shipped Since Baseline)
  Audio/
    AudioCapture.swift          # AVAudioEngine input tap -> AnalyzerInput stream
    DogfoodTap.swift            # opt-in per-recording .wav capture (Shipped Since Baseline)
  Hotkey/
    FnHotkey.swift              # NSEvent global monitor for fn press/release
  UI/
    RecordingIndicator.swift    # floating pill: status dot + live audio meter
    MenuBarView.swift           # MenuBarExtra: status, quit, open permissions
    CorrectionsEditorView.swift # correction-rule editor window (+ CorrectionDraft, CorrectionDraftRow)
  Inject/
    TextInsertionBackend.swift  # synthesized-keystroke insertion backend (type + deleteBackward)
    ProgressiveTranscriptInsertion.swift  # append partials, reconcile finals (self-correct)
    InsertionTargetGuard.swift  # AX focus/value observer + pure guard decision (Shipped Since Baseline)
  Diagnostics/
    EposLogger.swift            # os.Logger + on-disk DiagnosticLogSink (Shipped Since Baseline)
```

No `Core/`, no `Utilities/`, no `Models/` folder of empty types. (Settings, the indicator controller, and small view styles also live under `App/` and `UI/`; the tree above lists the load-bearing modules.)

### Data flow

```
FnHotkey.press
  -> AppCoordinator.startRecording
     -> AudioCapture.start (16 kHz mono Float32 buffers)
     -> Transcriber.start (SpeechAnalyzer + SpeechTranscriber module, correction vocabulary as speech context)
     -> RecordingIndicator.show
  // types canonicalized deltas live -> TextInsertionBackend (synthesized keystrokes)
  // shows listening state -> RecordingIndicator (pill: status dot + meter)
FnHotkey.release
  -> AppCoordinator.finishRecording
     -> AudioCapture.stop
     -> Transcriber.finalize -> String
     -> TranscriptPolisher.polish(finalText) -> PolishResult   # opt-in polish, Shipped Since Baseline (raw on off; deterministic cleanup or raw on model fallback)
     -> TranscriptCanonicalizer.canonicalize(...)   # correction layer, Shipped Since Baseline
     -> TextInsertionBackend reconciles the field to the canonicalized final (backspaces + retypes any diverged suffix)
     -> RecordingIndicator.hide   # after polish + reconcile, so the indicator stays visible through the polish window
```

### Coordinator state

Three states, nothing more:

- `idle`
- `recording` (audio + transcription streaming, indicator visible)
- `finalizing` (input stopped, awaiting the last final, which reconciles the field to the canonicalized final transcript)

No retry loop, no circuit breaker, no error recovery state. Errors log + reset to `idle` + brief indicator flash. The v1 `RecordingStateMachine` (`Sources/SteezFlow/Core/StateMachine/`) is intentionally not ported — its surface is larger than the baseline needs.

## Key Technical Decisions

### Apple Speech: `SpeechAnalyzer` + `SpeechTranscriber` module

Use the new (macOS 26) `SpeechAnalyzer` pipeline with a `SpeechTranscriber` module — *not* the legacy `SFSpeechRecognizer` and *not* `DictationTranscriber`. The `DictationTranscriber` + custom-LM path was re-evaluated empirically and rejected on net accuracy (`specs/recognition-bias-decision.md`).

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

A single `NSPanel` (borderless, non-activating, click-through, floats above all), rendered as a compact pill:

- A status dot whose color signals state (idle / recording / finalizing).
- A live amplitude meter from the audio tap (RMS over a small window).

No transcript preview — the dictated text streams into the focused field, so the pill never echoes it. No frontmost-app icon, no waveform history, no draggable position. Centered above the active screen's bottom edge, fixed.

### Text injection

Backend: synthesized Unicode keyboard events (`KeystrokeTextInjector` → `CGEventKeyboardSetUnicodeString`), behind `TextInsertionBackend`. Each transcript delta rides its own ordered keyboard event, so streaming many deltas per dictation preserves order without a shared clipboard — the race that garbled the earlier streamed-`cmd+v` paste. The Unicode payload is set on keyDown only (carrying it on keyUp double-types in Chromium/Electron); events come from a private-state source with cleared flags so the held fn modifier can't leak; long deltas are chunked on grapheme boundaries within the length the API carries reliably. Requires Accessibility permission.

Insertion is retractable, and every update retracts as needed. Both volatile partials and authoritative per-segment finals reconcile: the session backspaces (`deleteBackward`) the suffix that diverges from the new target and retypes the corrected remainder, so the freshest words stream in immediately and a revised word is corrected in place. This favors latency over the earlier append-only-partials policy, which held the newest words back ~1 confirmation cycle (~1s on the trailing edge) to avoid the live churn that reconciling-on-partials can show when the recognizer revises a word it already emitted; the ~1.2s-to-first-word and ~1s update cadence underneath that is the on-device model's own floor, not tunable from the public API. Backspace-retract is reliable in plain text fields and terminals; in fields with their own autocomplete/autocorrect (search boxes, iMessage, IntelliSense editors) on-screen text can diverge from what was typed, so backspace counts could misalign — and reconciling on every partial exercises that path more often than the old per-final reconcile did. The target-aware insertion guards (see "Shipped Since Baseline") keep that misalignment from corrupting text: the session verifies the focused element and the on-screen value before backspacing and stops deleting (append-only) or aborts when either diverges. Epos does not install or require a selected InputMethodKit input source.

### Concurrency

- Audio capture on its dedicated `AVAudioEngine` thread.
- Transcription stream consumed on a `Task` owned by `AppCoordinator`.
- UI updates marshaled to the main actor.
- No custom queues, no `OperationQueue`, no actor sprawl. `AppCoordinator` is `@MainActor`.

### Logging

`os.Logger` for unified logging — one subsystem (`com.steez.Epos`), categories per module — mirrored to an app-owned, size-capped, rotated on-disk `DiagnosticLogSink` (see "Shipped Since Baseline"; it writes direct events to disk instead of polling the unified-log store). No ring buffer, no `StateHistory`.

### Settings

A single `UserDefaults`-backed struct: launch-at-login bool, install locale string, a `saveAudioSamples` bool (opt-in audio capture), and a `polishEnabled` bool (opt-in on-device LLM polish, default off). Surfaced in the menu bar popover. The polish engine selector is intentionally launch configuration, not persisted UI state: default FoundationModels, or Ollama with `EPOS_POLISH_ENGINE=ollama` and optional `EPOS_OLLAMA_MODEL`. Correction rules persist separately under their own `UserDefaults` key and are edited in the Corrections window.

## Build & Project Layout

- Swift Package + a thin Xcode app target (same shape as v1) so we can sign + entitle + bundle.
- Entitlements: microphone, speech recognition, accessibility, hardened runtime. No sandbox in the baseline (keystroke injection wants accessibility, and there is no App Store target).
- One scheme: `EposMacApp`. One test scheme: `EposTests`.
- Lint: `swiftlint` with the v1 config copied verbatim.

## Testing

Test what would silently break, skip the rest.

- `AssetManager`: status reporting (`missing`, `downloading`, `ready`, `reserved`) — mock `AssetInventory`.
- `Transcriber`: feeds a known-good wav, asserts a non-empty final string — integration test, only runs when locale asset is installed (`XCTSkipIf`).
- `AppCoordinator`: state transitions on synthetic hotkey events with a fake transcriber + fake injector.
- `ProgressiveTranscriptInsertionSession`: immediate per-partial streaming, the live reconcile that backspaces and retypes a revised word on partials and finals so the field converges to the recognizer's text, cancel, and idempotent repeat finals.
- `KeystrokeTextInjector`: grapheme-safe UTF-16 chunking of synthesized keystrokes.
- Transcript timing diagnostics: emit quoted transcript text so dogfood runs can debug recognizer timing and text churn.
- Opt-in dogfood evals: replay saved wavs for recognition-context checks, text-only polish scoring, direct raw relaxed Ollama candidate scoring, strict-vs-relaxed Ollama shadow scoring, and the combined wav -> transcript -> canonicalizer -> polish guard pipeline with rejected candidate text and guard diffs in JSONL.
- Hotkey, audio capture, indicator UI: not unit tested; verified by running the app.

Target: < 30 tests total. If we cross that, we are testing implementation, not behavior.

## Repository

This repo is the greenfield rebuild now named Epos. The prior SteezFlow implementation lives at `~/Projects/Personal/steezflow` (99 Swift files, 28 specs, 16.7K LOC) and stays on disk as reference only — not a dependency, not a submodule, not something this repo imports from. The only v1 code worth porting verbatim is the fn-key monitor and the original paste injector (since replaced by synthesized-keystroke insertion), both small enough to retype. v1 remains available until this rebuild is daily-driver stable.

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
6. ~~LLM polish (local MLX) as opt-in per-recording.~~ **Shipped** as an opt-in global toggle using on-device FoundationModels guided generation, with a local Ollama engine available behind environment config for dogfooding (see "Shipped Since Baseline"). A per-recording toggle and persisted engine/model UI are still open.
7. Filler-word detection.
8. Audio device hot-swap handling.
9. Agent-specific modes (Codex / Claude Code / Cursor).
10. Custom hotkey binding UI.
11. ~~Target-aware insertion guards for fields where backspace-retract can misalign — autocomplete/autocorrect fields (search boxes, iMessage, IntelliSense editors): focused-element verification, and stop/fallback when on-screen text diverges from what was typed or focus changes mid-recording.~~ **Shipped** (see "Shipped Since Baseline").

Each is a separate spec when its turn comes. None block the baseline.
