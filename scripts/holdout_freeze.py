"""Freeze the holdout selection to disk and refuse to trust an edited one."""

from __future__ import annotations

import json
import os
from pathlib import Path
import tempfile
from typing import Any

from corpus_reader import Corpus
from holdout_audio import file_sha256
from holdout_selection import (
    ALGORITHM,
    ALGORITHM_VERSION,
    SCHEMA_VERSION,
    SelectedRecording,
    Selection,
    SelectionError,
    finalize,
    identity_payload,
)


SELECTION_FILENAME = "holdout-selection.json"


def default_selection_path(recordings_directory: Path) -> Path:
    return recordings_directory / SELECTION_FILENAME


def selection_payload(selection: Selection) -> dict[str, Any]:
    payload = identity_payload(
        selection.recordings, selection.pool_size, selection.corpus_sha256
    )
    payload["algorithm"] = ALGORITHM
    payload["selectionSHA256"] = selection.sha256
    return payload


def write_selection(path: Path, selection: Selection, *, replace: bool) -> None:
    if path.exists() and not replace:
        raise SelectionError(f"holdout selection is already frozen: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        dir=path.parent,
        prefix=f".{path.name}.",
        delete=False,
    ) as stream:
        staged = Path(stream.name)
        stream.write(json.dumps(selection_payload(selection), indent=2, sort_keys=True))
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    try:
        os.replace(staged, path)
    except OSError:
        staged.unlink(missing_ok=True)
        raise


def load_selection(path: Path) -> Selection:
    try:
        decoded: Any = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise SelectionError(f"cannot read holdout selection {path}: {error}") from error
    if not isinstance(decoded, dict) or decoded.get("schemaVersion") != SCHEMA_VERSION:
        raise SelectionError(f"{path}: unsupported holdout selection schema")
    if decoded.get("algorithmVersion") != ALGORITHM_VERSION:
        raise SelectionError(f"{path}: holdout selection algorithm version changed")
    rows = decoded.get("recordings")
    if not isinstance(rows, list) or not rows:
        raise SelectionError(f"{path}: holdout selection has no recordings")
    try:
        selection = finalize(
            tuple(
                SelectedRecording(
                    file=row["file"],
                    audio_sha256=row["audioSHA256"],
                    duration_seconds=row["durationSeconds"],
                    duration_stratum=row["durationStratum"],
                    chronological_stratum=row["chronologicalStratum"],
                )
                for row in rows
            ),
            decoded["poolSize"],
            decoded["sourceCorpusSHA256"],
        )
    except (KeyError, TypeError) as error:
        raise SelectionError(f"{path}: holdout selection is malformed: {error}") from error
    if selection.sha256 != decoded.get("selectionSHA256"):
        raise SelectionError(f"{path}: holdout selection was edited after freezing")
    return selection


def validate_selection(
    selection: Selection,
    corpus: Corpus,
    recordings_directory: Path,
) -> list[str]:
    """Fail closed if a frozen pick changed; report benign corpus drift as a note."""
    for recording in selection.recordings:
        entry = corpus.entries_by_file.get(recording.file)
        if entry is None:
            raise SelectionError(
                f"frozen holdout recording left the corpus: {recording.file}"
            )
        path = recordings_directory / recording.file
        if not path.is_file():
            raise SelectionError(f"frozen holdout recording is missing: {recording.file}")
        digest = file_sha256(path)
        if digest != recording.audio_sha256 or entry.audio_sha256 != digest:
            raise SelectionError(
                f"{recording.file}: frozen holdout audio changed since selection"
            )
    if selection.corpus_sha256 == corpus.sha256:
        return []
    return [
        "corpus changed since the holdout was frozen; every frozen recording still "
        "matches its audio, so the holdout stands"
    ]
