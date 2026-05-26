# Epos

Minimal macOS dictation app built on Apple's `SpeechTranscriber`. Hold fn, speak, release — the text pastes into the frontmost app.

Source of truth: `specs/baseline.md`.

## Requirements

- macOS 26.0 or later (uses `SpeechAnalyzer` + `SpeechTranscriber`, introduced in macOS 26).
- Apple Silicon.
- Xcode 17+ (for Swift 6.0 toolchain).
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) for generating the Xcode project: `brew install xcodegen`.

## Build

```sh
# Library target via SwiftPM
swift build

# Build a signed .app bundle. The script infers DEVELOPMENT_TEAM when one
# Apple Development team is available; otherwise set it in your local shell.
scripts/build-signed-app.sh

# Install the signed app to /Applications for the stable runtime/TCC target.
scripts/install-signed-app.sh
```

## Free Local Install

This path does not require a paid Apple Developer Program account. It builds
the app from source on the user's Mac, signs it locally, and installs it into
`/Applications`.

```sh
brew install xcodegen
scripts/install-local-app.sh
open /Applications/Epos.app
```

`scripts/build-local-app.sh` prefers an Apple Development certificate when one
is available. That certificate can be created with a free Apple ID in Xcode. If
none is available, the script falls back to an ad-hoc local signature.

For Homebrew tap distribution, use the source-build formula template in
`packaging/homebrew/`.

## Contributor Workflow

The build and install commands stay the same when editing normal app code under
`Sources/`, `Tests/`, or `Resources/`.

```sh
swift build -Xswiftc -warnings-as-errors
swift test
swiftlint --quiet
scripts/install-local-app.sh
```

Update the build or distribution instructions only when changing build
infrastructure: `Package.swift`, `project.yml`, app entitlements, required
tools, deployment target, signing behavior, install scripts, or Homebrew
packaging.

## First-Run Setup

1. Launch only `/Applications/Epos.app`, not a DerivedData copy.
2. Grant Microphone, Speech Recognition, and Accessibility permissions when prompted.
3. The app downloads the SpeechTranscriber locale asset on first launch (one-time).
4. **Disable macOS system dictation** so the fn key doesn't trigger two listeners at once: System Settings → Keyboard → Dictation → Shortcut → "Off".

## Architecture

See `specs/baseline.md` for the full spec. Ten source modules, ~2K LOC ceiling:

```
Sources/Epos/
  App/{EposApp,AppCoordinator}.swift
  Permissions/PermissionsGate.swift
  Speech/{AssetManager,Transcriber}.swift
  Audio/AudioCapture.swift
  Hotkey/FnHotkey.swift
  UI/{RecordingIndicator,MenuBarView}.swift
  Inject/TextInjector.swift
```

## Status

Scaffolded. All modules are compilable stubs with TODOs marking the real work. See `specs/baseline.md` Acceptance section for the done-bar.
