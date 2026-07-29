"""Own the holdout confirmation file the operator produces by listening."""

from __future__ import annotations

from dataclasses import dataclass
import json
import os
from pathlib import Path
import re
import tempfile
from typing import Any


CONFIRMATIONS_FILENAME = "holdout-confirmations.jsonl"
SCHEMA_VERSION = 1
DESIGNATION = "holdout"
CONFIRMATION_SOURCE = "scripts/confirm"
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}")


class ConfirmationError(ValueError):
    """A holdout confirmation violates its provenance contract."""


@dataclass(frozen=True)
class Confirmation:
    file: str
    audio_sha256: str
    human_intended_transcript: str
    candidate_shown: str | None
    candidate_source: str | None
    candidate_edited: bool
    selection_sha256: str
    confirmation_source: str = CONFIRMATION_SOURCE

    def to_row(self) -> dict[str, Any]:
        return {
            "schemaVersion": SCHEMA_VERSION,
            "file": self.file,
            "audioSHA256": self.audio_sha256,
            "humanIntendedTranscript": self.human_intended_transcript,
            "designation": DESIGNATION,
            "candidateShown": self.candidate_shown,
            "candidateSource": self.candidate_source,
            "candidateEdited": self.candidate_edited,
            "selectionSHA256": self.selection_sha256,
            "confirmationSource": self.confirmation_source,
        }


def default_confirmations_path(recordings_directory: Path) -> Path:
    return recordings_directory / CONFIRMATIONS_FILENAME


def load_confirmations(path: Path) -> list[Confirmation]:
    """Read every confirmation, or an empty list when no session has run yet."""
    if not path.exists():
        return []
    confirmations: list[Confirmation] = []
    seen: set[str] = set()
    for line_number, raw_line in enumerate(
        path.read_text(encoding="utf-8").splitlines(), start=1
    ):
        if not raw_line.strip():
            continue
        confirmation = read_confirmation(path, line_number, raw_line)
        if confirmation.file in seen:
            raise ConfirmationError(
                f"{path}: recording confirmed twice: {confirmation.file}"
            )
        seen.add(confirmation.file)
        confirmations.append(confirmation)
    return confirmations


def read_confirmation(path: Path, line_number: int, raw_line: str) -> Confirmation:
    try:
        decoded: Any = json.loads(raw_line)
    except json.JSONDecodeError as error:
        raise ConfirmationError(
            f"{path}: line {line_number} is not valid JSON: {error.msg}"
        ) from error
    if not isinstance(decoded, dict):
        raise ConfirmationError(f"{path}: line {line_number} must be a JSON object")
    where = f"{path}: line {line_number}"
    if decoded.get("schemaVersion") != SCHEMA_VERSION:
        raise ConfirmationError(f"{where} has unsupported schemaVersion")
    if decoded.get("designation") != DESIGNATION:
        raise ConfirmationError(f"{where} must be designated {DESIGNATION}")
    file = required_string(where, decoded, "file")
    validate_recording_filename(where, file)
    edited = decoded.get("candidateEdited")
    if not isinstance(edited, bool):
        raise ConfirmationError(f"{where} requires a boolean candidateEdited")
    candidate = optional_string(where, decoded, "candidateShown")
    transcript = required_string(where, decoded, "humanIntendedTranscript")
    if not edited and candidate != transcript:
        raise ConfirmationError(
            f"{where} claims an unedited candidate but its transcript differs"
        )
    return Confirmation(
        file=file,
        audio_sha256=required_sha256(where, decoded, "audioSHA256"),
        human_intended_transcript=transcript,
        candidate_shown=candidate,
        candidate_source=optional_string(where, decoded, "candidateSource"),
        candidate_edited=edited,
        selection_sha256=required_sha256(where, decoded, "selectionSHA256"),
        confirmation_source=required_string(where, decoded, "confirmationSource"),
    )


def append_confirmation(path: Path, confirmation: Confirmation) -> None:
    """Append one row by rewriting the whole file, so a crash cannot corrupt it."""
    existing = load_confirmations(path)
    if any(row.file == confirmation.file for row in existing):
        raise ConfirmationError(f"{path}: {confirmation.file} is already confirmed")
    payload = "".join(
        json.dumps(row.to_row(), ensure_ascii=False, sort_keys=True) + "\n"
        for row in (*existing, confirmation)
    )
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        dir=path.parent,
        prefix=f".{path.name}.",
        delete=False,
    ) as stream:
        staged = Path(stream.name)
        stream.write(payload)
        stream.flush()
        os.fsync(stream.fileno())
    try:
        os.replace(staged, path)
    except OSError:
        staged.unlink(missing_ok=True)
        raise


def resolve_confirmations(
    path: Path,
    legacy_files: set[str],
    current_digests: dict[str, str],
) -> dict[str, Confirmation]:
    """Validate confirmations against the recordings the ledger is about to emit."""
    resolved: dict[str, Confirmation] = {}
    for confirmation in load_confirmations(path):
        digest = current_digests.get(confirmation.file)
        if digest is None:
            raise ConfirmationError(
                f"confirmed recording has no audio: {confirmation.file}"
            )
        if confirmation.file in legacy_files:
            raise ConfirmationError(
                "recording is confirmed by both the legacy manifest and "
                f"{path.name}: {confirmation.file}"
            )
        if digest != confirmation.audio_sha256:
            raise ConfirmationError(
                f"{confirmation.file}: confirmed audio SHA-256 no longer matches; "
                f"confirmation={confirmation.audio_sha256}, recording={digest}"
            )
        resolved[confirmation.file] = confirmation
    return resolved


def required_string(where: str, row: dict[str, Any], key: str) -> str:
    value = row.get(key)
    if not isinstance(value, str) or not value.strip():
        raise ConfirmationError(f"{where} requires a non-empty string {key}")
    return value.strip()


def optional_string(where: str, row: dict[str, Any], key: str) -> str | None:
    if key not in row:
        raise ConfirmationError(f"{where} is missing {key}")
    value = row[key]
    if value is None:
        return None
    if not isinstance(value, str) or not value.strip():
        raise ConfirmationError(f"{where} requires a non-empty string or null {key}")
    return value.strip()


def required_sha256(where: str, row: dict[str, Any], key: str) -> str:
    value = row.get(key)
    if not isinstance(value, str) or SHA256_PATTERN.fullmatch(value) is None:
        raise ConfirmationError(f"{where} requires 64 lowercase hex characters in {key}")
    return value


def validate_recording_filename(where: str, file: str) -> None:
    if Path(file).name != file or not file.casefold().endswith(".wav"):
        raise ConfirmationError(f"{where} has an unsafe recording filename: {file}")
