# Recording stage timing

Date: 2026-10-01. See [diagnostics](../docs/diagnostics.md#stage-timing).

The existing release-to-outcome metric includes delayed delivery readback and
does not identify where a recording spends its time. Add stage durations beside
the reliability events so latency experiments can compare the same boundaries.

One `RecordingLatencyDiagnostics` instance belongs to one `RecordingSession` and
follows its insertion session into asynchronous readback. It uses an injected
`ContinuousClock` source and a lock around interval bookkeeping. Timings contain
fixed stage and outcome tokens, attempt numbers, durations, and recording IDs.
They contain no dictated text, field values, application titles, or identifiers
beyond the existing recording ID.

| Stage | Start | End |
| --- | --- | --- |
| microphone-open | Before capture start | Capture start returns or throws |
| target-baseline | Before backend and observer creation | Target baseline captured |
| analyzer-startup | Before recognizer start | Event stream returned or startup throws |
| first-recognizer-result | Recording starts | First partial or final event received |
| first-display-publication | Recording starts | First nonempty cleaned display event published |
| first-mark-acknowledged | Recording starts with preview enabled | First mark acknowledgment callback received |
| recognizer-finalization | Release | Recognizer event stream ends, or immediately if already ended |
| transcript-cleanup | Before final canonicalization | Final deterministic cleanup returns |
| preview-cancel | Before final IME composition cancellation | Cancellation attempt returns |
| preview-discard | Discard task scheduled | Discard returns and its acknowledgment state is known |
| composition-settle | Before fixed post-discard delay | Delay returns |
| baseline-settle | Before baseline polling or opaque IME settle | Polling and required settle return |
| target-authorization | Before final guard | Guard returns authorized or refused |
| ime-commit | Before final commit request | Commit acknowledged, refused, or ambiguous |
| keystroke-write | After authorization, before backend insertion | Unicode posting accepted or refused |
| release-to-write | Release | Accepted Unicode posting or acknowledged IME commit recorded |
| delivery-readback | Before readback eligibility check | Verification returns matched, mismatched, or unavailable |
| session-cleanup | Resource cleanup starts | Preview and analyzer cleanup awaited |

The first-result stages exclude readiness checks before recording starts. A
deferred fn press can precede them by seconds. Published display state and IME
acknowledgments are observable software boundaries, not measurements of screen
painting. Unicode acceptance proves event posting, not visible field delivery.

Release-to-write records refusal or ambiguity when no accepted write can be
claimed. Missing first results and empty recordings use unavailable durations
of -1. Unexecuted stages remain absent. Completed stages measure returned work;
they do not certify the whole recording or prove a baseline wait restored text.
Target authorization and terminal reliability remain authoritative for safety.

The audit validates attempts independently and reports percentiles by stage and
outcome. Authorization percentiles count attempts, so a recording can contribute
twice after a safe IME refusal. It excludes missing durations and malformed or
contradictory events.
Concurrent stages overlap. Readback remains diagnostic work outside the session's
idle transition and never causes a corrective write.

Clock-controlled tests verify boundaries without microphone input or audible
cues. Actual latency comparisons require current signed-app saved-audio replay
and installed-app delivery evidence. Add physical key or screen-paint timing only
when those acceptance measurements are being performed.
