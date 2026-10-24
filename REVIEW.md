# Epos review

## What to check

`Sources/Epos/Audio/` captures production microphone input. Review checks
render-thread safety, bounded buffering, format conversion,
route recovery, and draining the last captured frames on release.

`Sources/Epos/UI/RecordingCue.swift` plays production recording cues. Review
checks callback latency and ordered playback.

`Sources/Epos/Inject/` is production code that authorizes writes into other
applications. Review checks target identity, focus
changes, composition ownership, and suppression of duplicate writes.

- Deep: `probes/inline-preview/install`, which changes the installed input
  method and its live client sessions. Verify it in the target application
  after installation.

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

Ready-check questions 5 and 1 (4 and 5 before 2026-10-23) should have caught
this gap. When an installation
replaces the companion, verify acquisition and visible streaming in the installed
target app without manually priming its native client first. Registration,
selection, and a successful test before replacement do not cover that handoff.
