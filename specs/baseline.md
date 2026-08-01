# Epos — Baseline Spec

Date: 2026-05-22 · Revised: 2026-07-29 (authoritative insertion moved to one guarded final write; volatile recognition stays visible in the recording HUD; failed opt-in audio samples are retained for diagnosis; local reliability auditing classifies accuracy and operational outcomes separately; see "Shipped Since Baseline")

A clean-sheet rebuild of Epos as a minimal dictation app on top of Apple's `SpeechTranscriber` (macOS 26+). No WhisperKit, no MLX, no filler detector. Those were post-baseline candidates, not baseline requirements. A deterministic, user-editable correction layer has since shipped on top of this baseline; an opt-in on-device LLM polish stage shipped, was benchmarked, and has been removed — see "Shipped Since Baseline".

## Product

Hold fn → record while the recording HUD previews the recognizer's volatile text → release → Epos canonicalizes and conservatively cleans the final transcript, then writes it once into the text field that was focused at fn press. If that target or its selection changed, Epos inserts nothing and says so visibly. That is the whole product.

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

- **Correction layer** (`Speech/TranscriptCanonicalizer.swift`, `UI/CorrectionsEditorView.swift`, `CorrectionDraft.swift`, `CorrectionDraftRow.swift`). Deterministic spoken→canonical rewriting applied once to the authoritative final transcript before insertion: user-editable alias→canonical records with optional context guards, plus built-in developer-token normalization (`dash dash` → `--`, `slash goal` → `/goal`, `dollar home` → `$HOME`). Backlog #1 + #4. Replacements match only the recognizer's original text; one replacement's canonical output is never fed through later rules. The editor operates on correction records and preserves stable IDs, source, status, and person-lexicon alias classes across no-op saves and reorders. Records persist under their own `UserDefaults` key and are edited in a dedicated Corrections window. On upgrade, existing built-ins migrate in place while newly introduced built-in IDs append without changing manual records or a built-in's disabled status; an unreadable record or a dictionary written by a newer schema remains readable in memory but suppresses migration, persistence, and reseeding for that load. Local transcript/edit evidence for suggested corrections is controlled separately by `Settings.saveCorrectionEvidence` (opt-in, default off, surfaced as "Learn corrections") and is independent of opt-in audio sample capture. Exposed rules only, not grammar or style rewriting.
- **Opt-in audio sample capture** (`Audio/DogfoodTap.swift`). Per-recording `.wav` capture to `~/Library/Application Support/Epos/recordings/` as local eval material. Application Support, not the cache: these recordings are the frozen evaluation corpus and macOS purges caches under disk pressure. Off by default, gated by `Settings.saveAudioSamples`. Empty and failed transcription sessions are retained when capture is enabled because their audio is the evidence needed to distinguish silence, wrong-input, capture, and recognizer failures.
- **On-disk diagnostic log** (`Diagnostics/EposLogger.swift` → `DiagnosticLogSink`). Mirrors `os.Logger` events to a size-capped, rotated app-owned log under `~/Library/Caches/Epos/logs/` (writes direct events instead of polling the unified-log store). This is a local dogfood/debug surface; transcript-bearing diagnostic text for transcript timing is redacted by default and requires `EPOS_DIAGNOSTIC_TRANSCRIPT_TEXT=1`. Disable logs entirely with `EPOS_DIAGNOSTIC_LOGS=0`.
- **Target-aware insertion guard** (`Inject/InsertionTargetGuard.swift`, wired into `Inject/FinalTranscriptInsertion.swift`). Backlog #11. The session captures the focused Accessibility element and any readable value, caret, and selection at fn press. Immediately before the single final write it checks that the original application and field are still focused and that observable context is unchanged. Opaque Electron targets use the stable process and focus signature instead of pretending their value is readable. Any mismatch refuses the entire insertion; Epos does not refocus, append elsewhere, or delete text. AX I/O is bounded with `AXUIElementSetMessagingTimeout` so a wedged accessibility server cannot stall finalization. Two Chromium-host accommodations keep the guard usable there without weakening it: `Inject/ElectronAccessibilityWaker.swift` sets the Electron-documented `AXManualAccessibility` attribute on every app the user activates (never unset; a no-op on hosts without the attribute), because Chromium keeps its accessibility tree unbuilt until an assistive client announces itself and an unwoken tree makes the fn-press capture see no focused element at all; and before the final authorization the session waits out a bounded ladder for the readable baseline to be restored (`settleReadableBaseline` — run only for a recording whose preview mark may still be drawn, polling the guard's own shared comparison including its focus checks), because Chromium reflects a composition teardown into its AX value asynchronously and an immediate read mistakes stale marked text for a user edit. Every refusal leg of the readable-context comparison logs its reason with lengths and ranges only. The pure decision is unit-tested with fake observations; live Accessibility behavior requires the installed signed app.
- **Conservative final cleanup** (`Speech/TranscriptDeterministicCleaner.swift`; applied per recording by `App/AppCoordinator.swift`). Always on, no toggle. Removes only hard fillers (`um`/`uh`/`er`/`hmm`, with an acronym guard), collapses stuttered function-word repeats from a closed allow-list, and writes standalone numeric ordinals as words (`1st` -> `first`). It runs on the streamed HUD text and, after canonicalization, on the authoritative final transcript, so the one guarded write can never re-type text the user already saw cleaned. Everything ambiguous survives: "you know", bare or comma-delimited `so`/`like`, emphatic and grammatical doublings, and grammar shape. Spoken-symbol conversion remains solely owned by `TranscriptCanonicalizer`.
- **Opt-in LLM polish — shipped, benchmarked, removed 2026-07-29.** Backlog #6. An opt-in `Settings.polishEnabled` polish stage (FoundationModels guided generation by default, a local Ollama engine behind `EPOS_POLISH_ENGINE` for dogfooding, a content-retention guard, and a deterministic fallback) shipped and stayed default-off. The 2026-06-07 local-model benchmark found no model with a safe operating point above the deterministic transforms above: the only safe configuration did nothing the deterministic cleaner does not already do, at gigabytes of resident memory. The whole stack — policy, guard, engines, prompts, HTTP client, menu toggle, and eval harnesses — was deleted rather than carried as dead maintenance surface. Full record: `specs/polish-model-benchmark.md`; earlier design notes in `specs/llm-polish-probe.md` and `specs/ollama-polish-levers/`. Do not re-add an LLM rewrite stage without new evidence that clears that bar.
- **Final-only guarded insertion** (`Inject/FinalTranscriptInsertion.swift`, `Inject/TextInsertionBackend.swift`). Epos captures the focused field, value, caret, and selection at fn press. Volatile and per-segment final recognition events update only in-memory transcript state and the recording HUD. After finalization, canonicalization, and conservative cleanup, Epos sends the authoritative transcript once through synthesized Unicode keystrokes (`KeystrokeTextInjector`, `CGEventKeyboardSetUnicodeString`), with no clipboard and no corrective backspaces. Immediately before insertion it verifies that focus and any observable field context still match the fn-press baseline. A changed target causes zero keystrokes and a visible "Not inserted" result. This retires progressive target mutation: typing and retracting unstable partials created app-specific races with Teams, terminals, autocomplete, autocorrect, and Accessibility views that regenerate their elements. Marked-text inline preview (below) is not that: composition text is never in the document, so it needs no retraction and cannot race the field's own content.
- **Inline preview (palette input method)** (`Inject/InlinePreviewSession.swift`, `Inject/InlinePreviewTransport.swift`, companion bundle from `probes/inline-preview/` installed as `~/Library/Input Methods/EposProbe.app`). Live volatile text streams into the fn-press field as input-method marked text via a palette-type InputMethodKit companion — Apple Dictation's own mechanism; palette selection is additive and never replaces the user's keyboard layout. Preview only: marked text is discarded before finalization, the authoritative commit remains the single guarded write (an acked IME commit replaces it; otherwise keystrokes follow the discard), and crash, focus change, or guard refusal leaves the field byte-identical to fn-press. Gated by `Settings.inlinePreview` (default on, menu-bar toggle); when the companion is missing, degraded, or slow past the 200ms deadline the pill HUD presents instead, so a fresh machine without the input method just sees the pre-preview behavior. No preview inside Secure Input contexts (final write still works). Design record and probe protocol: `specs/inline-preview-feasibility.md`; the pre-registered cmux/Ghostty kill criterion passed in daily dogfood use. `scripts/install-signed-app.sh` builds, signs, installs, and live-registers the companion. Live registration (`lsregister -f -R -trusted` + `TISRegisterInputSource` + restarting the text-input agents) has worked without a logout every time it has been tried, contradicting the DevForums 775526 expectation the design assumed; the logout path is a never-yet-needed fallback the installer surfaces as a non-fatal warning (`probes/inline-preview/install --verify-only` after logging back in).
- **Speaker-audio rejection** (`Audio/AudioCapture.swift`). Dictating while the machine plays music or a video used to transcribe that audio alongside the user. The mic now runs through Apple's voice-processing IO (`AVAudioInputNode.setVoiceProcessingEnabled`) — the AUVoiceProcessingIO path Siri and FaceTime use — whose echo canceller references what the *device* renders, so other apps' output is subtracted, not just Epos's own. Gated by `Settings.echoCancellation` (default on, menu-bar toggle "Ignore speaker audio"); read at each fn press because the mode can only change while the engine is stopped. A device that refuses the mode logs and captures raw rather than losing the dictation. Two findings from the measured rollout, both load-bearing: (1) voice processing replaces the 1-channel hardware input with **nine `DiscreteInOrder` channels** carrying identical copies of the processed mono signal, and `AVAudioConverter`'s implicit N→1 downmix for that layout emits **digital silence** — no error, correct frame counts, every transcript empty; the converter selects channel 0 explicitly (`channelMap = [0]`, lossless at 0.963x, which is the 48k→16k low-pass), pinned by `Tests/EposTests/AudioCaptureConverterTests.swift`. (2) The echo canceller alone is *not* sufficient for push-to-talk: it is adaptive and each fn press starts it unconverged. Measured with speech played from the speakers during a hold — raw mic 84 transcribed chars, ducking at `.min` 55, `.mid` 84, `.max` 0 across three runs — so the ducking level is `.max`. The dip lasts only as long as the hold. Verified with the installed signed app driving real recordings; the residual open item is a human-voice confirmation that dictation quality is unchanged in a quiet room.
- **Local reliability audit** (`Diagnostics/ReliabilityDiagnostics.swift`, `scripts/audit`). Each recording emits privacy-safe, recording-scoped outcome metadata. The audit assigns every selected recording exactly one operational outcome, reports incomplete or ambiguous sessions instead of dropping them, and keeps delivery outcomes separate from recognition accuracy. For AX-readable targets, a bounded post-write readback can verify exact delivery without logging transcript text; opaque targets remain explicitly unverified. The same command summarizes signed corpus artifacts into exact, residual substitution, residual insertion, residual deletion, and empty/error buckets. It calls the result verified accuracy only when every selected row carries explicit `human_confirmed` reference provenance; legacy artifacts without it remain visible as historical evidence. New signed artifacts score Epos's deterministic production baseline after the active correction dictionary and stream cleaner; older raw-only artifacts are labeled as raw recognizer evidence. It never combines WER with operational delivery rates into one score and never uploads data.

## Architecture

Flat layout, one test target, no subsystem folders beyond what's listed. The core dictation path is below; the correction layer, opt-in capture, and diagnostic sink (see "Shipped Since Baseline") extend it.

```
Sources/Epos/
  App/
    EposApp.swift               # @main, scenes, dependency wiring
    AppCoordinator.swift        # state machine: idle <-> recording <-> finalizing
    StartReadinessProbe.swift   # can a press open a dictation: grants + model + capture format
    RecordingCuePresenter.swift # which cue is up: screen-edge glow, pill, or neither
    InlinePreviewCoordinator.swift # one recording's inline-preview session lifecycle
    CorrectionEvidenceRecorder.swift # evidence row + post-insertion watch for the user's edit
  Permissions/
    PermissionsGate.swift       # mic + speech + accessibility, request + status
  Speech/
    AssetManager.swift          # SpeechTranscriber locale asset reserve + download
    Transcriber.swift           # SpeechAnalyzer + SpeechTranscriber wrapper
    TranscriptCanonicalizer.swift  # deterministic spoken->canonical correction rules (Shipped Since Baseline)
    TranscriptDeterministicCleaner.swift  # always-on hard-filler + stutter + ordinal cleanup (Shipped Since Baseline)
  Audio/
    AudioCapture.swift          # AVAudioEngine input tap -> AnalyzerInput stream
    DogfoodTap.swift            # opt-in per-recording .wav capture (Shipped Since Baseline)
  Hotkey/
    FnHotkey.swift              # NSEvent global monitor for fn press/release
  UI/
    RecordingIndicator.swift    # floating HUD: state + audio meter + volatile transcript preview
    MenuBarView.swift           # MenuBarExtra: status, quit, open permissions
    CorrectionsEditorView.swift # correction-rule editor window (+ CorrectionDraft, CorrectionDraftRow)
  Inject/
    TextInsertionBackend.swift  # synthesized-keystroke insertion backend (one final write)
    FinalTranscriptInsertion.swift  # captures target at fn press; inserts final once if unchanged
    InsertionTargetGuard.swift  # AX focus/value observer + pure guard decision (Shipped Since Baseline)
  Diagnostics/
    EposLogger.swift            # os.Logger + on-disk DiagnosticLogSink (Shipped Since Baseline)
    ReliabilityDiagnostics.swift # privacy-safe per-recording terminal outcome (Shipped Since Baseline)
```

No `Core/`, no `Utilities/`, no `Models/` folder of empty types. (Settings, the
indicator controller, the coordinator's settings facade, and small view styles also
live under `App/` and `UI/`; the tree above lists the load-bearing modules.) The
four `App/` types below `AppCoordinator` are its collaborators: it owns the state
machine and every published value the UI observes, and delegates the subsystems.

### Data flow

```
FnHotkey.press
  -> AppCoordinator.startRecording
     -> RecordingIndicator.show (edge glow, or the pill)
     -> AudioCapture.start (16 kHz mono Float32 buffers) — first, so the start cue is
        an honest "mic is hot"; buffers queue in CapturePreRoll until the analyzer exists
     -> RecordingCue.playStart
     -> FinalTranscriptInsertionSession captures focused target + selection
     -> Transcriber.start (SpeechAnalyzer + SpeechTranscriber module, correction vocabulary as speech context)
        -> CapturePreRoll hands over everything captured while it was starting
  // volatile partials update only in-memory transcript + RecordingIndicator preview
FnHotkey.release
  -> AppCoordinator.finishRecording
     -> AudioCapture.stop
     -> Transcriber.finalize -> String
     -> TranscriptCanonicalizer.canonicalize(finalText)   # correction layer, Shipped Since Baseline
     -> TranscriptDeterministicCleaner.streamClean(...)   # same conservative cleanup the HUD streamed
     -> FinalTranscriptInsertionSession verifies the fn-press target and writes once
     -> RecordingIndicator.hide   # after insertion, or after visibly reporting "Not inserted"
```

### Coordinator state

Three states, nothing more:

- `idle`
- `recording` (audio + transcription streaming to the local preview, indicator visible)
- `finalizing` (input stopped, awaiting the last final and one guarded insertion)

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

A single `NSPanel` (borderless, non-activating, click-through, floats above all), rendered as a compact HUD:

- A status dot whose color signals state (idle / recording / finalizing).
- A live amplitude meter from the audio tap (RMS over a small window).
- One tail-truncated line of volatile transcript text while recording.
- A brief visible red notice whenever a dictation cannot complete normally, naming
  which stage failed: "Not inserted" (the fn-press target is no longer safe),
  "Mic lost" (the microphone died mid-hold), "Recognition lost" (the recognizer
  stopped mid-hold; what it heard first is still written at release), and
  "Not ready" (the session never started). Silence is never an acceptable outcome
  for a dictation the user held fn and spoke into.

The preview is memory-only and clears with the recording session. No persistent history, frontmost-app icon, waveform history, or draggable position. Centered above the active screen's bottom edge, fixed.

### Text injection

Backend: synthesized Unicode keyboard events (`KeystrokeTextInjector` → `CGEventKeyboardSetUnicodeString`), behind `TextInsertionBackend`. The authoritative final transcript is sent once without a shared clipboard. The Unicode payload is set on keyDown only (carrying it on keyUp double-types in Chromium/Electron); events come from a private-state source with cleared flags so the held fn modifier can't leak; long text is chunked on grapheme boundaries within the length the API carries reliably. Requires Accessibility permission.

The insertion session captures its target at fn press, before recording or asynchronous finalization can move focus. At release it verifies the same application and focused element. Where Accessibility exposes text, it also verifies the original value, caret, or selection. It then inserts once or refuses completely. Epos never restores focus and never issues corrective backspaces. Long writes remain a sequence of ordered Unicode events rather than a transactional system edit, so signed-app verification must cover long text in Teams, terminals, and editors. Epos does not install or require a selected InputMethodKit input source.

### Concurrency

- Audio capture on its dedicated `AVAudioEngine` thread.
- Transcription stream consumed on a `Task` owned by `AppCoordinator`.
- UI updates marshaled to the main actor.
- No custom queues, no `OperationQueue`, no actor sprawl. `AppCoordinator` is `@MainActor`.

### Logging

`os.Logger` for unified logging — one subsystem (`com.steez.Epos`), categories per module — mirrored to an app-owned, size-capped, rotated on-disk `DiagnosticLogSink` (see "Shipped Since Baseline"; it writes direct events to disk instead of polling the unified-log store). No ring buffer, no `StateHistory`.

Each recording also emits one parseable `reliability outcome` event. Outcomes distinguish setup failure, no audio input, recognizer failure, empty transcript, target refusal, backend refusal, delivery mismatch, AX-verified delivery, and accepted-but-unverified delivery. The event contains counts, booleans, outcome, and latency only. It does not contain transcript text. `scripts/audit` classifies stale logs that predate this event from their existing boundaries but labels inferred and incomplete results honestly.

### Settings

A single `UserDefaults`-backed struct: launch-at-login bool, install locale string, a `saveAudioSamples` bool (opt-in audio capture), and a `saveCorrectionEvidence` bool (opt-in local transcript/edit evidence for Corrections suggestions, default off). Surfaced in the menu bar popover. Final-transcript cleanup has no setting: it is always on and deliberately conservative. Correction rules persist separately under their own `UserDefaults` key and are edited in the Corrections window.

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
- `FinalTranscriptInsertionSession`: partials produce no backend operations; one final writes once; changed focus/value/caret/selection writes nothing; initial selection replacement, cancel, and repeated finalization are safe.
- `KeystrokeTextInjector`: grapheme-safe UTF-16 chunking of synthesized keystrokes.
- Transcript timing diagnostics: emit quoted transcript text so dogfood runs can debug recognizer timing and revisions without mutating the target field.
- Reliability diagnostics: one terminal outcome per recording, exact AX readback when available, no transcript text, and explicit incomplete/ambiguous classification in `scripts/audit`.
- Deterministic cleanup: hard fillers, stutter collapse, and numeric ordinals are pinned by behavior, including everything the pass must leave alone.
- Opt-in dogfood evals: replay saved wavs for recognition-context checks, raw recognizer scoring, and correction-candidate scoring against the signed corpus. When a human transcript manifest is present, the saved-recording harnesses log the intended transcript and WER/accuracy for raw, canonicalized raw, and final output.
- Hotkey, audio capture, indicator UI: not unit tested; verified by running the app.

Target: < 30 tests total. If we cross that, we are testing implementation, not behavior.

## Repository

This repo is the greenfield rebuild now named Epos. The prior SteezFlow implementation lives at `~/Projects/Personal/steezflow` (99 Swift files, 28 specs, 16.7K LOC) and stays on disk as reference only — not a dependency, not a submodule, not something this repo imports from. The only v1 code worth porting verbatim is the fn-key monitor and the original paste injector (since replaced by synthesized-keystroke insertion), both small enough to retype. v1 remains available until this rebuild is daily-driver stable.

## Acceptance — Baseline Done

All of:

- Holding fn while a text field is focused produces the spoken text in that field on release, end-to-end, in under 500 ms after release for a 10-second utterance.
- Indicator appears within 100 ms of fn press, transitions to finalizing immediately on release, and disappears only after insertion or a visible failure result.
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
6. ~~LLM polish (local MLX) as opt-in per-recording.~~ **Closed — shipped then removed.** Built as an opt-in global toggle, benchmarked against local models, and deleted 2026-07-29 because no model beat the deterministic cleanup safely (`specs/polish-model-benchmark.md`). Not open work; reopening needs new evidence.
7. Filler-word detection.
8. Audio device hot-swap handling.
9. Agent-specific modes (Codex / Claude Code / Cursor).
10. Custom hotkey binding UI.
11. ~~Target-aware insertion guard: capture the fn-press target and refuse final insertion if focus, field value, caret, or selection changes before release.~~ **Shipped** (see "Shipped Since Baseline").
12. ~~Built-in correction re-seed on upgrade.~~ **Shipped** with versioned introduction metadata. An upgrade appends only built-ins introduced after the saved dictionary version, so a rule intentionally removed from that saved version stays removed.

Each is a separate spec when its turn comes. None block the baseline.
