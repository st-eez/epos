"""Render the frozen holdout selection for review before any listening starts."""

from __future__ import annotations

from pathlib import Path

from holdout_selection import (
    ALGORITHM,
    CHRONOLOGICAL_STRATA,
    DURATION_STRATA,
    Selection,
)


def format_plan(
    selection: Selection,
    selection_path: Path,
    corpus_path: Path,
    notes: list[str],
    frozen: bool,
) -> str:
    durations = [recording.duration_seconds for recording in selection.recordings]
    lines = [
        f"holdout: {len(selection.recordings)} of {selection.pool_size} "
        "unlabeled recordings",
        f"algorithm: {ALGORITHM}",
        f"selection digest: {selection.sha256}",
        f"source corpus: {corpus_path} ({selection.corpus_sha256[:16]})",
        f"selection file: {selection_path} ({'frozen' if frozen else 'not yet frozen'})",
        f"listening time: {sum(durations) / 60:.1f} min of audio, "
        f"{min(durations):.1f}s shortest, {max(durations):.1f}s longest",
        "",
        "strata (duration tercile x chronological quartile):",
    ]
    lines.extend(stratum_lines(selection))
    lines.extend(f"note: {note}" for note in notes)
    lines.append("")
    for index, recording in enumerate(selection.recordings, start=1):
        lines.append(
            f"{index:3d}. {recording.file}  {recording.duration_seconds:6.1f}s  "
            f"d{recording.duration_stratum} c{recording.chronological_stratum}"
        )
    return "\n".join(lines)


def stratum_lines(selection: Selection) -> list[str]:
    counts: dict[tuple[int, int], int] = {}
    for recording in selection.recordings:
        key = (recording.duration_stratum, recording.chronological_stratum)
        counts[key] = counts.get(key, 0) + 1
    lines = []
    for duration_stratum in range(1, DURATION_STRATA + 1):
        members = [
            recording for recording in selection.recordings
            if recording.duration_stratum == duration_stratum
        ]
        cells = " ".join(
            f"c{chronological}={counts.get((duration_stratum, chronological), 0)}"
            for chronological in range(1, CHRONOLOGICAL_STRATA + 1)
        )
        span = (
            f"{min(item.duration_seconds for item in members):.1f}"
            f"-{max(item.duration_seconds for item in members):.1f}s"
            if members else "empty"
        )
        lines.append(
            f"  d{duration_stratum}: {len(members):2d} picks  {span:>14}  {cells}"
        )
    return lines
