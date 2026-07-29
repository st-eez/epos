"""Validate replay coverage against the provenance-aware evaluation corpus."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
from typing import cast

from label_artifact import (
    JsonObject,
    required_sha256,
    required_string,
    validate_recording_filename,
)
from label_queue import Candidate, LabelQueueError


CONFIRMED_LEGACY_ORDINALS = frozenset(range(1, 36))
INFERRED_LEGACY_ORDINALS = frozenset(range(36, 115))


REQUIRED_CORPUS_FIELDS = frozenset({
    "schemaVersion",
    "file",
    "audioSHA256",
    "transcriptCandidate",
    "verificationStatus",
    "legacyOrdinal",
})


@dataclass(frozen=True)
class CorpusEntry:
    file: str
    audio_sha256: str
    transcript_candidate: str | None
    verification_status: str
    legacy_ordinal: int | None


@dataclass(frozen=True)
class CorpusCoverage:
    entries_by_file: dict[str, CorpusEntry]
    sha256: str


def validate_recording_coverage(
    candidates: list[Candidate],
    recordings_directory: Path,
    corpus_path: Path,
) -> CorpusCoverage:
    if not recordings_directory.is_dir():
        raise LabelQueueError(
            f"recordings directory does not exist: {recordings_directory}"
        )
    if not corpus_path.is_file():
        raise LabelQueueError(f"evaluation corpus does not exist: {corpus_path}")

    recording_files = {
        item.name for item in recordings_directory.iterdir()
        if item.is_file() and item.suffix.casefold() == ".wav"
    }
    corpus = load_corpus(corpus_path)
    corpus_files = set(corpus.entries_by_file)
    stale_corpus = corpus_files - recording_files
    recordings_absent_from_corpus = recording_files - corpus_files
    confirmed_files = {
        file for file, entry in corpus.entries_by_file.items()
        if entry.verification_status == "human_confirmed"
    }
    reviewable_files = corpus_files - confirmed_files
    source_files = {candidate.file for candidate in candidates}
    already_confirmed = source_files & confirmed_files
    missing_audio = source_files - recording_files
    missing_from_source = reviewable_files - source_files
    unexpected_source = source_files - reviewable_files
    if (
        stale_corpus
        or recordings_absent_from_corpus
        or already_confirmed
        or missing_audio
        or missing_from_source
        or unexpected_source
    ):
        raise LabelQueueError(
            "corpus coverage mismatch: "
            f"stale corpus rows={format_file_set(stale_corpus)}, "
            "recordings absent from corpus="
            f"{format_file_set(recordings_absent_from_corpus)}, "
            f"already human-confirmed={format_file_set(already_confirmed)}, "
            f"missing audio={format_file_set(missing_audio)}, "
            "reviewable recordings absent from artifact="
            f"{format_file_set(missing_from_source)}, "
            f"unexpected artifact files={format_file_set(unexpected_source)}"
        )

    candidates_by_file = {candidate.file: candidate for candidate in candidates}
    for file in sorted(recording_files):
        actual = file_sha256(recordings_directory / file)
        corpus_expected = corpus.entries_by_file[file].audio_sha256
        if actual != corpus_expected:
            raise LabelQueueError(
                f"{file}: audio SHA-256 mismatch; "
                f"corpus={corpus_expected}, recording={actual}"
            )
        candidate = candidates_by_file.get(file)
        if candidate is not None and candidate.audio_sha256 != corpus_expected:
            raise LabelQueueError(
                f"{file}: audio SHA-256 mismatch; "
                f"artifact={candidate.audio_sha256}, corpus={corpus_expected}"
            )
    return corpus


def load_corpus(path: Path) -> CorpusCoverage:
    entries: dict[str, CorpusEntry] = {}
    canonical_filenames: dict[str, str] = {}
    legacy_ordinals: dict[int, str] = {}
    digest = hashlib.sha256()
    try:
        stream = path.open("rb")
    except OSError as error:
        raise LabelQueueError(f"cannot read evaluation corpus {path}: {error}") from error
    with stream:
        for line_number, raw_line in enumerate(stream, start=1):
            digest.update(raw_line)
            if not raw_line.strip():
                continue
            try:
                decoded: object = json.loads(raw_line)
            except (UnicodeDecodeError, json.JSONDecodeError) as error:
                raise LabelQueueError(
                    f"{path}: line {line_number} is not valid UTF-8 JSON"
                ) from error
            if not isinstance(decoded, dict):
                raise LabelQueueError(
                    f"{path}: line {line_number} must be a JSON object"
                )
            row = cast(JsonObject, decoded)
            missing_fields = REQUIRED_CORPUS_FIELDS - row.keys()
            if missing_fields:
                raise LabelQueueError(
                    f"{path}: line {line_number} is missing fields: "
                    + ", ".join(sorted(missing_fields))
                )
            if type(row.get("schemaVersion")) is not int or row["schemaVersion"] != 2:
                raise LabelQueueError(
                    f"{path}: line {line_number} has unsupported schemaVersion"
                )
            file = required_string(row, "file")
            validate_recording_filename(file)
            prior_file = canonical_filenames.setdefault(file.casefold(), file)
            if prior_file != file:
                raise LabelQueueError(
                    f"{path}: filenames differ only by case: {prior_file}, {file}"
                )
            if file in entries:
                raise LabelQueueError(f"{path}: duplicate corpus file {file}")

            status = required_string(row, "verificationStatus")
            if status not in {"human_confirmed", "inferred", "unlabeled"}:
                raise LabelQueueError(
                    f"{file}: unsupported verificationStatus {status}"
                )
            transcript = optional_transcript(row, file)
            ordinal = optional_legacy_ordinal(row, file)
            validate_status_fields(file, status, transcript, ordinal)
            if ordinal is not None:
                prior_ordinal_file = legacy_ordinals.setdefault(ordinal, file)
                if prior_ordinal_file != file:
                    raise LabelQueueError(
                        f"{path}: duplicate legacyOrdinal {ordinal} for "
                        f"{prior_ordinal_file}, {file}"
                    )
            entries[file] = CorpusEntry(
                file=file,
                audio_sha256=required_sha256(row, "audioSHA256"),
                transcript_candidate=transcript,
                verification_status=status,
                legacy_ordinal=ordinal,
            )
    if not entries:
        raise LabelQueueError(f"{path}: no evaluation corpus rows found")
    confirmed_ordinals = {
        entry.legacy_ordinal
        for entry in entries.values()
        if entry.verification_status == "human_confirmed"
    }
    inferred_ordinals = {
        entry.legacy_ordinal
        for entry in entries.values()
        if entry.verification_status == "inferred"
    }
    if confirmed_ordinals != CONFIRMED_LEGACY_ORDINALS:
        raise LabelQueueError(
            f"{path}: human-confirmed legacy ordinals must be exactly 1...35"
        )
    if inferred_ordinals != INFERRED_LEGACY_ORDINALS:
        raise LabelQueueError(
            f"{path}: inferred legacy ordinals must be exactly 36...114"
        )
    return CorpusCoverage(entries, digest.hexdigest())


def optional_transcript(row: JsonObject, file: str) -> str | None:
    value = row.get("transcriptCandidate")
    if value is None:
        return None
    if not isinstance(value, str) or not value.strip():
        raise LabelQueueError(
            f"{file}: transcriptCandidate must be a non-empty string or null"
        )
    return value.strip()


def optional_legacy_ordinal(row: JsonObject, file: str) -> int | None:
    value = row.get("legacyOrdinal")
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, int) or value < 1:
        raise LabelQueueError(
            f"{file}: legacyOrdinal must be a positive integer or null"
        )
    return value


def validate_status_fields(
    file: str,
    status: str,
    transcript: str | None,
    ordinal: int | None,
) -> None:
    if status == "unlabeled":
        if transcript is not None or ordinal is not None:
            raise LabelQueueError(
                f"{file}: unlabeled rows require null transcriptCandidate "
                "and legacyOrdinal"
            )
        return
    if transcript is None:
        raise LabelQueueError(
            f"{file}: {status} rows require a transcriptCandidate"
        )
    if status == "human_confirmed" and ordinal not in CONFIRMED_LEGACY_ORDINALS:
        raise LabelQueueError(
            f"{file}: human-confirmed legacyOrdinal must be within 1...35"
        )
    if status == "inferred" and ordinal not in INFERRED_LEGACY_ORDINALS:
        raise LabelQueueError(
            f"{file}: inferred legacyOrdinal must be within 36...114"
        )


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def format_file_set(files: set[str]) -> str:
    return f"{len(files)}[{', '.join(sorted(files))}]"
