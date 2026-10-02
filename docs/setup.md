# Setup

For build commands and project generation rules, see [development](development.md).

## Install

Use an Apple Development certificate for development. One can be obtained with a
free Apple ID in Xcode. Quit the running Epos app and run from the repository root:

```sh
CONFIGURATION=Release scripts/install-signed-app.sh
open /Applications/Epos.app
```

Release enables compiler optimizations for daily use. The build script defaults
to Debug for development; the signed saved-audio evaluation hosts require that
configuration. Use `CONFIGURATION=Debug` when running those evaluations.

The installer builds with a team signature, verifies a fresh staged bundle,
replaces the installed app, and installs the inline preview companion. It restores
the prior bundle if replacement fails. First registration of the companion can
require a logout or input source consent.
The app can use its recording pill while the companion is unavailable.

The free source install command is `scripts/install-local-app.sh`. It prefers an
Apple Development certificate and can use an ad-hoc signature when none is
available. Permission grants can be less stable across rebuilds with that
signature. This installer does not install the companion. Its fallback dictation
path is the recording pill followed by guarded Unicode keystrokes.

The app targets macOS 26 or later. Disable the macOS Dictation fn shortcut in
System Settings, Keyboard, Dictation so the same hold does not activate two
dictation systems. Epos has one fn binding and no remapping UI.

## Permissions and readiness

At launch, Epos requests Microphone, Speech Recognition, and Accessibility. It
prepares and reserves the configured locale's Apple speech asset, then resolves
the analyzer's preferred capture format. The default locale is `en-US`; the menu
displays it without a locale switcher.

The menu shows permission tiles and a readiness banner. Microphone, Speech
Recognition, and Accessibility use `OK`, `Blocked`, or `Needed`. Pipeline
blockers distinguish an installing or missing model, missing grants, and a speech
engine that resolved no capture format. Asset installation has no progress bar.

A blocked pipeline is rechecked when the menu opens or fn is pressed. This
recheck reads grants and asset status without presenting new prompts or starting
a missing model download. A newly granted Accessibility permission causes the
fn monitor to be reinstalled when the app observes the grant while idle.

The Privacy button opens System Settings. Grant changes and asset readiness are
live system state; an existing source checkout says nothing about the grants of
the installed bundle.

## Evidence

Implementation lives in [StartReadinessProbe](../Sources/Epos/App/StartReadinessProbe.swift),
[PermissionsGate](../Sources/Epos/Permissions/PermissionsGate.swift),
[AssetManager](../Sources/Epos/Speech/AssetManager.swift), and
[MenuBarView](../Sources/Epos/UI/MenuBarView.swift).
[StartReadinessTests](../Tests/EposTests/StartReadinessTests.swift) and
[CoordinatorBootstrapLatchTests](../Tests/EposTests/CoordinatorBootstrapLatchTests.swift)
cover blocker wording, permission observation, and deferred startup using fakes.
Actual consent, model downloads, source registration, and fn event delivery
require installed app verification.

See [development](development.md), [dictation](dictation.md), and
[the companion instructions](../probes/inline-preview/README.md). The latter
also contains historical probe observations; runtime enablement now follows the
saved Stream into field setting.
