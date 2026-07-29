"""Validate replay coverage against current recordings and human labels."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import cast

from label_artifact import JsonObject, required_string, validate_recording_filename
from label_queue import Candidate, LabelQueueError


def validate_recording_coverage(
    candidates: list[Candidate],
    recordings_directory: Path,
    ground_truth_manifest: Path,
) -> None:
    if not recordings_directory.is_dir():
        raise LabelQueueError(
            f"recordings directory does not exist: {recordings_directory}"
        )
    recording_files = {
        item.name for item in recordings_directory.iterdir()
        if item.is_file() and item.suffix.casefold() == ".wav"
    }
    labeled_files = (
        load_labeled_files(ground_truth_manifest)
        if ground_truth_manifest.is_file()
        else set()
    )
    stale_labels = labeled_files - recording_files
    source_files = {candidate.file for candidate in candidates}
    already_labeled = source_files & labeled_files
    missing_audio = source_files - recording_files
    expected_unlabeled = recording_files - labeled_files
    missing_from_source = expected_unlabeled - source_files
    unexpected_source = source_files - expected_unlabeled
    if stale_labels or already_labeled or missing_audio or missing_from_source or unexpected_source:
        raise LabelQueueError(
            "corpus coverage mismatch: "
            f"stale labels={format_file_set(stale_labels)}, "
            f"already labeled={format_file_set(already_labeled)}, "
            f"missing audio={format_file_set(missing_audio)}, "
            "unlabeled recordings absent from artifact="
            f"{format_file_set(missing_from_source)}, "
            f"unexpected artifact files={format_file_set(unexpected_source)}"
        )

    candidates_by_file = {candidate.file: candidate for candidate in candidates}
    for file in sorted(source_files):
        actual = file_sha256(recordings_directory / file)
        expected = candidates_by_file[file].audio_sha256
        if actual != expected:
            raise LabelQueueError(
                f"{file}: audio SHA-256 mismatch; artifact={expected}, recording={actual}"
            )


def load_labeled_files(path: Path) -> set[str]:
    files: set[str] = set()
    with path.open(encoding="utf-8") as stream:
        for line_number, raw_line in enumerate(stream, start=1):
            if not raw_line.strip():
                continue
            try:
                decoded: object = json.loads(raw_line)
            except json.JSONDecodeError as error:
                raise LabelQueueError(
                    f"{path}: line {line_number} is not valid JSON: {error.msg}"
                ) from error
            if not isinstance(decoded, dict):
                raise LabelQueueError(
                    f"{path}: line {line_number} must be a JSON object"
                )
            row = cast(JsonObject, decoded)
            file = required_string(row, "file")
            validate_recording_filename(file)
            required_string(row, "humanIntendedTranscript")
            if file in files:
                raise LabelQueueError(f"{path}: duplicate labeled file {file}")
            files.add(file)
    return files


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def format_file_set(files: set[str]) -> str:
    return f"{len(files)}[{', '.join(sorted(files))}]"
