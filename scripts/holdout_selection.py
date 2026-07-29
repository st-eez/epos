"""Select the untouched holdout deterministically from the unlabeled pool."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
from typing import Any

from corpus_reader import Corpus
from holdout_audio import HoldoutAudioError, file_sha256, wav_duration_seconds


SCHEMA_VERSION = 1
SELECTION_SIZE = 40
DURATION_STRATA = 3
CHRONOLOGICAL_STRATA = 4
ALGORITHM_VERSION = 1
ALGORITHM = (
    "unlabeled pool split into duration terciles then chronological quartiles; "
    "picks apportioned by integer largest-remainder; "
    "members ordered by audioSHA256 within each cell"
)
POOL_STATUS = "unlabeled"


class SelectionError(ValueError):
    """The holdout selection cannot be computed, loaded, or trusted."""


@dataclass(frozen=True)
class SelectedRecording:
    file: str
    audio_sha256: str
    duration_seconds: float
    duration_stratum: int
    chronological_stratum: int


@dataclass(frozen=True)
class Selection:
    recordings: tuple[SelectedRecording, ...]
    pool_size: int
    corpus_sha256: str
    sha256: str


def compute_selection(
    corpus: Corpus,
    recordings_directory: Path,
    *,
    size: int = SELECTION_SIZE,
) -> Selection:
    pool = measure_pool(corpus, recordings_directory)
    if len(pool) < size:
        raise SelectionError(
            f"holdout needs {size} {POOL_STATUS} recordings; pool holds {len(pool)}"
        )
    stratified = assign_strata(pool)
    cells: dict[tuple[int, int], list[SelectedRecording]] = {}
    for recording in stratified:
        key = (recording.duration_stratum, recording.chronological_stratum)
        cells.setdefault(key, []).append(recording)
    keys = sorted(cells)
    picks = apportion([len(cells[key]) for key in keys], size)
    chosen: list[SelectedRecording] = []
    for key, count in zip(keys, picks):
        members = sorted(cells[key], key=lambda item: (item.audio_sha256, item.file))
        chosen.extend(members[:count])
    chosen.sort(key=lambda item: item.file)
    return finalize(tuple(chosen), len(pool), corpus.sha256)


def measure_pool(
    corpus: Corpus,
    recordings_directory: Path,
) -> list[SelectedRecording]:
    """Every unlabeled recording, with its duration read from the wav header.

    Inferred rows were the historical correction-tuning arm, so they are
    contaminated as a holdout and never enter the pool.
    """
    pool: list[SelectedRecording] = []
    for file, entry in sorted(corpus.entries_by_file.items()):
        if entry.verification_status != POOL_STATUS:
            continue
        path = recordings_directory / file
        if not path.is_file():
            raise SelectionError(f"pooled recording is missing: {file}")
        digest = file_sha256(path)
        if digest != entry.audio_sha256:
            raise SelectionError(
                f"{file}: audio SHA-256 mismatch; "
                f"corpus={entry.audio_sha256}, recording={digest}"
            )
        try:
            duration = wav_duration_seconds(path)
        except (HoldoutAudioError, OSError) as error:
            raise SelectionError(str(error)) from error
        pool.append(SelectedRecording(file, digest, round(duration, 3), 0, 0))
    return pool


def assign_strata(pool: list[SelectedRecording]) -> list[SelectedRecording]:
    """Tag each recording with its duration tercile and chronological quartile.

    Filenames are recording timestamps, so filename order is chronological order.
    """
    by_duration = sorted(pool, key=lambda item: (item.duration_seconds, item.file))
    banded: dict[int, list[SelectedRecording]] = {}
    for position, recording in enumerate(by_duration):
        stratum = position * DURATION_STRATA // len(by_duration) + 1
        banded.setdefault(stratum, []).append(recording)
    stratified: list[SelectedRecording] = []
    for duration_stratum, members in sorted(banded.items()):
        chronological = sorted(members, key=lambda item: item.file)
        for position, recording in enumerate(chronological):
            stratified.append(
                SelectedRecording(
                    file=recording.file,
                    audio_sha256=recording.audio_sha256,
                    duration_seconds=recording.duration_seconds,
                    duration_stratum=duration_stratum,
                    chronological_stratum=(
                        position * CHRONOLOGICAL_STRATA // len(chronological) + 1
                    ),
                )
            )
    return stratified


def apportion(sizes: list[int], total: int) -> list[int]:
    """Largest-remainder apportionment in exact integers, so runs never differ."""
    pool = sum(sizes)
    picks = [size * total // pool for size in sizes]
    remainders = [size * total % pool for size in sizes]
    order = sorted(range(len(sizes)), key=lambda index: (-remainders[index], index))
    for index in order[: total - sum(picks)]:
        picks[index] += 1
    over_drawn = [index for index, count in enumerate(picks) if count > sizes[index]]
    if over_drawn:
        raise SelectionError("apportionment drew more recordings than a stratum holds")
    return picks


def finalize(
    recordings: tuple[SelectedRecording, ...],
    pool_size: int,
    corpus_sha256: str,
) -> Selection:
    payload = identity_payload(recordings, pool_size, corpus_sha256)
    canonical = json.dumps(payload, sort_keys=True, separators=(",", ":"))
    digest = hashlib.sha256(canonical.encode("utf-8")).hexdigest()
    return Selection(recordings, pool_size, corpus_sha256, digest)


def identity_payload(
    recordings: tuple[SelectedRecording, ...],
    pool_size: int,
    corpus_sha256: str,
) -> dict[str, Any]:
    """The fields the selection digest covers; free-text prose stays out of it."""
    return {
        "schemaVersion": SCHEMA_VERSION,
        "algorithmVersion": ALGORITHM_VERSION,
        "designation": "holdout",
        "poolStatus": POOL_STATUS,
        "poolSize": pool_size,
        "selectionSize": len(recordings),
        "sourceCorpusSHA256": corpus_sha256,
        "recordings": [
            {
                "file": recording.file,
                "audioSHA256": recording.audio_sha256,
                "durationSeconds": recording.duration_seconds,
                "durationStratum": recording.duration_stratum,
                "chronologicalStratum": recording.chronological_stratum,
            }
            for recording in recordings
        ],
    }
