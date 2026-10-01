# Development and verification

Return to the [feature index](readme.md). Shared repository instructions live in
[AGENTS.md](../AGENTS.md).

## Build and tests

Use Apple Silicon, macOS 26 or later, Xcode with the macOS 26 or newer SDK,
XcodeGen, and SwiftLint. Run from the repository root.

```sh
swift build -Xswiftc -warnings-as-errors
swift test
swiftlint lint --quiet --no-cache
scripts/audit --self-test
probes/inline-preview/verify
```

The Swift suite includes behavior tests and opt-in evaluation harnesses. The
`EPOS_RUN_*` harnesses can skip when their fixtures or permissions are absent.
Record skipped checks separately from successful runtime verification. Tests
disable diagnostic file logging and real indicator windows.

The companion verification command builds that separate target with warnings as
errors and runs native text-view safety checks. The corpus, confirmation,
labeling, and migration CLIs expose deterministic checks through `--test`.

## Installed app

Follow [setup](setup.md) for installation, signing options, companion registration,
and permissions. Runtime verification requires the installed signed app identity.
Do not launch a DerivedData copy for runtime testing. Raw `xcodebuild` and Swift
Package Manager establish compilation; microphone, Speech, Accessibility, fn-key,
InputMethodKit, and delivery require installed-app checks.

## Build topology

- [Package.swift](../Package.swift) defines the Epos library and EposTests only.
  An executable target would collide with the Xcode application target.
- [project.yml](../project.yml) defines the app target, Info.plist properties,
  entitlements, deployment target, and hardened runtime. Edit it and regenerate
  with `xcodegen generate`; the files in `Resources/` are generated artifacts.
- Signed builds live under `.build/xcode`. The signed installer is the source
  of truth for the runnable app and stable TCC identity.
- The companion currently lives in [probes/inline-preview](../probes/inline-preview/README.md).
  See [insertion](insertion.md) for preview, IME delivery, and fallback behavior.

## Apple Speech API

Check the installed SDK's Swift interface before assuming a symbol exists.
Discover the active SDK instead of pinning a developer machine or SDK version.

```sh
epos_sdk_path=$(xcrun --sdk macosx --show-sdk-path)
rg 'SpeechAnalyzer|SpeechTranscriber|AssetInventory' \
  "$epos_sdk_path/System/Library/Frameworks/Speech.framework/Versions/A/Modules/Speech.swiftmodule/arm64e-apple-macos.swiftinterface"
```

macOS 26 is the deployment floor. No availability guard is needed for a symbol
introduced at that floor.

## Logging and investigation

Read [diagnostics](diagnostics.md) before changing logging or interpreting
recording evidence. It covers `EposLogger`, log inspection, transcript privacy,
reliability auditing, and evaluation tools.

## Runtime acceptance

Before claiming Epos can replace another dictation app, verify a current signed
installation in the actual target apps. Cover short and long holds, selection
replacement, focus movement, consecutive recordings, preview degradation,
permissions, and microphone route changes. Check that failed delivery is visible
and does not modify a different field. Measure latency and resource use against
the [baseline acceptance criteria](../specs/baseline.md#acceptance--baseline-done).
Unit tests cannot establish those macOS integration outcomes.
