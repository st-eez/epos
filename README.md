# Epos

Epos is an on-device dictation app for Apple Silicon Macs running macOS 26 or
later. Hold fn to record, see volatile text in the field or recording HUD, and
release to insert the cleaned final transcript once into the captured field.
Apple SpeechTranscriber handles recognition. Deterministic correction rules
handle personal vocabulary and spoken developer symbols.

Start at [docs/readme.md](docs/readme.md) for every shipped feature, its source,
tests, defaults, and design records. [AGENTS.md](AGENTS.md) contains contributor
rules, and [specs/baseline.md](specs/baseline.md) governs scope and backlog.

## Install from source

Install Xcode with the macOS 26 or newer SDK and XcodeGen. A free Apple ID can
provide an Apple Development certificate through Xcode.

```sh
brew install xcodegen
scripts/install-signed-app.sh
open /Applications/Epos.app
```

Grant Microphone, Speech Recognition, and Accessibility permissions. The app
prepares the locale asset on first launch. Disable the macOS Dictation fn
shortcut in System Settings, Keyboard, Dictation.

For a local install with an ad-hoc signing fallback, use
`scripts/install-local-app.sh`. See [development.md](docs/development.md) for
the signing and companion differences, build commands, and runtime checks.

## Status

The repository contains dictation, guarded final delivery, inline preview,
corrections, conservative cleanup, recording cues, and local diagnostic and
evaluation tools. Source and unit tests establish implementation behavior.
Replacing an existing dictation app also requires current signed-app verification
in the apps you use. See the [feature index](docs/readme.md) for evidence and
known limitations.
