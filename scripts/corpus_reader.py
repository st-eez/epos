"""Strictly load the authoritative v2 evaluation-corpus ledger for consumers."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import re
from typing import Any


SCHEMA_VERSION = 2
CONFIRMED_LEGACY_ORDINALS = frozenset(range(1, 36))
INFERRED_LEGACY_ORDINALS = frozenset(range(36, 115))
VERIFICATION_STATUSES = frozenset({"human_confirmed", "inferred", "unlabeled"})
REQUIRED_CORPUS_FIELDS = frozenset({
    "schemaVersion",
    "file",
    "audioSHA256",
    "transcriptCandidate",
    "verificationStatus",
    "legacyOrdinal",
})
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}")


class CorpusReadError(ValueError):
    """A corpus artifact violates the v2 provenance contract."""


@dataclass(frozen=True)
class CorpusEntry:
    file: str
    audio_sha256: str
    transcript_candidate: str | None
    verification_status: str
    legacy_ordinal: int | None


@dataclass(frozen=True)
class Corpus:
    entries_by_file: dict[str, CorpusEntry]
    sha256: str


def load_corpus(path: Path) -> Corpus:
    entries: dict[str, CorpusEntry] = {}
    canonical_filenames: dict[str, str] = {}
    ordinal_files: dict[int, str] = {}
    digest = hashlib.sha256()
    try:
        stream = path.open("rb")
    except OSError as error:
        raise CorpusReadError(
            f"cannot read evaluation corpus {path}: {error}"
        ) from error
    with stream:
        for line_number, raw_line in enumerate(stream, start=1):
            digest.update(raw_line)
            if not raw_line.strip():
                continue
            entry = read_entry(decode_row(path, line_number, raw_line))
            prior_file = canonical_filenames.setdefault(
                entry.file.casefold(), entry.file
            )
            if prior_file != entry.file:
                raise CorpusReadError(
                    f"{path}: filenames differ only by case: {prior_file}, {entry.file}"
                )
            if entry.file in entries:
                raise CorpusReadError(f"{path}: duplicate corpus file {entry.file}")
            if entry.legacy_ordinal is not None:
                prior_ordinal_file = ordinal_files.setdefault(
                    entry.legacy_ordinal, entry.file
                )
                if prior_ordinal_file != entry.file:
                    raise CorpusReadError(
                        f"{path}: duplicate legacyOrdinal {entry.legacy_ordinal} for "
                        f"{prior_ordinal_file}, {entry.file}"
                    )
            entries[entry.file] = entry
    if not entries:
        raise CorpusReadError(f"{path}: no evaluation corpus rows found")
    validate_legacy_ordinal_sets(path, entries)
    return Corpus(entries, digest.hexdigest())


def decode_row(path: Path, line_number: int, raw_line: bytes) -> dict[str, Any]:
    try:
        decoded: Any = json.loads(raw_line)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise CorpusReadError(
            f"{path}: line {line_number} is not valid UTF-8 JSON"
        ) from error
    if not isinstance(decoded, dict):
        raise CorpusReadError(f"{path}: line {line_number} must be a JSON object")
    missing_fields = REQUIRED_CORPUS_FIELDS - decoded.keys()
    if missing_fields:
        raise CorpusReadError(
            f"{path}: line {line_number} is missing fields: "
            + ", ".join(sorted(missing_fields))
        )
    if (
        type(decoded["schemaVersion"]) is not int
        or decoded["schemaVersion"] != SCHEMA_VERSION
    ):
        raise CorpusReadError(
            f"{path}: line {line_number} has unsupported schemaVersion"
        )
    return decoded


def read_entry(row: dict[str, Any]) -> CorpusEntry:
    file = required_string(row, "file")
    validate_recording_filename(file)
    status = required_string(row, "verificationStatus")
    if status not in VERIFICATION_STATUSES:
        raise CorpusReadError(f"{file}: unsupported verificationStatus {status}")
    transcript = optional_transcript(row, file)
    ordinal = optional_legacy_ordinal(row, file)
    validate_status_fields(file, status, transcript, ordinal)
    return CorpusEntry(
        file=file,
        audio_sha256=required_sha256(row, "audioSHA256"),
        transcript_candidate=transcript,
        verification_status=status,
        legacy_ordinal=ordinal,
    )


def validate_legacy_ordinal_sets(
    path: Path,
    entries: dict[str, CorpusEntry],
) -> None:
    ordinals_by_status: dict[str, set[int | None]] = {
        status: {
            entry.legacy_ordinal for entry in entries.values()
            if entry.verification_status == status
        }
        for status in ("human_confirmed", "inferred")
    }
    if ordinals_by_status["human_confirmed"] != CONFIRMED_LEGACY_ORDINALS:
        raise CorpusReadError(
            f"{path}: human-confirmed legacy ordinals must be exactly 1...35"
        )
    if ordinals_by_status["inferred"] != INFERRED_LEGACY_ORDINALS:
        raise CorpusReadError(
            f"{path}: inferred legacy ordinals must be exactly 36...114"
        )


def validate_status_fields(
    file: str,
    status: str,
    transcript: str | None,
    ordinal: int | None,
) -> None:
    if status == "unlabeled":
        if transcript is not None or ordinal is not None:
            raise CorpusReadError(
                f"{file}: unlabeled rows require null transcriptCandidate "
                "and legacyOrdinal"
            )
        return
    if transcript is None:
        raise CorpusReadError(f"{file}: {status} rows require a transcriptCandidate")
    if status == "human_confirmed" and ordinal not in CONFIRMED_LEGACY_ORDINALS:
        raise CorpusReadError(
            f"{file}: human-confirmed legacyOrdinal must be within 1...35"
        )
    if status == "inferred" and ordinal not in INFERRED_LEGACY_ORDINALS:
        raise CorpusReadError(
            f"{file}: inferred legacyOrdinal must be within 36...114"
        )


def optional_transcript(row: dict[str, Any], file: str) -> str | None:
    value = row["transcriptCandidate"]
    if value is None:
        return None
    if not isinstance(value, str) or not value.strip():
        raise CorpusReadError(
            f"{file}: transcriptCandidate must be a non-empty string or null"
        )
    return value.strip()


def optional_legacy_ordinal(row: dict[str, Any], file: str) -> int | None:
    value = row["legacyOrdinal"]
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, int) or value < 1:
        raise CorpusReadError(
            f"{file}: legacyOrdinal must be a positive integer or null"
        )
    return value


def required_string(row: dict[str, Any], key: str) -> str:
    value = row[key]
    if not isinstance(value, str) or not value.strip():
        raise CorpusReadError(
            f"{row.get('file', '<unknown>')}: {key} must be a non-empty string"
        )
    return value.strip()


def required_sha256(row: dict[str, Any], key: str) -> str:
    value = row[key]
    if not isinstance(value, str) or SHA256_PATTERN.fullmatch(value) is None:
        raise CorpusReadError(
            f"{row.get('file', '<unknown>')}: {key} must be 64 lowercase hex characters"
        )
    return value


def validate_recording_filename(file: str) -> None:
    if Path(file).name != file or not file.casefold().endswith(".wav"):
        raise CorpusReadError(f"unsafe recording filename: {file}")
