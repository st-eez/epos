# Epos

Epos is a menu-bar, push-to-talk dictation app for macOS 26+. Hold the fn key and
speak: volatile recognition appears in Epos's HUD. Release fn and the authoritative
final transcript is inserted once into the field captured at fn press. Transcription
is fully on-device (Apple `SpeechTranscriber`).

`specs/baseline.md` is the spec and source of truth. Before changing architecture
or scope, re-read it; if the work doesn't fit, update the spec first. Scope is
deliberately narrow: the non-goals and backlog in `specs/baseline.md` are binding —
check them before adding any feature. Specs are design docs, not proof — verify
behavior in `Sources/` and `Tests/` before editing.

## How a dictation flows

```
FnHotkey                               (fn-only push-to-talk; hold to record)
    ↓  AudioCapture                    (48 kHz mic → 16 kHz mono PCM)
Transcriber                            (SpeechAnalyzer + SpeechTranscriber, en-US)
    ↓  volatile partials + growing per-segment finals
RecordingIndicator                    (memory-only volatile preview)
    ↓  fn release
TranscriptPolisher + Canonicalizer     (safe cleanup + deterministic jargon fix)
    ↓
FinalTranscriptInsertionSession       (verifies the fn-press field)
    ↓
TextInsertionBackend                  (one synthesized-keystroke write)
```

`AppCoordinator` owns the recording state machine and wires every stage; the menu
bar HUD shows volatile partials. Correction aliases are attached to the recognizer
as speech context, and the canonicalizer owns the authoritative final jargon fix.

The insertion session captures focus, readable value, caret, and selection at fn
press. Before the one final write it verifies that context is unchanged. Opaque
Electron targets use their process and focus signature. A mismatch writes nothing
and shows "Not inserted"; Epos never restores focus or issues corrective backspaces.

On fn release the coordinator finalizes. The optional `TranscriptPolisher`
(`polishEnabled`, default OFF) may rewrite the final transcript behind a
content-retention guard with an always-safe fallback — words are never lost.
`CorrectionDictionary` + `CorrectionEvidence` learn new aliases from the user's
post-dictation AX edits, gated by `CorrectionPromotionGate`.

---

## Development workflow

```sh
# 1. Library + tests (SPM does NOT build an executable; see "Build topology" below)
swift build -Xswiftc -warnings-as-errors    # default `swift build` lets Swift 6 concurrency warnings through
swift test                                   # full suite; must stay green
swiftlint --quiet                            # silent = clean

# 2. Installed signed .app — required for permission-gated work (mic, speech, AX)
scripts/build-signed-app.sh
scripts/install-signed-app.sh
open /Applications/Epos.app
```

- E2E behavior (mic / speech / accessibility / fn key / insertion) requires the
  installed signed `.app`. macOS does not persist TCC grants for `swift run`
  executables, and launching a DerivedData `.app` can leave `/Applications/Epos.app`
  stale. Treat raw `xcodebuild` as compile verification only.
- Insertion correctness is NOT unit-testable: verifying it means dictating with the
  installed app into real target apps. Unit tests drive the final-write guard through
  fake backends/observers (`Tests/EposTests/InsertionTargetGuardTests.swift`).
- Skipped tests are env-gated eval harnesses (`EPOS_RUN_*`) that replay saved
  dogfood recordings or call local models; they are opt-in, not broken.
- `scripts/bench [count]` installs a signed Debug app and runs the five-arm Apple
  preset comparison inside that app identity. It replaces `/Applications/Epos.app`.
- `scripts/audit` reports privacy-safe operational outcomes and the most complete
  signed labeled-corpus artifact. It keeps current schema-1 sessions separate from
  legacy inferred logs and never prints transcript text.
- `scripts/corpus` builds the provenance ledger for the frozen recording corpus
  (35 human-confirmed, 79 inferred, rest unlabeled). Only `human_confirmed` rows
  may back accuracy claims or correction promotion; see `specs/evaluation-corpus.md`.
- `scripts/correct <candidate.json>` evaluates one correction record against the
  frozen signed 114-row production arm. Until a human-confirmed holdout exists it
  rejects every promotion; then it requires zero confirmed-development and holdout
  regressions plus at least one holdout win.
- Current `swift test` processes disable the shared dogfood diagnostic sink. Older
  logs can still contain historical test bursts; `scripts/audit` partitions all
  pre-schema sessions as legacy instead of treating them as current evidence.

---

## Build topology — do not re-introduce the trap

- `Package.swift` defines ONLY the `Epos` library + `EposTests` test target. No
  executable target. Adding one back collides with the xcodegen `application`
  target (same name, same path) and produces a raw Mach-O at
  `Build/Products/Debug/Epos` instead of a `.app` bundle.
- `project.yml` is the source of truth for `Info.plist` keys and entitlements.
  They live under `info: properties:` and `entitlements: properties:`. Bare
  `path:` forms cause xcodegen to overwrite the on-disk files with empty templates
  on every regenerate.
- `Resources/Info.plist` and `Resources/Epos.entitlements` are generated
  artifacts. Edit `project.yml` and regenerate; don't hand-edit the plists.
- `scripts/install-signed-app.sh` is the source of truth for the runnable app: it
  builds into `.build/xcode`, verifies a non-ad-hoc signature, copies to
  `/Applications/Epos.app`, and verifies the installed bundle. Do not open
  DerivedData builds for runtime testing.

---

## Apple Speech API source of truth

Apple's developer.apple.com pages for `SpeechAnalyzer`, `SpeechTranscriber`, and
`AssetInventory` are JS-rendered and opaque to WebFetch. The reliable surface is
the SDK swiftinterface:

```
/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk/System/Library/Frameworks/Speech.framework/Versions/A/Modules/Speech.swiftmodule/arm64e-apple-macos.swiftinterface
```

Grep it before assuming any symbol exists. macOS 26+ only — no `if #available`
guards needed.

---

## Logging

Use `EposLogger` so each event goes to Apple unified logging AND the app-owned
diagnostic log under `~/Library/Caches/Epos/logs/` (one file per day). Subsystem
`com.steez.Epos`. One category per module — currently `coordinator`, `permissions`,
`assets`, `transcriber`, `audio`, `inject`, `corrections`, `dogfood`, `indicator`,
`reliability`. Reuse an existing category before inventing a new one.

The diagnostic log is the primary bug-investigation surface: every recording gets
a `recordingID`, and insertion logs each final-write decision. It is a local
dogfood/debug surface and may include transcript text when the transcript is the
behavior under test.

`log stream` is a manual, bounded debugging command only — never leave it running
as a background capture rig:

```sh
/usr/bin/log stream --predicate 'subsystem == "com.steez.Epos"' --info --debug
```

---

## Rules

- Never hardcode PII, secrets, API keys, credentials, or machine-specific absolute
  paths. Resolve paths through `$HOME`, `__dirname`, or `pathlib.Path(__file__)`.
- Keep this file an orientation map; detailed guidance lives in `specs/`.
- Search narrowly first: `fd` for paths, `rg` for content.
- Validate at system boundaries; no fallbacks for impossible internal states.
- Tests cover behavior or regression risk, not constants or ignored inputs.
- Remove unused code directly; no compatibility shells or placeholder wrappers.
- Before adding to a file over ~1000 lines, state its single responsibility in one
  sentence; if you can't, split along that sentence boundary instead of growing
  it. Never split mechanically just to satisfy the number.

## Git

- Commit completed agent-made changes as rollback points; never commit partial,
  unrelated, secret, env, or credential changes.
- Before committing, inspect `git status`, `git diff`, and `git log -5 --oneline`;
  stage only task-relevant files.
- Do not push, force push, hard reset, amend, discard changes, or update git
  config unless explicitly asked.

---

## Key files

| File | Role |
|------|------|
| `App/AppCoordinator.swift` | Recording state machine; wires audio → speech → insertion |
| `App/Settings.swift` | Persisted settings (`polishEnabled`, …) |
| `Hotkey/FnHotkey.swift` | fn-key push-to-talk monitor |
| `Audio/AudioCapture.swift` | Mic capture + resample to 16 kHz mono |
| `Audio/DogfoodTap.swift` | Per-recording WAVs for replay evals |
| `Speech/Transcriber.swift` | SpeechAnalyzer/SpeechTranscriber session lifecycle |
| `Speech/AssetManager.swift` | On-device model asset install/availability |
| `Speech/TranscriptCanonicalizer.swift` | Deterministic correction layer (jargon aliases, spoken symbols) |
| `Speech/Correction*.swift` | User-editable alias dictionary; learns from AX edit evidence |
| `Speech/TranscriptPolisher*.swift`, `*Polish*.swift` | Opt-in LLM polish: engines, guard, prompts, fallback |
| `Speech/TranscriptDeterministicCleaner.swift` | Guard-proven hard-filler cleanup (polish fallback path) |
| `Inject/FinalTranscriptInsertion.swift` | Captures the fn-press target; issues at most one final write |
| `Inject/InsertionTargetGuard.swift`, `InsertionTargetFocusSignature.swift` | AX safety: final target/value/caret/selection validation |
| `Inject/TextInsertionBackend.swift` | Keystroke synthesis backend |
| `Permissions/PermissionsGate.swift` | Mic / speech / accessibility TCC gating |
| `Diagnostics/EposLogger.swift` | Unified logging + app-owned diagnostic file log |
| `Diagnostics/ReliabilityDiagnostics.swift` | Privacy-safe terminal recording outcome for `scripts/audit` |
| `UI/MenuBarView.swift`, `UI/RecordingIndicator*.swift`, `UI/Correction*.swift` | Menu bar, recording indicator, corrections editor |
