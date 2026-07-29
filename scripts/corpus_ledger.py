"""Load, validate, and write the Epos evaluation-corpus v2 ledger."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import tempfile
from typing import Any

from corpus_membership import (
    FROZEN_MEMBERSHIP_ROWS,
    MembershipError,
    load_frozen_membership,
    recording_identity_digest,
)


SCHEMA_VERSION = 2
EXPECTED_MANIFEST_SHA256 = (
    "85a0ed532a232afe20df37a05c8d973cbe890300547bbb868ab97127b7f68bc1"
)
EXPECTED_LEGACY_ROWS = 114
HUMAN_CONFIRMED_ROWS = 35
MINIMUM_RECORDINGS = 347
SAFE_RECORDING_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*\.wav")


class CorpusError(Exception):
    """A corpus input failed a provenance or safety invariant."""


def build_ledger(
    recordings_directory: Path,
    legacy_manifest: Path,
    frozen_membership: Path,
    *,
    expected_manifest_sha256: str = EXPECTED_MANIFEST_SHA256,
    expected_legacy_rows: int = EXPECTED_LEGACY_ROWS,
    human_confirmed_rows: int = HUMAN_CONFIRMED_ROWS,
    minimum_recordings: int = MINIMUM_RECORDINGS,
    expected_frozen_rows: int = FROZEN_MEMBERSHIP_ROWS,
) -> list[dict[str, Any]]:
    manifest_rows = load_legacy_manifest(
        legacy_manifest,
        expected_sha256=expected_manifest_sha256,
        expected_rows=expected_legacy_rows,
    )
    if human_confirmed_rows < 0 or human_confirmed_rows > expected_legacy_rows:
        raise CorpusError("human-confirmed row boundary is invalid")
    audio_paths = load_audio_paths(recordings_directory)
    if len(audio_paths) < minimum_recordings:
        raise CorpusError(
            "recording count fell below frozen floor; expected at least "
            f"{minimum_recordings}, found {len(audio_paths)}"
        )
    manifest_by_file: dict[str, tuple[int, str]] = {}
    for ordinal, row in enumerate(manifest_rows, start=1):
        name = required_nonempty_string(row, "file", legacy_manifest, ordinal)
        validate_recording_name(name)
        transcript = required_nonempty_string(
            row,
            "humanIntendedTranscript",
            legacy_manifest,
            ordinal,
        )
        if name in manifest_by_file:
            raise CorpusError(f"{legacy_manifest}: duplicate legacy file {name}")
        manifest_by_file[name] = (ordinal, transcript)
    audio_by_file = {path.name: path for path in audio_paths}
    stale_labels = set(manifest_by_file) - set(audio_by_file)
    if stale_labels:
        raise CorpusError(
            "legacy labels have no recording: " + ", ".join(sorted(stale_labels))
        )
    rows: list[dict[str, Any]] = []
    for name, audio_path in sorted(audio_by_file.items()):
        legacy = manifest_by_file.get(name)
        if legacy is None:
            transcript: str | None = None
            status = "unlabeled"
            legacy_ordinal: int | None = None
        else:
            legacy_ordinal, transcript = legacy
            status = (
                "human_confirmed"
                if legacy_ordinal <= human_confirmed_rows
                else "inferred"
            )
        rows.append({
            "schemaVersion": SCHEMA_VERSION,
            "file": name,
            "audioSHA256": file_sha256(audio_path),
            "transcriptCandidate": transcript,
            "verificationStatus": status,
            "legacyOrdinal": legacy_ordinal,
        })
    if len({row["file"] for row in rows}) != len(rows):
        raise CorpusError("generated ledger contains duplicate recordings")
    try:
        frozen_digests = load_frozen_membership(
            frozen_membership,
            expected_rows=expected_frozen_rows,
        )
    except MembershipError as error:
        raise CorpusError(str(error)) from error
    current_digests = {
        recording_identity_digest(row["file"], row["audioSHA256"])
        for row in rows
    }
    missing_frozen = frozen_digests - current_digests
    if missing_frozen:
        raise CorpusError(
            f"{len(missing_frozen)} frozen recordings are missing or changed"
        )
    return rows


def load_legacy_manifest(
    path: Path,
    *,
    expected_sha256: str,
    expected_rows: int,
) -> list[dict[str, Any]]:
    if not path.is_file():
        raise CorpusError(f"legacy manifest does not exist: {path}")
    raw = path.read_bytes()
    actual_sha256 = hashlib.sha256(raw).hexdigest()
    if actual_sha256 != expected_sha256:
        raise CorpusError(
            "legacy manifest SHA-256 changed; expected "
            f"{expected_sha256}, found {actual_sha256}"
        )
    rows: list[dict[str, Any]] = []
    for line_number, raw_line in enumerate(raw.decode("utf-8").splitlines(), start=1):
        if not raw_line.strip():
            continue
        try:
            decoded = json.loads(raw_line)
        except json.JSONDecodeError as error:
            raise CorpusError(
                f"{path}: line {line_number} is not valid JSON: {error.msg}"
            ) from error
        if not isinstance(decoded, dict):
            raise CorpusError(f"{path}: line {line_number} must be a JSON object")
        rows.append(decoded)
    if len(rows) != expected_rows:
        raise CorpusError(
            f"legacy manifest must contain {expected_rows} rows; found {len(rows)}"
        )
    return rows


def load_audio_paths(recordings_directory: Path) -> list[Path]:
    if not recordings_directory.is_dir():
        raise CorpusError(
            f"recordings directory does not exist: {recordings_directory}"
        )
    paths: list[Path] = []
    casefolded_names: set[str] = set()
    for item in recordings_directory.iterdir():
        if item.suffix.casefold() != ".wav":
            continue
        validate_recording_name(item.name)
        if item.is_symlink() or not item.is_file():
            raise CorpusError(f"recording must be a regular file: {item.name}")
        folded = item.name.casefold()
        if folded in casefolded_names:
            raise CorpusError(f"duplicate recording filename: {item.name}")
        casefolded_names.add(folded)
        paths.append(item)
    return paths


def validate_recording_name(name: str) -> None:
    if not SAFE_RECORDING_NAME.fullmatch(name):
        raise CorpusError(f"unsafe recording filename: {name!r}")
    if Path(name).name != name or name in {".wav", "..wav"}:
        raise CorpusError(f"unsafe recording filename: {name!r}")


def required_nonempty_string(
    row: dict[str, Any],
    key: str,
    source: Path,
    ordinal: int,
) -> str:
    value = row.get(key)
    if not isinstance(value, str) or not value.strip():
        raise CorpusError(
            f"{source}: legacy row {ordinal} requires non-empty string {key}"
        )
    return value


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def validate_output_path(
    output: Path,
    recordings_directory: Path,
    legacy_manifest: Path,
) -> None:
    resolved_output = output.resolve()
    resolved_recordings = recordings_directory.resolve()
    if resolved_output.is_relative_to(resolved_recordings):
        raise CorpusError("output must not be inside the recordings directory")
    if resolved_output == legacy_manifest.resolve():
        raise CorpusError("output must not replace the legacy manifest")


def write_ledger(
    output: Path,
    rows: list[dict[str, Any]],
    *,
    replace: bool,
) -> None:
    if output.exists() and not replace:
        raise CorpusError(f"output exists; pass --replace to overwrite: {output}")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        dir=output.parent,
        prefix=f".{output.name}.",
        delete=False,
    ) as stream:
        staged = Path(stream.name)
        for row in rows:
            stream.write(json.dumps(row, ensure_ascii=False, separators=(",", ":")))
            stream.write("\n")
    try:
        if replace:
            os.replace(staged, output)
        else:
            try:
                os.link(staged, output)
            except FileExistsError as error:
                raise CorpusError(
                    f"output exists; pass --replace to overwrite: {output}"
                ) from error
    finally:
        staged.unlink(missing_ok=True)
