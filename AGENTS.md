# Epos shared agent instructions

Start feature work at [docs/readme.md](docs/readme.md), then read the relevant
feature page and its linked source, tests, and design records.

Read [docs/development.md](docs/development.md) for build,
signing, verification, logging, and project generation rules.

[specs/baseline.md](specs/baseline.md) governs product scope. Re-read it before
changing architecture or adding a feature, and update it first when the work
changes that scope. Verify behavior in `Sources/` and `Tests/`; specs and old
review reports are evidence to check, not proof of current behavior.

The dictation path is fn hold, microphone capture, Apple SpeechTranscriber,
deterministic corrections and cleanup, then one guarded final insertion.
Inline preview uses the companion input method's marked text. Final delivery
uses an acknowledged IME commit when eligible, otherwise Unicode keystrokes.

## Rules

- Never hardcode PII, secrets, credentials, or machine-specific absolute paths.
  Resolve user paths from the home directory and repository paths from the file
  or script location. Discover the active SDK through `xcrun`.
- Read `~/.steez/repo/docs/code-design.md` when designing code or changing
  structure or behavior. Follow `~/.steez/repo/docs/writing.md` for writing.
- Search narrowly with `rg` or `rg --files`. Validate system boundaries and
  remove unused code directly. Tests should cover behavior and regression risk.
- Split by responsibility when a module becomes hard to reason about. Avoid
  mechanical file splits and speculative abstractions.
- Keep these instructions concise. Put feature details in `docs/` and design
  decisions in `specs/`, and update the index when either changes.
- Keep push-to-talk, one locale, on-device transcription, and current scope.
  History, toggle mode, custom bindings, model selection, and cloud fallback
  require an updated spec. LLM polish was removed after benchmarking.

## Git

Commit completed task changes as rollback points. Before committing, inspect
`git status`, `git diff`, and `git log -5 --oneline`, and stage only relevant
files. Never commit partial, unrelated, secret, environment, or credential
changes. Do not push, force push, hard reset, amend, discard changes, or change
Git configuration unless Steve explicitly asks.
