"""Monotonic recording stage durations, grouped by their observed outcome."""

from __future__ import annotations

from collections import defaultdict
from typing import Any, Iterable, TYPE_CHECKING

from audit_common import numeric, timing

if TYPE_CHECKING:
    from audit_operational import Session

STAGES = (
    "microphone-open", "target-baseline", "analyzer-startup",
    "first-recognizer-result", "first-display-publication", "first-mark-acknowledged",
    "recognizer-finalization", "transcript-cleanup", "preview-cancel", "preview-discard",
    "composition-settle", "baseline-settle", "target-authorization", "ime-commit",
    "keystroke-write", "release-to-write", "delivery-readback", "session-cleanup",
)
OUTCOMES = ("completed", "failed", "refused", "ambiguous", "unavailable")


def stage_timing_report(recordings: Iterable[Session]) -> dict[str, Any]:
    from audit_operational import fields

    grouped: dict[str, list[dict[str, str]]] = defaultdict(list)
    invalid, with_timing = 0, 0
    for recording in recordings:
        attempts: dict[tuple[str, int], list[dict[str, str]]] = defaultdict(list)
        prefix = f"recordingID={recording.recording_id} recording timing "
        for event in recording.events:
            if not event.message.startswith(prefix):
                continue
            row = fields(event.message)
            duration, elapsed = numeric(row.get("durationMs")), numeric(row.get("elapsedMs"))
            attempt = numeric(row.get("attempt"))
            if (row.get("schema") != "1" or row.get("stage") not in STAGES
                    or row.get("outcome") not in OUTCOMES or attempt is None
                    or attempt < 1 or not attempt.is_integer()
                    or duration is None or elapsed is None or elapsed < 0
                    or duration > elapsed
                    or (duration < 0 and not (duration == -1 and row["outcome"] == "unavailable"))):
                invalid += 1
                continue
            attempts[(row["stage"], int(attempt))].append(row)
        valid = False
        for rows in attempts.values():
            if len(rows) != 1:
                invalid += len(rows)
                continue
            grouped[rows[0]["stage"]].append(rows[0])
            valid = True
        with_timing += int(valid)

    stages = {}
    for stage in STAGES:
        rows = grouped[stage]
        stages[stage] = {
            "observations": len(rows),
            "outcomes": {
                outcome: {
                    "count": sum(row["outcome"] == outcome for row in rows),
                    "durationlessCount": sum(row["outcome"] == outcome and float(row["durationMs"]) < 0
                                             for row in rows),
                    "timing": timing(float(row["durationMs"]) for row in rows
                                     if row["outcome"] == outcome and float(row["durationMs"]) >= 0),
                }
                for outcome in OUTCOMES
            },
        }
    return {"recordingsWithTiming": with_timing, "invalidEvents": invalid, "stages": stages}
