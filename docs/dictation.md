# Dictation

## Push-to-talk

Hold the configured shortcut with the destination field focused. The default is
fn; the menu's Shortcut recorder can change it. Epos opens the microphone, plays a
start sound after capture starts, and captures the destination's insertion
context. Release the shortcut to stop capture, play the release sound, finalize recognition,
and attempt one authoritative final write.

The coordinator moves through idle, recording, and finalizing. Each hold has
one RecordingSession that owns capture callbacks, startup audio, the analyzer
task, the frozen transcript transform, preview, insertion target and reliability
record. It closes those resources before the coordinator returns to idle.
Callbacks retained from a finished hold cannot update or feed a newer recording.
A press during bootstrap or finalization is deferred and replayed after readiness returns, only
if the configured shortcut remains held. Audio before the deferred recording starts is unavailable.
A release during analyzer startup stops the microphone immediately. The captured
startup audio reaches the analyzer before it is finalized, so a short spoken hold
can still produce a transcript.

The hotkey reads global modifier and key events through an active event tap.
Modifier-only shortcuts start when the configured modifiers match; combinations
start on the configured key-down with those modifiers. Releasing the key or a
required modifier ends the hold. Combination key events are consumed, including
repeats and the matching key-up. The tap schedules coordinator work outside its
callback. A hardware check every 500 ms recovers missed releases and clears
stale key suppression, including after secure input. Opening the shortcut
recorder cancels pending holds and suspends dictation.

## Audio and recognition

AudioCapture converts the input device's native PCM format to the format selected
by SpeechAnalyzer. A mono target explicitly selects channel zero from a
multichannel input. This handles the discrete channel layout produced by Apple's
voice processing without an implicit downmix to silence.

The microphone starts before asynchronous analyzer setup. A three second queue
preserves startup audio until the analyzer attaches. If setup exceeds that cap,
the queue discards the oldest audio and logs the truncation. The transcriber's
input queue also has a limit; overflowing it reports recognition failure.

A fresh SpeechAnalyzer and SpeechTranscriber serve each recording. The preset
requests volatile results, fast results, and confidence attributes. Recognition
uses the configured locale. The contextual vocabulary contains `Epos` and
pronounceable canonical dictionary entries, deduplicated and capped at 100.
Correction error aliases stay out of this bias list.

Volatile partials replace the current segment's provisional tail. Final segments
accumulate. The recording's correction rules and cleanup transform are captured
once, so editing a dictionary during a hold does not change that hold's output.
If recognition fails, Epos reports `Recognition lost`, waits for shortcut release, and
attempts to deliver text recognized before the failure. A trailing partial can
serve as the final fallback.

The [Microphone menu](settings.md#input-controls) can pin an input by its Core
Audio UID. Each open or recovery resolves that UID to its current device ID,
binds Epos's audio unit, and verifies the binding. It leaves the system default
unchanged. System default resolves the current macOS input instead. An
unavailable pinned microphone blocks a new recording without falling back.

AudioCapture attempts to reopen the input path when the device configuration or
input inventory changes during a hold. A reconnected device is resolved again,
so its device ID can change. A failed reopen ends the recording and reports `Mic lost`.
Recovery behavior across real input devices needs installed app verification.
Analyzer startup and speech finalization each have a ten second bound to escape
framework hangs. A cancellation-ignoring startup cannot keep the coordinator
waiting forever.

## Ignore speaker audio

The menu toggle enables Apple's microphone voice processing on the next hold.
It attempts to subtract speaker playback and adds the platform's noise
suppression and gain control. The default is off because macOS also ducks other
audio while this mode runs, including at the minimum ducking level Epos uses.
Speaker rejection is imperfect. If the device refuses voice processing, Epos
logs the failure and captures raw input.

## Transcript cleanup

The provisional display and final transcript share this transform:

```text
raw transcript -> active correction dictionary -> deterministic stream cleanup
```

Cleanup is always on. It removes standalone `um`, `uh`, `er`, and `hmm`, collapses
immediate whitespace-separated repeats from a conservative function word list,
and spells valid standalone numeric ordinals from first through thirty-first.
For example, `um, the the 2nd task` becomes `the second task`.

Ambiguous fillers such as `like`, grammatical repeats such as `had had`, acronyms,
and punctuation outside a changed seam are preserved. General grammar rewriting
and LLM polish are absent. [Corrections](corrections.md) describe dictionary
matching; [insertion](insertion.md) describes the destination checks.

## Evidence

The path is wired by [AppCoordinator](../Sources/Epos/App/AppCoordinator.swift),
[RecordingSession](../Sources/Epos/App/RecordingSession.swift),
[DictationHotkey](../Sources/Epos/Hotkey/DictationHotkey.swift),
[AudioCapture](../Sources/Epos/Audio/AudioCapture.swift),
[CapturePreRoll](../Sources/Epos/Audio/CapturePreRoll.swift), and
[Transcriber](../Sources/Epos/Speech/Transcriber.swift).
[TranscriptDeterministicCleaner](../Sources/Epos/Speech/TranscriptDeterministicCleaner.swift)
owns cleanup.

Regression coverage includes
[shortcut events and reconciliation](../Tests/EposTests/DictationHotkeyTests.swift),
[shortcut validation](../Tests/EposTests/DictationShortcutTests.swift),
[shortcut recording](../Tests/EposTests/ShortcutRecordingTests.swift),
[device routing and inventory](../Tests/EposTests/AudioInputDeviceTests.swift),
[audio lifecycle](../Tests/EposTests/CoordinatorAudioLifecycleTests.swift),
[startup audio ordering](../Tests/EposTests/CapturePreRollTests.swift),
[channel conversion](../Tests/EposTests/AudioCaptureConverterTests.swift),
[recognizer failures](../Tests/EposTests/CoordinatorRecognizerFailureTests.swift),
[cleanup](../Tests/EposTests/TranscriptDeterministicCleanerTests.swift), and
[final transform](../Tests/EposTests/CoordinatorFinalCleaningTests.swift).
Fakes prove coordinator decisions. They do not measure current microphone
capture, recognition accuracy, device recovery, or release latency.
The [stopped-engine probe](../probes/audio-input/verify) checks native device
binding and readback without recording audio or changing the system default.
