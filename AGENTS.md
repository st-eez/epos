# SteezFlow Claude Instructions

## Hard Rules

- Never hardcode PII, secrets, API keys, credentials, or machine-specific absolute paths.
- Resolve paths through `$HOME`, `__dirname`, `__filename`, or `pathlib.Path(__file__)`.
- Keep this file concise. Put detailed guidance in `specs/` and link to it.
- Specs are design docs, not proof. Verify behavior in `Sources/` and `Tests/` before editing.

## Source of Truth

`specs/baseline.md` is the spec. Before changing architecture, scope, or adding a feature, re-read it. If the work doesn't fit, update the spec first.

Architecture in one line: fn key → AudioCapture → Transcriber (Apple SpeechTranscriber) → TextInjector. Coordinator wires them. UI shows live partial. Nothing else.

## Non-Goals

These are explicitly out of scope for the baseline. Do not add them without an updated spec:

- Personal dictionary, LLM polish, filler-word detector
- Persistent history, multiple model choices, multi-locale switching UI
- Toggle/hands-free mode (push-to-talk only in baseline)
- Cloud transcription fallback
- Custom hotkey binding UI

The full backlog is at the bottom of `specs/baseline.md`.

## Development Workflow

```sh
# 1. Library + tests (SPM does NOT build an executable; see "Build Topology" below)
swift build -Xswiftc -warnings-as-errors    # default `swift build` lets Swift 6 concurrency warnings through
swift test                                   # 4 smoke tests; should stay green
swiftlint --quiet                            # silent = clean

# 2. Installed signed .app — required for permission-gated work (mic, speech, AX)
scripts/build-signed-app.sh
scripts/install-signed-app.sh
open /Applications/SteezFlowMacApp.app
```

E2E (mic / speech / accessibility / fn key / paste) requires the installed signed `.app`. macOS does not persist TCC grants for `swift run` executables, and launching a DerivedData `.app` can leave `/Applications/SteezFlowMacApp.app` stale. Treat raw `xcodebuild` as compile verification only; install before launching for app behavior.

## Build Topology — Do Not Re-introduce the Trap

- `Package.swift` defines ONLY the `SteezFlow` library + `SteezFlowTests` test target. No executable target. Adding one back collides with the xcodegen `application` target (same name, same path) and produces a raw Mach-O at `Build/Products/Debug/SteezFlowMacApp` instead of a `.app` bundle.
- `project.yml` is the source of truth for `Info.plist` keys and entitlements. They live under `info: properties:` and `entitlements: properties:`. Bare `path:` forms cause xcodegen to overwrite the on-disk files with empty templates on every regenerate.
- `Resources/Info.plist` and `Resources/SteezFlow.entitlements` are generated artifacts. Edit `project.yml` and regenerate; don't hand-edit the plists.
- `scripts/install-signed-app.sh` is the source of truth for the runnable app. It builds into `.build/xcode`, verifies a non-ad-hoc signature, copies to `/Applications/SteezFlowMacApp.app`, and verifies the installed bundle. Do not open DerivedData builds for runtime testing.

## Apple Speech API Source of Truth

Apple's developer.apple.com pages for `SpeechAnalyzer`, `SpeechTranscriber`, and `AssetInventory` are JS-rendered and opaque to WebFetch. The reliable surface is the SDK swiftinterface:

```
/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk/System/Library/Frameworks/Speech.framework/Versions/A/Modules/Speech.swiftmodule/arm64e-apple-macos.swiftinterface
```

Grep it before assuming any symbol exists. macOS 26+ only — no `if #available` guards needed.

## Logging

Use `SteezFlowLogger` so each event goes to Apple unified logging and the app-owned diagnostic log under `~/Library/Caches/SteezFlow/logs/`. Subsystem `com.steez.SteezFlow`. Categories per module: `coordinator`, `permissions`, `assets`, `transcriber`, `audio`, `menubar`.

Use `log stream` only as a manual, bounded debugging command; do not leave it running as a background capture rig:

```sh
/usr/bin/log stream --predicate 'subsystem == "com.steez.SteezFlow"' --info --debug
```

Diagnostic log events must stay privacy-aware: no transcript text, PII, secrets, or environment-specific values.

## Code Change Rules

- Search narrowly first: `fd` for paths, `rg` for content, `rg --files` for file lists.
- Validate at system boundaries; no fallbacks for impossible internal states.
- Tests cover behavior or regression risk, not constants or ignored inputs.
- Remove unused code directly; no compatibility shells or placeholder wrappers.
- If a module pushes the file past ~250 LOC, you're probably doing too much in it. Split or cut scope.

## Git

- Commit completed agent-made changes as rollback points; never commit partial, unrelated, secret, env, or credential changes.
- Before committing, inspect `git status`, `git diff`, and `git log -5 --oneline`; stage only task-relevant files.
- Do not push, force push, hard reset, amend, discard changes, or update git config unless explicitly asked.
