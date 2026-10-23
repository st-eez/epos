# Epos review

## Deep

`Sources/Epos/Audio/` captures production microphone input. Changes require Deep
review, including render-thread safety, bounded buffering, format conversion,
route recovery, and draining the last captured frames on release.

`Sources/Epos/UI/RecordingCue.swift` plays production recording cues. Changes
require Deep review, including callback latency and ordered playback.

`Sources/Epos/Inject/` is production code that authorizes writes into other
applications. Changes require Deep review, including target identity, focus
changes, composition ownership, and suppression of duplicate writes.

`probes/inline-preview/install` changes the installed input method and its live
client sessions. Installer changes require Deep review and verification in the
target application after installation.

## Evidence

Use the checks in [development](docs/development.md). Distinguish simulated
Accessibility failures from live host failures, and native input-method delivery
from keystroke delivery. A successful focus lookup alone does not establish that
a recorded utterance reached its destination.

## Misses

On October 20, 2026, Steve reported missing Codex streaming after installing
`5385f6b`. Three recordings refused native acquisition with `input method
activation pending` and used final keystroke delivery. The readiness pass had
checked a previously activated Ghostty client before installation, followed by
bundle signatures and input-source registration after installation. Those checks
did not establish native client activation in Codex after the companion was
replaced. The cause of the missing activation remains unconfirmed.

Ready-check questions 4 and 5 should have caught this gap. When an installation
replaces the companion, verify acquisition and visible streaming in the installed
target app without manually priming its native client first. Registration,
selection, and a successful test before replacement do not cover that handoff.
