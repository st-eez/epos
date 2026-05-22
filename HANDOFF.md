# HANDOFF — SteezFlow Baseline Rebuild

Pickup brief for a fresh Claude Code session in this repo. Greenfield rebuild of SteezFlow on Apple's `SpeechTranscriber` (macOS 26+).

## First Action

Read `specs/baseline.md` (the spec — source of truth) and `CLAUDE.md` (workflow), then start implementing TODOs in the source skeletons. **Done when:** all `// TODO` markers in `Sources/SteezFlow/` are replaced with real implementations and the acceptance criteria at the bottom of `specs/baseline.md` are met.

## State at Handoff

- Branch `main`, 2 commits, working tree clean.
- `swift build` green, `swift test` 4/4 passing, `swiftlint` 0 violations.
- 10 source skeletons + executable shim. Each module has the public surface from the spec with `// TODO` bodies.

```
Sources/SteezFlow/
  App/{SteezFlowApp,AppCoordinator}.swift
  Permissions/PermissionsGate.swift
  Speech/{AssetManager,Transcriber}.swift
  Audio/AudioCapture.swift
  Hotkey/FnHotkey.swift          # real, not a stub
  UI/{RecordingIndicator,MenuBarView}.swift
  Inject/TextInjector.swift      # real, not a stub
Sources/SteezFlowMacApp/main.swift  # @main shim
Tests/SteezFlowTests/SmokeTests.swift  # 4 smoke tests
```

## Implementation Order

Independent slices first, wiring last:

1. **`PermissionsGate`** and **`AssetManager`** — independent, do in parallel. Permissions handles mic/speech/accessibility prompts. AssetManager handles `AssetInventory` reserve + download for the install locale.
2. **`Transcriber`** + **`AudioCapture`** — paired. Audio feeds buffers, Transcriber consumes them via `SpeechAnalyzer`. Build them together so the buffer format contract stays consistent.
3. **`AppCoordinator`** — wires everything. State machine is already sketched (`idle`/`recording`/`finalizing`); fill in the TODO bodies in `startRecording`/`finishRecording`.
4. **UI polish** — `RecordingIndicator` needs window-positioning (centered above bottom edge of active screen), `MenuBarView` may need permission-status surfacing.

`TextInjector` and `FnHotkey` are already real — only touch them if a bug surfaces.

## Build / Test / Lint

```sh
swift build          # library + executable
swift test           # smoke tests (and real tests as you add them)
swiftlint            # config: .swiftlint.yml (copied from v1)
xcodegen generate    # produces SteezFlow.xcodeproj when you need permission-gated runtime testing
```

The Xcode project is gitignored — regenerate from `project.yml` on demand. `xcodegen` install: `brew install xcodegen`.

## Gotchas / Non-Obvious Decisions

- **macOS 26+ only.** Use `SpeechAnalyzer` + `SpeechTranscriber` module — *not* `SFSpeechRecognizer`, *not* `DictationTranscriber`. The bakeoff at `~/Projects/Personal/steezflow/specs/local-transcription-direction.md:82` is what justified this choice.
- **`AssetInventory` reservation is process-scoped.** Download persists on disk, but reservation does not — `AssetManager.prepare()` must run on every app launch.
- **Build a fresh `SpeechAnalyzer` + `SpeechTranscriber` per recording.** Do not reuse across sessions.
- **Audio format: 16 kHz mono Float32.** Use `AVAudioConverter` from the input node's native format. Tap on `engine.inputNode`, convert in the tap callback, emit via `onBuffer`.
- **Swift 6 strict concurrency is on.** `FnHotkey` is already `@MainActor` because the NSEvent monitor callback fires off-main and needs to hop. Same pattern for any new code that crosses thread boundaries — use `Task { @MainActor in … }` or mark the type `@MainActor`.
- **macOS system dictation collision.** The fn key normally triggers macOS dictation too. The user (steez) has already disabled it in System Settings → Keyboard → Dictation → Shortcut → "Off". No in-app detection needed; just document it in README (already done).
- **Permissions required at runtime:** Microphone, Speech Recognition, Accessibility (for paste). Info.plist + entitlements already have the strings/keys; the prompts fire when you call `PermissionsGate.requestAll()` for the first time.
- **No sandbox.** Accessibility-based paste requires it off, and there's no App Store target.

## Load-Bearing Non-Goals — Do NOT Add

These were explicitly cut from v1 and live in the post-baseline backlog at the bottom of `specs/baseline.md`. Do not add them without an updated spec:

- Personal dictionary / custom vocabulary
- LLM grammar polish (MLX/Qwen3 etc.)
- Filler-word detector
- Persistent transcription history
- Multiple model choices in settings
- Multi-locale switching UI
- Toggle / hands-free recording mode (push-to-talk only in baseline)
- Cloud transcription fallback
- Deterministic developer-token rewriter (`"dash dash"` → `--`) — this is #1 in the backlog, not v2 baseline
- Custom hotkey binding UI
- Agent-specific modes (Codex / Claude Code / Cursor)

If you find yourself wanting to add one of these to make a TODO "complete," stop — you're scope-creeping. Implement the bare baseline first.

## Acceptance — Baseline Done

Concrete numbers from `specs/baseline.md`:

- Holding fn while a text field is focused produces the spoken text on release, end-to-end, in under 500 ms after release for a 10-second utterance.
- Indicator appears within 100 ms of fn press, disappears within 100 ms of release.
- Idle RSS under 50 MB after 5 minutes; transcribing RSS under 100 MB.
- Cold launch to "ready for first recording" under 2 seconds (excluding first-run asset download).
- App quits cleanly with no leaked audio engine or analyzer.
- Survives 50 consecutive recordings without restart.

## Reference Repo

The prior implementation lives at `~/Projects/Personal/steezflow` as **reference only**, not a dependency. Two pieces worth glancing at if you get stuck:

- `Sources/SteezFlow/Hotkey/HotkeyManager.swift:184` — fn-key NSEvent monitor pattern. Already ported into `Sources/SteezFlow/Hotkey/FnHotkey.swift` in this repo.
- `Sources/SteezFlow/Core/Injection/` — v1's text injection. Already ported (and stripped) into `Sources/SteezFlow/Inject/TextInjector.swift`.

Do not port anything else. The v1 codebase is 16.7K LOC and most of it is the complexity we're escaping.

## When You're Done

Delete this file (`HANDOFF.md`) — it's a session pickup artifact, not product documentation.
