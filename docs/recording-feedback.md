# Recording feedback

Epos uses a screen edge glow, a floating recording pill, and synthesized start
and release sounds to show capture and progress. The pill does not activate the
app or intercept clicks. It appears near the bottom center of the active screen.

During recording, the pill shows Listening, an RMS amplitude meter, and a single
tail-visible line of provisional text when the field preview is unavailable.
It shows Finishing while speech finalizes and Updating while insertion runs.
When the field mirrors the transcript, the duplicate pill transcript is hidden.

The start sound plays after the microphone opens. The release sound plays when
capture closes. A failed sound synthesis does not stop dictation. There is no
sound preference in the menu.

## Edge glow

The glow defaults on and starts at recording onset. Voice amplitude brightens
it. With a healthy inline preview, the glow supplies the capture cue and the pill
yields. If preview is unconfirmed after 200 ms or degrades during the hold, the
glow retires and the pill takes over. With inline preview disabled, the glow and
transcript pill appear together.

Menu controls persist enablement, intensity, thickness, theme, and color. The
standard theme starts teal and offers seven swatches plus a custom color panel.
Ember aura uses a fixed red and black palette with smoke and flicker. Choosing
a standard color selects the standard theme. Style changes apply during the
current hold, and disabling the active glow hands the capture cue to the pill.

## Failure notices

Notices remain visible for approximately 2.5 seconds. Overlapping notices retain
their own lifetimes so finalization does not hide an active failure.

| Notice | Meaning |
| --- | --- |
| Preparing | Launch or speech asset preparation is incomplete |
| No model | The speech model is unavailable |
| Mic blocked | Microphone access is missing |
| Speech blocked | Speech Recognition access is missing |
| Not ready | A session could not open |
| Mic lost | Capture failed during a hold |
| Recognition lost | Recognition failed during a hold |
| Not inserted | The final target or backend refused delivery |
| No access | Accessibility trust prevented delivery |

The final IME commit's missing acknowledgment is currently logged as ambiguous
without a refusal notice. See [insertion](insertion.md#final-delivery).

## Evidence

Implementation lives in
[RecordingCuePresenter](../Sources/Epos/App/RecordingCuePresenter.swift),
[RecordingIndicator](../Sources/Epos/UI/RecordingIndicator.swift),
[RecordingIndicatorController](../Sources/Epos/UI/RecordingIndicatorController.swift),
[RecordingEdgeGlow](../Sources/Epos/UI/RecordingEdgeGlow.swift), and
[RecordingCue](../Sources/Epos/UI/RecordingCue.swift).

[CoordinatorDisplayAndGlowTests](../Tests/EposTests/CoordinatorDisplayAndGlowTests.swift)
cover preview ownership and live style changes.
[CoordinatorNoticeOverlapTests](../Tests/EposTests/CoordinatorNoticeOverlapTests.swift)
cover notice lifetime. [SmokeTests](../Tests/EposTests/SmokeTests.swift) cover meter
response, placement, sound parsing, and labels.
[IndicatorSuppressionTests](../Tests/EposTests/IndicatorSuppressionTests.swift)
protect the test runner from presenting windows. Actual rendering, sound, screen
placement, and cue latency require an installed app run.
