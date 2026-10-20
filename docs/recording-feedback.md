# Recording feedback

Epos shows a tiny microphone beside the text cursor throughout recording. Voice
amplitude brightens the icon. It stays visible whether inline text preview is
healthy, unavailable, or disabled, with the same behavior in Codex and Ghostty.
The panel does not activate Epos or intercept clicks.

The microphone sits below the caret with a gap, or above it when a bottom input
leaves too little room. The input method supplies native caret geometry with
preview acknowledgments. Bounded Accessibility reads provide a fallback off the
main actor. Invalid, unavailable, selected, or offscreen caret geometry uses a small
cue at the right edge of the target display instead. The cue never shows a
transcript. While finalizing, it shows a spinner, then disappears when the session
completes. Error notices expand at the screen edge so their text remains readable.

The start sound plays after the microphone opens. The release sound plays when
capture closes. A failed sound synthesis does not stop dictation. There is no
sound preference in the menu.

## Edge glow

The optional glow follows its existing setting and starts at recording onset.
Voice amplitude brightens it, and release ends it. It is independent of preview
availability and does not replace or hide the microphone cue.

Menu controls persist enablement, intensity, thickness, theme, and color. The
standard theme starts teal and offers seven swatches plus a custom color panel.
Ember aura uses a fixed red and black palette with smoke and flicker. Choosing
a standard color selects the standard theme. Style changes apply during the
current hold, and disabling the glow leaves the microphone cue visible.

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
| Field unavailable | No destination could be captured at the start of the hold |
| Mic lost | Capture failed during a hold |
| Recognition lost | Recognition failed during a hold |
| Not inserted | The final target or backend refused delivery |
| No access | Accessibility trust prevented delivery |
| Check the field | The final IME command was sent, but delivery could not be confirmed |

`Check the field` asks the user to inspect the destination. The IME may have
inserted the text before its acknowledgment was lost, so Epos suppresses a second
write. See [insertion](insertion.md#final-delivery).

## Evidence

Implementation lives in
[RecordingCuePresenter](../Sources/Epos/App/RecordingCuePresenter.swift),
[RecordingIndicator](../Sources/Epos/UI/RecordingIndicator.swift),
[RecordingIndicatorController](../Sources/Epos/UI/RecordingIndicatorController.swift),
[RecordingEdgeGlow](../Sources/Epos/UI/RecordingEdgeGlow.swift), and
[RecordingCue](../Sources/Epos/UI/RecordingCue.swift).

[CoordinatorDisplayAndGlowTests](../Tests/EposTests/CoordinatorDisplayAndGlowTests.swift)
cover cue lifetime and live style changes.
[CoordinatorNoticeOverlapTests](../Tests/EposTests/CoordinatorNoticeOverlapTests.swift)
cover notice lifetime. [SmokeTests](../Tests/EposTests/SmokeTests.swift) cover microphone
brightness, sound parsing, and labels.
[RecordingIndicatorPlacementTests](../Tests/EposTests/RecordingIndicatorPlacementTests.swift)
cover caret clearance, screen-edge fallback, invalid geometry, and multiple displays.
[IndicatorSuppressionTests](../Tests/EposTests/IndicatorSuppressionTests.swift)
protect the test runner from presenting windows. Actual rendering, sound, screen
placement, and cue latency require an installed app run.
