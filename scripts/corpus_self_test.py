"""Self-test the evaluation corpus ledger without touching saved recordings."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

from corpus_ledger import (
    CorpusError,
    build_ledger,
    validate_output_path,
    write_ledger,
)
from corpus_holdout_self_test import run_self_test as run_holdout_self_test
from corpus_membership import recording_identity_digest
from corpus_reader_self_test import run_self_test as run_reader_self_test


def run_self_test(root: Path) -> None:
    run_reader_self_test(root)
    run_holdout_self_test(root)
    recordings = root / "recordings"
    recordings.mkdir()
    audio = {
        "confirmed.wav": b"confirmed audio",
        "inferred.wav": b"inferred audio",
        "unlabeled.wav": b"unlabeled audio",
    }
    for name, content in audio.items():
        (recordings / name).write_bytes(content)
    manifest = recordings / "ground-truth.jsonl"
    manifest_rows = [
        {
            "file": "confirmed.wav",
            "humanIntendedTranscript": "Human transcript.",
        },
        {
            "file": "inferred.wav",
            "humanIntendedTranscript": "Inferred transcript.",
        },
    ]
    manifest.write_text(
        "".join(json.dumps(row) + "\n" for row in manifest_rows),
        encoding="utf-8",
    )
    manifest_sha256 = hashlib.sha256(manifest.read_bytes()).hexdigest()
    membership = root / "frozen-recordings.sha256"
    write_membership(membership, audio)
    rows = fixture_ledger(recordings, manifest, membership, manifest_sha256)
    assert len(rows) == 3
    by_file = {row["file"]: row for row in rows}
    assert by_file["confirmed.wav"]["verificationStatus"] == "human_confirmed"
    assert by_file["confirmed.wav"]["legacyOrdinal"] == 1
    assert by_file["inferred.wav"]["verificationStatus"] == "inferred"
    assert by_file["inferred.wav"]["legacyOrdinal"] == 2
    assert by_file["unlabeled.wav"]["verificationStatus"] == "unlabeled"
    assert by_file["unlabeled.wav"]["transcriptCandidate"] is None
    assert by_file["unlabeled.wav"]["legacyOrdinal"] is None
    assert by_file["confirmed.wav"]["audioSHA256"] == hashlib.sha256(
        audio["confirmed.wav"]
    ).hexdigest()
    assert all(row["schemaVersion"] == 2 for row in rows)
    output = root / "output" / "ledger.jsonl"
    write_ledger(output, rows, replace=False)
    expect_error(
        lambda: write_ledger(output, rows, replace=False),
        "pass --replace",
    )
    write_ledger(output, rows, replace=True)
    persisted = [
        json.loads(line) for line in output.read_text(encoding="utf-8").splitlines()
    ]
    assert persisted == rows
    original_manifest = manifest.read_bytes()
    manifest.write_bytes(original_manifest + b"\n")
    expect_error(
        lambda: fixture_ledger(recordings, manifest, membership, manifest_sha256),
        "manifest SHA-256 changed",
    )
    manifest.write_bytes(original_manifest)
    expect_error(
        lambda: custom_ledger(
            recordings,
            manifest,
            membership,
            expected_legacy_rows=3,
        ),
        "must contain 3 rows",
    )
    duplicate_manifest = root / "duplicate.jsonl"
    duplicate_rows = [manifest_rows[0], manifest_rows[0]]
    duplicate_manifest.write_text(
        "".join(json.dumps(row) + "\n" for row in duplicate_rows),
        encoding="utf-8",
    )
    expect_error(
        lambda: custom_ledger(
            recordings,
            duplicate_manifest,
            membership,
            expected_legacy_rows=2,
        ),
        "duplicate legacy file",
    )
    missing_transcript = root / "missing-transcript.jsonl"
    missing_transcript.write_text(
        json.dumps({"file": "confirmed.wav"}) + "\n",
        encoding="utf-8",
    )
    expect_error(
        lambda: custom_ledger(
            recordings,
            missing_transcript,
            membership,
            expected_legacy_rows=1,
        ),
        "requires non-empty string humanIntendedTranscript",
    )
    stale_manifest = root / "stale.jsonl"
    stale_manifest.write_text(
        json.dumps({
            "file": "missing.wav",
            "humanIntendedTranscript": "Missing audio.",
        }) + "\n",
        encoding="utf-8",
    )
    expect_error(
        lambda: custom_ledger(
            recordings,
            stale_manifest,
            membership,
            expected_legacy_rows=1,
        ),
        "legacy labels have no recording",
    )
    unsafe_manifest = root / "unsafe.jsonl"
    unsafe_manifest.write_text(
        json.dumps({
            "file": "../confirmed.wav",
            "humanIntendedTranscript": "Unsafe.",
        }) + "\n",
        encoding="utf-8",
    )
    expect_error(
        lambda: custom_ledger(
            recordings,
            unsafe_manifest,
            membership,
            expected_legacy_rows=1,
        ),
        "unsafe recording filename",
    )
    (recordings / "extra.wav").write_bytes(b"extra")
    expanded_rows = fixture_ledger(
        recordings,
        manifest,
        membership,
        manifest_sha256,
    )
    assert len(expanded_rows) == 4
    assert next(
        row for row in expanded_rows if row["file"] == "extra.wav"
    )["verificationStatus"] == "unlabeled"
    (recordings / "extra.wav").unlink()
    (recordings / "unlabeled.wav").unlink()
    (recordings / "replacement.wav").write_bytes(b"replacement")
    expect_error(
        lambda: fixture_ledger(recordings, manifest, membership, manifest_sha256),
        "1 frozen recordings are missing or changed",
    )
    (recordings / "replacement.wav").unlink()
    (recordings / "unlabeled.wav").write_bytes(audio["unlabeled.wav"])
    (recordings / "unlabeled.wav").unlink()
    expect_error(
        lambda: fixture_ledger(recordings, manifest, membership, manifest_sha256),
        "fell below frozen floor",
    )
    (recordings / "unlabeled.wav").write_bytes(audio["unlabeled.wav"])
    unsafe_audio = recordings / "bad name.wav"
    unsafe_audio.write_bytes(b"unsafe")
    expect_error(
        lambda: fixture_ledger(recordings, manifest, membership, manifest_sha256),
        "unsafe recording filename",
    )
    unsafe_audio.unlink()
    symlink_audio = recordings / "linked.wav"
    symlink_audio.symlink_to(recordings / "confirmed.wav")
    expect_error(
        lambda: fixture_ledger(recordings, manifest, membership, manifest_sha256),
        "must be a regular file",
    )
    symlink_audio.unlink()
    expect_error(
        lambda: validate_output_path(
            recordings / "ledger.jsonl",
            recordings,
            manifest,
        ),
        "must not be inside",
    )
def fixture_ledger(
    recordings: Path,
    manifest: Path,
    membership: Path,
    manifest_sha256: str,
) -> list[dict]:
    return build_ledger(
        recordings,
        manifest,
        membership,
        expected_manifest_sha256=manifest_sha256,
        expected_legacy_rows=2,
        human_confirmed_rows=1,
        minimum_recordings=3,
        expected_frozen_rows=3,
    )


def custom_ledger(
    recordings: Path,
    manifest: Path,
    membership: Path,
    *,
    expected_legacy_rows: int,
) -> list[dict]:
    return build_ledger(
        recordings,
        manifest,
        membership,
        expected_manifest_sha256=hashlib.sha256(manifest.read_bytes()).hexdigest(),
        expected_legacy_rows=expected_legacy_rows,
        human_confirmed_rows=1,
        minimum_recordings=3,
        expected_frozen_rows=3,
    )


def write_membership(path: Path, audio: dict[str, bytes]) -> None:
    digests = sorted(
        recording_identity_digest(name, hashlib.sha256(content).hexdigest())
        for name, content in audio.items()
    )
    path.write_text("\n".join(digests) + "\n", encoding="utf-8")


def expect_error(action, message: str) -> None:
    try:
        action()
    except CorpusError as error:
        assert message in str(error), (message, str(error))
    else:
        raise AssertionError(f"expected CorpusError containing {message!r}")
