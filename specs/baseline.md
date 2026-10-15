# Epos — Baseline Spec

Date: 2026-05-22. Documentation reconciled with source on 2026-10-01.
Configurable input controls added to scope on 2026-10-02.
Native keyboard-session preview redesign added to scope on 2026-10-09.
Continuous preview finalization added to scope on 2026-10-15.

Start at [docs/readme.md](../docs/readme.md) for the current feature map, implementation, tests, and verification limits. This document governs product scope and design. Historical validation below does not establish the current installed app's behavior.

A clean-sheet rebuild of Epos as a minimal dictation app on top of Apple's `SpeechTranscriber` (macOS 26+). No WhisperKit, no MLX, no filler detector. Those were post-baseline candidates, not baseline requirements. A deterministic, user-editable correction layer has since shipped on top of this baseline; an opt-in on-device LLM polish stage shipped, was benchmarked, and has been removed — see "Shipped Since Baseline".

## Product

Hold the dictation shortcut, which defaults to fn, to record and preview volatile text. Release to finalize, canonicalize, conservatively clean, and write once into the field captured at press. If the target or its selection changed, Epos inserts nothing and reports the refusal. The menu offers a shortcut recorder and microphone picker.

## Constraints

- macOS 26.0+ only. The baseline drops every earlier OS; `SpeechTranscriber` is the entire reason for the rebuild.
- Apple Silicon only.
- On-device. No network at runtime except the one-time `SpeechTranscriber` locale asset download via `AssetInventory`.
- Single locale per install (start with `en-US`); locale switching is a post-baseline concern.
- Target footprint: under ~50 MB resident while idle, under ~100 MB while transcribing. Bakeoff measured `SpeechTranscriber` at ~27 MB RSS.
- Keep modules focused by responsibility (see `AGENTS.md`) rather than policing one global budget. The core dictation path held to the original ~2,000 LOC target; the correction layer, opt-in audio capture, and diagnostic sink shipped on top of it (see "Shipped Since Baseline"), so the whole app now runs larger. Cut scope at the module level.

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
- **Target-aware insertion guard** (`Inject/InsertionTargetGuard.swift`, wired into `Inject/FinalTranscriptInsertion.swift`). Backlog #11. The session captures the focused Accessibility element and any readable value, caret, and selection at shortcut press. Immediately before final delivery it checks that the original application and field are still focused. Keystroke delivery also requires unchanged observable text context; an owned native composition uses the companion checks described below. Opaque Electron targets use the stable process and focus signature instead of pretending their value is readable. Any mismatch refuses the entire insertion; Epos does not refocus, append elsewhere, or delete text. AX I/O is bounded with `AXUIElementSetMessagingTimeout` so a wedged accessibility server cannot stall finalization. Two Chromium-host accommodations keep the guard usable there without weakening it: `Inject/ElectronAccessibilityWaker.swift` sets the Electron-documented `AXManualAccessibility` attribute on every app the user activates (never unset; a no-op on hosts without the attribute), because Chromium keeps its accessibility tree unbuilt until an assistive client announces itself and an unwoken tree makes the shortcut-press capture see no focused element at all; and before the final authorization the session waits out a bounded ladder for the readable baseline to be restored (`settleReadableBaseline` — run only for a recording whose preview mark may still be drawn, polling the guard's own shared comparison including its focus checks), because Chromium reflects a composition teardown into its AX value asynchronously and an immediate read mistakes stale marked text for a user edit. Every refusal leg of the readable-context comparison logs its reason with lengths and ranges only. The pure decision is unit-tested with fake observations; live Accessibility behavior requires the installed signed app.
- **Conservative final cleanup** (`Speech/TranscriptDeterministicCleaner.swift`; applied per recording by `App/AppCoordinator.swift`). Always on, no toggle. Removes only hard fillers (`um`/`uh`/`er`/`hmm`, with an acronym guard), collapses stuttered function-word repeats from a closed allow-list, and writes standalone numeric ordinals as words (`1st` -> `first`). It runs on the streamed HUD text and, after canonicalization, on the authoritative final transcript, so the one guarded write can never re-type text the user already saw cleaned. Everything ambiguous survives: "you know", bare or comma-delimited `so`/`like`, emphatic and grammatical doublings, and grammar shape. Spoken-symbol conversion remains solely owned by `TranscriptCanonicalizer`.
- **Opt-in LLM polish — shipped, benchmarked, removed 2026-07-29.** Backlog #6. An opt-in `Settings.polishEnabled` polish stage (FoundationModels guided generation by default, a local Ollama engine behind `EPOS_POLISH_ENGINE` for dogfooding, a content-retention guard, and a deterministic fallback) shipped and stayed default-off. The 2026-06-07 local-model benchmark found no model with a safe operating point above the deterministic transforms above: the only safe configuration did nothing the deterministic cleaner does not already do, at gigabytes of resident memory. The whole stack — policy, guard, engines, prompts, HTTP client, menu toggle, and eval harnesses — was deleted rather than carried as dead maintenance surface. Full record: `specs/polish-model-benchmark.md`; earlier design notes in `specs/llm-polish-probe.md` and `specs/ollama-polish-levers/`. Do not re-add an LLM rewrite stage without new evidence that clears that bar.
- **Final-only guarded insertion** (`Inject/FinalTranscriptInsertion.swift`, `Inject/TextInsertionBackend.swift`). Epos captures the focused field, value, caret, and selection at shortcut press. Volatile and per-segment final recognition events update in-memory transcript state, the recording HUD, and an eligible marked-text preview. After finalization, canonicalization, and conservative cleanup, Epos sends the authoritative transcript once through an acknowledged IME commit when the preview channel is eligible, otherwise through synthesized Unicode keystrokes (`KeystrokeTextInjector`, `CGEventKeyboardSetUnicodeString`), with no clipboard and no corrective backspaces. An IME commit sent without a conclusive acknowledgement is reported as ambiguous and suppresses a second write. Immediately before insertion it verifies captured focus and either the companion's native composition ownership or, for keystrokes, the original observable field context. A changed target causes zero keystrokes and a visible "Not inserted" result. This retires progressive target mutation: typing and retracting unstable partials created app-specific races with Teams, terminals, autocomplete, autocorrect, and Accessibility views that regenerate their elements. Marked-text inline preview uses provisional host composition. It can change the live field value while visible, so selection preservation, concrete client ownership, live composition ownership, and cancellation remain safety requirements.
- **Inline preview (native keyboard input method)** (`Inject/InlinePreviewSession.swift`, `Inject/PreviewKeyboardSource.swift`, companion `probes/inline-preview/`). Epos adopts its already selected companion without changing the user's source, or acquires it during a hold. A successful native commit acquired from a keyboard layout keeps Epos selected with that layout; failures and borrowed input methods restore the prior source unless the user chose another. Both paths preserve the underlying keyboard mapping. Actual companion activation, readable empty selection, and concrete client/connection ownership authorize an uninterrupted draft session. An unavailable initial marked range requires actual Epos activation with an adopted layout or acquisition from a keyboard layout; known foreign composition is refused. Drafts use native marked text, with range checks and readable text equality when supported. Keyboard and mouse interaction, focus or source changes, host teardown, and connection loss retire the session. Healthy owned drafts commit in place after the guard accounts for the preview. Unavailable preview channels use guarded Unicode delivery after cleanup. Missing source, activation, or companion Accessibility uses the HUD. The October 9 redesign still requires installed Ghostty acceptance; historical palette feasibility and isolated experiments do not certify it. See [insertion.md](../docs/insertion.md) and the Text injection design below.
- **Speaker-audio rejection — built, measured, default OFF** (`Audio/AudioCapture.swift`, `Settings.echoCancellation`). Dictating while the machine plays music or a video transcribes that audio alongside the user. The mic can be routed through Apple's voice-processing IO (`AVAudioInputNode.setVoiceProcessingEnabled`), whose echo canceller references what the *device* renders, so other apps' output is subtracted, not just Epos's own. It works: with speech played from the speakers during a hold, three of four runs transcribed 0 chars against an 82-char no-processing control. **It ships off anyway**, because macOS voice processing always ducks other audio while it runs and the dip is audible at `.min`, the lowest level the platform offers. Ducking cannot be disabled: the level enum has no "off" and `kAUVoiceIOProperty_DuckNonVoiceAudio` is iOS-only and deprecated. Quieting audio the user chose to play is a worse failure than occasionally transcribing it. Enable via the menu toggle "Ignore speaker audio"; read at each shortcut press because the mode only changes while the engine is stopped, and `stop()` turns it back off so the unit never outlives the hold (leaving it on ducked the whole machine until Epos quit). One trap this leaves behind regardless of the toggle: voice processing swaps the 1-channel hardware input for **nine `DiscreteInOrder` channels** carrying identical copies of the processed mono signal, and `AVAudioConverter`'s implicit N→1 downmix for that layout emits **digital silence** — no error, correct frame counts, every transcript empty. `AudioCapture.makeConverter` selects channel 0 explicitly (`channelMap = [0]`, lossless at 0.963x, the 48k→16k low-pass); `Tests/EposTests/AudioCaptureConverterTests.swift` measures exactly 0.0 without it. Untested lever if this is revisited: `enableAdvancedDucking = true` with `.min` (Apple's own WWDC23 sample pairing) was never tried. The route that meets the requirement properly is a self-built canceller taking the reference from ScreenCaptureKit (`capturesAudio` + `excludesCurrentProcessAudio`), which is what Apple shipped on iOS 18.2 as `setPrefersEchoCancelledInput` and has not brought to macOS.
- **Local reliability audit** (`Diagnostics/ReliabilityDiagnostics.swift`, `scripts/audit`). Each recording emits privacy-safe, recording-scoped outcome metadata. The audit assigns every selected recording exactly one operational outcome, reports incomplete or ambiguous sessions instead of dropping them, and keeps delivery outcomes separate from recognition accuracy. For AX-readable targets, a bounded post-write readback can verify exact delivery without logging transcript text; opaque targets remain explicitly unverified. The same command summarizes signed corpus artifacts into exact, residual substitution, residual insertion, residual deletion, and empty/error buckets. It calls the result verified accuracy only when every selected row carries explicit `human_confirmed` reference provenance; legacy artifacts without it remain visible as historical evidence. New signed artifacts score Epos's deterministic production baseline after the active correction dictionary and stream cleaner; older raw-only artifacts are labeled as raw recognizer evidence. It never combines WER with operational delivery rates into one score and never uploads data.

## Architecture

Flat layout, one test target, no subsystem folders beyond what's listed. The core dictation path is below; the correction layer, opt-in capture, and diagnostic sink (see "Shipped Since Baseline") extend it.

```
Sources/Epos/
  App/
    EposApp.swift               # @main, scenes, dependency wiring
    AppCoordinator.swift        # readiness, shortcut/deferred presses, published UI and presentation
    AppCoordinatorInputControls.swift # guarded input preferences and recorder suspension
    RecordingSession.swift      # one hold owns capture, recognition, preview, final delivery and teardown
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
    AudioInputDevices.swift     # available input UIDs and fresh device ID resolution
    AudioInputDeviceMonitor.swift # device inventory and liveness changes
    AudioInputDeviceBinding.swift # audio-unit device binding and readback
    DogfoodTap.swift            # opt-in per-recording .wav capture (Shipped Since Baseline)
  Hotkey/
    DictationHotkey.swift       # configurable press/release and lost-release recovery
    DictationShortcut.swift     # persisted validated binding, fn default
    ShortcutRecording.swift    # recorder candidate and release reducer
  UI/
    RecordingIndicator.swift    # floating HUD: state + audio meter + volatile transcript preview
    MenuBarView.swift           # MenuBarExtra: status, quit, open permissions
    ShortcutRecorderView.swift  # native key-window recorder from the menu
    CorrectionsEditorView.swift # correction-rule editor window (+ CorrectionDraft, CorrectionDraftRow)
  Inject/
    TextInsertionBackend.swift  # synthesized-keystroke insertion backend (one final write)
    FinalTranscriptInsertion.swift  # captures target at shortcut press; inserts final once if unchanged
    InsertionTargetGuard.swift  # AX focus/value observer + pure guard decision (Shipped Since Baseline)
  Diagnostics/
    EposLogger.swift            # os.Logger + on-disk DiagnosticLogSink (Shipped Since Baseline)
    ReliabilityDiagnostics.swift # privacy-safe per-recording terminal outcome (Shipped Since Baseline)
```

No `Core/`, no `Utilities/`, no `Models/` folder of empty types. (Settings, the
indicator controller, the coordinator's settings facade, and small view styles also
live under `App/` and `UI/`; the tree above lists the load-bearing modules.) The
recording session owns the transcription task, frozen transcript transform, capture
callbacks, target insertion session, preview, reliability record, and release waiter.
`AppCoordinator` owns readiness, deferred shortcut presses, and every published UI value.
A session completes cleanup before the coordinator returns to idle and replays a press.

### Data flow

```
DictationHotkey.press
  -> AppCoordinator.startRecording
     -> RecordingIndicator.show (edge glow, or the pill)
     -> AudioCapture.start (16 kHz mono Float32 buffers) — first, so the start cue is
        an honest "mic is hot"; buffers queue in CapturePreRoll until the analyzer exists
     -> RecordingCue.playStart
     -> FinalTranscriptInsertionSession captures focused target + selection
     -> Transcriber.start (SpeechAnalyzer + SpeechTranscriber module, correction vocabulary as speech context)
        -> CapturePreRoll hands over everything captured while it was starting
  // volatile partials update transcript state, RecordingIndicator, and eligible marked-text preview
DictationHotkey.release
  -> AppCoordinator.finishRecording
     -> AudioCapture.stop
     -> Transcriber.finalize -> String
     -> TranscriptCanonicalizer.canonicalize(finalText)   # correction layer, Shipped Since Baseline
     -> TranscriptDeterministicCleaner.streamClean(...)   # same conservative cleanup the HUD streamed
     -> FinalTranscriptInsertionSession verifies the shortcut-press target and writes once
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

### Hold-to-dictate shortcut

The default binding is fn. A menu recorder lets the user choose a supported modifier key or modifier-plus-key combination, and reset to fn. The binding persists across launches. Plain typing keys without a modifier are rejected. The recorder displays the candidate and applies it after its keys are released; Escape cancels. Recording a shortcut suspends dictation and clears deferred starts so the candidate cannot open a microphone session.

Use an active session keyboard event tap for modifier changes and key down/up. A matched combination consumes its key down, repeats, and corresponding key up, including a key up that follows modifier release, so the shortcut cannot type into the destination. Activation matches the configured modifiers; releasing the key or any required modifier ends the hold once. A 500 ms hardware check reconciles missed release events for the configured keys. Recover disabled taps and reinstall after Accessibility trust arrives. Deferred startup and recognizer-failure handling consult the configured binding's live held state. Input controls are disabled while a hold or finalization is active.

macOS Dictation also defaults to fn. Setup instructions explain how to disable that collision. Epos does not change system shortcut settings or promise that a chosen combination is free of conflicts with other applications. The initial binding and saved user choices are retained until the user changes them.

### Audio capture

`AVAudioEngine` input node tap at native input format, converted to 16 kHz mono Float32 with `AVAudioConverter` for the analyzer input. The shipped capture layer observes audio-engine configuration changes, rebuilds the input tap and converter, and attempts to resume capture. If recovery fails, it ends recording, preserves already recognized text, and shows "Mic lost". Seamless device switching is not established by unit tests and requires installed-app verification.

The menu microphone picker defaults to System default. Choosing an available input pins its persistent Core Audio UID for Epos, without changing the system-wide default. Resolve that UID to a live input device ID at every capture open and configuration-change recovery, then bind Epos's own I/O unit before installing the tap. A pinned input remains selected when another device, such as AirPods, becomes the system default. Reconnecting it may produce a new device ID, which must be resolved from the same UID. A missing pinned input blocks new capture with a visible unavailable state; loss during a hold follows the existing "Mic lost" path. It never falls back to another input. The picker retains the missing selection and offers System default and currently available inputs. The per-hold input choice is frozen alongside the capture mode. Enumeration and device binding preserve the long-lived audio engine.

### Recording indicator

A single `NSPanel` (borderless, non-activating, click-through, floats above all), rendered as a compact HUD:

- A status dot whose color signals state (idle / recording / finalizing).
- A live amplitude meter from the audio tap (RMS over a small window).
- One tail-truncated line of volatile transcript text while recording.
- A brief visible red notice whenever a dictation cannot complete normally, naming
  which stage failed: "Not inserted" (the shortcut-press target is no longer safe),
  "Mic lost" (the microphone died mid-hold), "Recognition lost" (the recognizer
  stopped mid-hold; what it heard first is still written at release), and
  "Not ready" (the session never started). Silence is never an acceptable outcome
  for a dictation the user held fn and spoke into.

The preview is memory-only and clears with the recording session. No persistent history, frontmost-app icon, waveform history, or draggable position. Centered above the active screen's bottom edge, fixed.

### Text injection

Inline preview uses the companion as an exclusive keyboard input method.
If Epos is already selected, adopt its actual activated client and underlying
keyboard layout without selecting or restoring another source. Keeping Epos
selected prepares native streaming while ordinary typing uses that layout.
Otherwise acquire it temporarily for the recording. Save the user's keyboard
source and underlying layout,
require actual companion activation for the captured client. Restore borrowed
input methods and failed acquisitions only if Epos still owns the current source.
Successful native commits acquired from a layout keep Epos and that layout selected. A source
selection return code alone does not authorize preview. If acquisition fails,
restore only a temporarily borrowed source and use the HUD and guarded final delivery.
No synthetic wake key or automatic startup input-source change is used.

An uninterrupted native input session owns its provisional draft without requiring
the host to return the exact string. Keep readable empty-selection checks,
concrete client and connection ownership, observed marked-range checks, and
readable text equality where available. Retire the session before ordinary input,
focus movement, source changes, controller teardown, or connection replacement.
Clear the owned draft before forwarding an interruption event. An event barrier
must run in the companion before Ghostty processes keyboard and mouse input;
an asynchronous cancellation from the main app is insufficient. Retired or
uncertain sessions cannot resume marking or authorize final delivery.

Do not acquire an unknown composition from another keyboard input method. An
already selected Epos source with an actual activated client and saved layout can
adopt unavailable initial marked metadata. Temporary acquisition starts from a
keyboard layout, or from a positively absent
composition; a positively observed foreign composition is always refused.
Unavailable marked metadata is acceptable on acquisition only after actual
exclusive Epos activation with an adopted layout or acquisition from a keyboard
layout. This is a native session
ownership contract, not normalization of an unavailable range to absence.
Concurrent additive input methods remain a verification limit.

Final delivery remains exactly once. A healthy owned composition is committed
in place, without clearing the visible utterance first. Small revisions near the
end are acceptable; disappearing and reinserting the whole utterance at release
is not. For a healthy composition, the app checks captured focus and the companion
authorizes the write using its concrete client, selection, marked range, readable
native draft and uninterrupted ownership. Accessibility text may contain generated
labels and layout characters that differ from native text, so it does not authorize
replacement of an owned native composition. Keystroke delivery still requires the
exact original Accessibility text and selection after confirmed preview cleanup.
Unavailable draft text alone does not require cancellation. A native commit
acknowledgement establishes acceptance, not independently verified terminal bytes.
Keep ambiguous-commit suppression for the acknowledged IME path. Unusable preview
channels retain guarded Unicode delivery after confirmed cleanup.

After a successful commit acquired from a keyboard layout, keep Epos selected
with that same underlying layout so release does not switch back to ABC and show
the system input-source indicator. Failed acquisition restores the prior source;
another input method or a source the user selects is preserved. When the standard
AX focused-element lookup returns no value, a bounded search of the frontmost
application's focused window may use an editable element whose AXFocused flag is
true. Missing, changed or ambiguous focus still refuses insertion.

The historical
[session prototype](preview-session-prototype.md) remains an experiment; its fresh
fixture, nonce, and background geometry gates do not belong in production.
Installed Ghostty verification must cover revised drafts, zero-byte cancellation,
one final payload, ordinary input, and retained or restored keyboard source before declaring
this redesign ready.

Backend: synthesized Unicode keyboard events (`KeystrokeTextInjector` → `CGEventKeyboardSetUnicodeString`), behind `TextInsertionBackend`. The authoritative final transcript is sent once without a shared clipboard. The Unicode payload is set on keyDown only (carrying it on keyUp double-types in Chromium/Electron); events come from a private-state source with cleared flags so the held fn modifier can't leak; long text is chunked on grapheme boundaries within the length the API carries reliably. Requires Accessibility permission.

The insertion session captures its target at shortcut press, before recording or asynchronous finalization can move focus. At release it verifies the same application and focused element. Before keystroke delivery, a readable Accessibility text context must retain the original value, caret, and selection. Healthy native composition commits instead use the companion's native selection, range, draft and session checks. It then inserts once or refuses completely. Epos never restores focus and never issues corrective backspaces. Long writes remain a sequence of ordered Unicode events rather than a transactional system edit, so signed-app verification must cover long text in Teams, terminals, and editors. A confirmed Ghostty terminal surface (`com.mitchellh.ghostty`, `AXTextArea`, help `Terminal content area`) exposes rendered screen contents and terminal selection rather than the command editor's input buffer. It uses the opaque focus, window, and target-identity guard, so screen redraws cannot masquerade as input edits. Ghostty search and rename fields, unconfirmed surfaces, and other editable fields keep exact text-context validation. Preview still requires readable selection and provable composition ownership; this terminal distinction does not waive those checks. The signed installer also installs the companion keyboard input method for preview and optional IME delivery. When it is unavailable, Epos uses the recording HUD and guarded keystroke delivery. A recording adopts a selected Epos source or acquires it for the hold. Successful native commits acquired from a layout retain Epos with that layout; failed acquisitions and borrowed input methods restore the prior source.

### Concurrency

- Audio capture on its dedicated `AVAudioEngine` thread.
- Transcription stream consumed on a `Task` owned by that hold's `RecordingSession`.
- UI updates marshaled to the main actor.
- `AppCoordinator` owns UI and readiness on the main actor; `RecordingSession` owns each hold's lifecycle on the main actor. Capture uses the audio-engine callback thread; the capture pre-roll and transcriber input handoff are bounded. Blocking socket and Electron Accessibility work use dedicated queues, and other AX readbacks run off the main actor. Ownership and cancellation must remain explicit across these boundaries.

### Logging

`os.Logger` for unified logging — one subsystem (`com.steez.Epos`), categories per module — mirrored to an app-owned, size-capped, rotated on-disk `DiagnosticLogSink` (see "Shipped Since Baseline"; it writes direct events to disk instead of polling the unified-log store). No ring buffer, no `StateHistory`.

Each recording also emits one parseable `reliability outcome` event. Outcomes distinguish setup failure, no audio input, recognizer failure, empty transcript, target refusal, backend refusal, delivery mismatch, AX-verified delivery, and accepted-but-unverified delivery. The event contains counts, booleans, outcome, and latency only. It does not contain transcript text. `scripts/audit` classifies stale logs that predate this event from their existing boundaries but labels inferred and incomplete results honestly.

### Settings

A single `UserDefaults`-backed struct stores the dictation shortcut, optional pinned microphone UID, launch at login, install locale, opt-in audio samples and correction evidence, opt-in speaker-audio rejection, inline preview (default on), and edge-glow styling. Missing or invalid shortcut data loads fn; an unset microphone follows System default. The menu bar exposes these settings except locale switching. See [settings.md](../docs/settings.md) for current defaults and application timing. Final-transcript cleanup has no setting: it is always on and deliberately conservative. Correction rules persist separately under their own `UserDefaults` key and are edited in the Corrections window.

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
- Hotkey reconciliation, audio conversion and buffering, indicator policy, and coordinator behavior have unit tests. Actual microphone, Speech, Accessibility, InputMethodKit, hotkey delivery, and target-app behavior require the installed signed app.
- Configurable input controls cover persistence, shortcut suppression and release ordering, deferred replay, recorder suspension, chosen microphone forwarding, missing pinned inputs, and UID resolution on recovery. Native device checks must establish binding/readback and an unchanged system default. Synthetic tests do not establish physical shortcut delivery or real device reconnection.

Keep tests tied to observable behavior and regression risk. A test count alone does not establish quality; opt-in corpus harnesses also do not prove current live delivery.

## Repository

This repo is the greenfield rebuild now named Epos. The prior SteezFlow implementation lives at `~/Projects/Personal/steezflow` (99 Swift files, 28 specs, 16.7K LOC) and stays on disk as reference only — not a dependency, not a submodule, not something this repo imports from. The only v1 code worth porting verbatim is the fn-key monitor and the original paste injector (since replaced by synthesized-keystroke insertion), both small enough to retype. v1 remains available until this rebuild is daily-driver stable.

## Acceptance — Baseline Done

All of:

- Holding fn while a text field is focused produces the spoken text in that field on release, end-to-end, in under 500 ms after release for a 10-second utterance.
- Indicator appears within 100 ms of shortcut press, transitions to finalizing immediately on release, and disappears only after insertion or a visible failure result.
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
8. Audio device switching. Configuration-change recovery and a persistent input picker are implemented. The picker pins Epos by device UID; physical disconnect recovery and voice-processing routing still need live verification.
9. Agent-specific modes (Codex / Claude Code / Cursor).
10. ~~Custom hotkey binding UI.~~ Implemented as a hold-to-dictate recorder, with fn retained as the default. Native keyboard and recorder focus behavior still need installed-app verification.
11. ~~Target-aware insertion guard: capture the shortcut-press target and refuse final insertion if focus, field value, caret, or selection changes before release.~~ **Shipped** (see "Shipped Since Baseline").
12. ~~Built-in correction re-seed on upgrade.~~ **Shipped** with versioned introduction metadata. An upgrade appends only built-ins introduced after the saved dictionary version, so a rule intentionally removed from that saved version stays removed.

Each is a separate spec when its turn comes. None block the baseline.
