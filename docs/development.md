# Development and verification

Return to the [feature index](readme.md). Product scope lives in
[baseline.md](../specs/baseline.md); current behavior is established by source,
tests, and installed-app observations.

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

Permission-gated verification requires the installed signed app. The preferred
development path uses an Apple Development certificate, including one obtained
with a free Apple ID in Xcode.

```sh
scripts/install-signed-app.sh
open /Applications/Epos.app
```

The installer builds the app, verifies a non-ad-hoc signature, installs it, and
builds and registers the inline-preview companion. Quit Epos before installing.
Do not launch a DerivedData copy for runtime testing. Raw `xcodebuild` and Swift
Package Manager establish compilation, not microphone, Speech, Accessibility,
fn-key, InputMethodKit, or delivery correctness.

`scripts/install-local-app.sh` supports a free local source install with an
ad-hoc fallback when no development certificate is available. Permission grants
can be less stable across those rebuilds. This installer currently installs only
the main app, so inline preview requires a separate companion install. Read
[insertion and inline preview](insertion.md) before testing that route.

First launch requires Microphone, Speech Recognition, Accessibility, and the
on-device locale asset. Disable the macOS Dictation fn shortcut in System
Settings, Keyboard, Dictation, so the two listeners do not collide.

## Build topology

- [Package.swift](../Package.swift) defines the Epos library and EposTests only.
  An executable target would collide with the Xcode application target.
- [project.yml](../project.yml) defines the app target, Info.plist properties,
  entitlements, deployment target, and hardened runtime. Edit it and regenerate
  with `xcodegen generate`; the files in `Resources/` are generated artifacts.
- Signed builds live under `.build/xcode`. The signed installer is the source
  of truth for the runnable app and stable TCC identity.
- The companion currently lives in [probes/inline-preview](../probes/inline-preview/README.md).
  It is a runtime dependency for preview and IME delivery, with a HUD and
  keystroke fallback when unavailable.

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

Use `EposLogger`. It writes unified logging under `com.steez.Epos` and an
app-owned diagnostic log under `~/Library/Caches/Epos/logs/`. Reuse the category
owned by the module. Recording IDs join capture, recognizer, preview, guard,
insertion, and terminal reliability events.

Start with `scripts/audit`, then inspect recording-scoped diagnostic events.
Historical logs before the test-sink fix contain synthetic test output. Missing
recording IDs, `app=nil`, and bursts without real recording boundaries are not
proof of user harm. Check dates and installed build provenance before attributing
an old log to current source.

Transcript timing text is redacted unless `EPOS_DIAGNOSTIC_TRANSCRIPT_TEXT=1`.
Reliability auditing prints metadata only. Keep transcript-bearing diagnostics
local and out of source control. Audio samples and correction evidence are
separate opt-in features.

Use unified log streaming only as a bounded manual debugging action.

```sh
/usr/bin/log stream --predicate 'subsystem == "com.steez.Epos"' --info --debug
```

## Runtime acceptance

Before claiming Epos can replace another dictation app, verify a current signed
installation in the actual target apps. Cover short and long holds, selection
replacement, focus movement, consecutive recordings, preview degradation,
permissions, and microphone route changes. Check that failed delivery is visible
and does not modify a different field. Measure latency and resource use against
the [baseline acceptance criteria](../specs/baseline.md#acceptance--baseline-done).
Unit tests cannot establish those macOS integration outcomes.
