# Epos documentation

Epos is a macOS menu bar dictation app. Hold fn to record, watch the provisional
transcript, then release to deliver the cleaned final text to the captured field.
Apple Speech performs recognition on the device. The feature pages below describe
the implementation in `Sources/` and its regression coverage in `Tests/`.

Start with [development](development.md) for repository rules and verification,
or [setup](setup.md) for installation and permissions. [The baseline
specification](../specs/baseline.md) governs scope and architecture.
[The specification index](../specs/README.md) points to design decisions and
historical experiments. Confirm behavior in source before changing it.

## Feature index

| Feature | Documentation |
| --- | --- |
| Installed app, signing, first launch, Privacy shortcut | [Setup](setup.md) |
| Microphone, Speech Recognition, Accessibility, speech asset readiness | [Setup](setup.md#permissions-and-readiness) |
| Hold fn, release, deferred presses, missed release recovery | [Dictation](dictation.md#push-to-talk) |
| Microphone conversion, startup audio, input device recovery | [Dictation](dictation.md#audio-and-recognition) |
| Ignore speaker audio | [Dictation](dictation.md#ignore-speaker-audio) |
| On-device recognition, locale, vocabulary context | [Dictation](dictation.md#audio-and-recognition) |
| Final cleanup of fillers, stutters, and ordinals | [Dictation](dictation.md#transcript-cleanup) |
| Stream into field, marked text, companion input method | [Insertion](insertion.md#stream-into-field) |
| Captured target guard, final IME commit, Unicode keystrokes | [Insertion](insertion.md#final-delivery) |
| Refused writes and delivery verification | [Insertion](insertion.md#delivery-evidence) |
| Corrections editor, Literal and Name modes, developer tokens | [Corrections](corrections.md#dictionary-and-editor) |
| Dictionary upgrades and protected storage | [Corrections](corrections.md#persistence) |
| Learn corrections, observed edits, suggestion review | [Corrections](corrections.md#learning-and-suggestions) |
| Recording pill, live meter, start and release sounds, notices | [Recording feedback](recording-feedback.md) |
| Edge glow, intensity, thickness, color, Ember aura | [Recording feedback](recording-feedback.md#edge-glow) |
| Launch at login and saved preferences | [Settings](settings.md) |
| Quit and menu status | [Settings](settings.md#menu-actions) |
| Diagnostic logs and transcript timing | [Diagnostics](diagnostics.md#logs) |
| Save audio samples and local evidence storage | [Diagnostics](diagnostics.md#saved-audio-and-correction-evidence) |
| Reliability audit, corpus labeling, confirmation, benchmarks | [Diagnostics](diagnostics.md#evaluation-tools) |

## Replacement readiness

These pages establish what the source implements. They do not certify the current
installed app, grants, companion registration, or delivery into specific apps.
Replacing Wispr Flow requires a current installed app run through the target apps
used for daily work, including long text, selections, focus changes, rapid holds,
and microphone changes. Use the [verification workflow](development.md).

The [baseline acceptance criteria](../specs/baseline.md#acceptance--baseline-done)
also require measured release latency, cue latency, memory, startup time, clean
quit, and 50 consecutive recordings. Passing the test suite alone does not
establish those results. Historical benchmark documents retain their original
dates and corpus assumptions.

## Scope boundaries

Push-to-talk, one configured locale, deterministic cleanup, and personal
corrections are the current product path. Toggle recording, transcript history,
locale switching UI, cloud fallback, and a custom hotkey UI remain outside the
baseline. The local LLM polish stage was removed after evaluation. See the
[backlog](../specs/baseline.md#backlog-post-baseline) before adding capabilities.
