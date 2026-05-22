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
# 1. Build via SwiftPM
swift build

# 2. Lint
swiftlint

# 3. Regenerate Xcode project after adding files or changing project.yml
xcodegen generate

# 4. Build the .app bundle in Xcode for permission-gated testing
open SteezFlow.xcodeproj
```

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
