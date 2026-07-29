"""Check that confirmed holdout rows merge into the ledger and fail closed."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

from corpus_ledger import CorpusError, build_ledger
from corpus_membership import recording_identity_digest
from corpus_reader_self_test import holdout_row
from holdout_confirmations import (
    Confirmation,
    ConfirmationError,
    append_confirmation,
    load_confirmations,
)


AUDIO = {
    "confirmed.wav": b"confirmed audio",
    "inferred.wav": b"inferred audio",
    "unlabeled.wav": b"unlabeled audio",
    "spare.wav": b"spare audio",
}
SELECTION_SHA256 = "c" * 64


def run_self_test(root: Path) -> None:
    recordings = root / "holdout-recordings"
    recordings.mkdir()
    for name, content in AUDIO.items():
        (recordings / name).write_bytes(content)
    manifest = recordings / "ground-truth.jsonl"
    manifest.write_text(
        "".join(
            json.dumps({"file": name, "humanIntendedTranscript": f"Legacy {name}."})
            + "\n"
            for name in ("confirmed.wav", "inferred.wav")
        ),
        encoding="utf-8",
    )
    membership = root / "holdout-membership.sha256"
    membership.write_text(
        "\n".join(sorted(
            recording_identity_digest(name, digest(name))
            for name in AUDIO
        )) + "\n",
        encoding="utf-8",
    )
    confirmations = recordings / "holdout-confirmations.jsonl"

    baseline = ledger(recordings, manifest, membership, confirmations)
    assert {row["file"]: row["verificationStatus"] for row in baseline} == {
        "confirmed.wav": "human_confirmed",
        "inferred.wav": "inferred",
        "spare.wav": "unlabeled",
        "unlabeled.wav": "unlabeled",
    }, "an absent confirmations file must leave the ledger unchanged"

    append_confirmation(confirmations, confirmation("unlabeled.wav"))
    append_confirmation(confirmations, confirmation("spare.wav", edited=True))
    assert [row.file for row in load_confirmations(confirmations)] == [
        "unlabeled.wav", "spare.wav"
    ], "appends must preserve every earlier confirmation"

    rows = {
        row["file"]: row
        for row in ledger(recordings, manifest, membership, confirmations)
    }
    merged = rows["unlabeled.wav"]
    assert merged["verificationStatus"] == "human_confirmed"
    assert merged["legacyOrdinal"] is None
    assert merged["designation"] == "holdout"
    assert merged["transcriptCandidate"] == "Confirmed unlabeled.wav."
    assert merged["audioSHA256"] == digest("unlabeled.wav")
    assert set(merged) == set(holdout_row(("unlabeled.wav", "a" * 64, "text"))), (
        "the ledger must emit exactly the fields the strict reader validates"
    )
    assert rows["confirmed.wav"]["legacyOrdinal"] == 1
    assert "designation" not in rows["confirmed.wav"], (
        "legacy rows must stay byte-identical to the frozen migration"
    )

    expect_error(
        lambda: append_confirmation(confirmations, confirmation("unlabeled.wav")),
        "is already confirmed",
    )
    expect_error(
        lambda: load_confirmations(
            written(
                root / "unedited.jsonl",
                confirmation("unlabeled.wav", edited=True),
                edited=False,
            )
        ),
        "claims an unedited candidate but its transcript differs",
    )
    for row, message in (
        (confirmation("confirmed.wav"), "confirmed by both the legacy manifest"),
        (confirmation("absent.wav"), "confirmed recording has no audio"),
        (confirmation("unlabeled.wav", audio_sha256="d" * 64), "no longer matches"),
    ):
        path = written(root / "case.jsonl", row)
        expect_error(
            lambda path=path: ledger(recordings, manifest, membership, path),
            message,
        )


def confirmation(
    file: str,
    *,
    edited: bool = False,
    audio_sha256: str | None = None,
) -> Confirmation:
    transcript = f"Confirmed {file}."
    return Confirmation(
        file=file,
        audio_sha256=audio_sha256 or digest(file),
        human_intended_transcript=transcript,
        candidate_shown=None if edited else transcript,
        candidate_source=None if edited else "replay.jsonl",
        candidate_edited=edited,
        selection_sha256=SELECTION_SHA256,
    )


def written(path: Path, row: Confirmation, *, edited: bool | None = None) -> Path:
    payload = row.to_row()
    if edited is not None:
        payload["candidateEdited"] = edited
    path.write_text(json.dumps(payload) + "\n", encoding="utf-8")
    return path


def digest(name: str) -> str:
    return hashlib.sha256(AUDIO.get(name, b"absent")).hexdigest()


def ledger(
    recordings: Path,
    manifest: Path,
    membership: Path,
    confirmations: Path,
) -> list[dict]:
    return build_ledger(
        recordings,
        manifest,
        membership,
        confirmations,
        expected_manifest_sha256=hashlib.sha256(manifest.read_bytes()).hexdigest(),
        expected_legacy_rows=2,
        human_confirmed_rows=1,
        minimum_recordings=len(AUDIO),
        expected_frozen_rows=len(AUDIO),
    )


def expect_error(action, message: str) -> None:
    try:
        action()
    except (ConfirmationError, CorpusError) as error:
        assert message in str(error), (message, str(error))
    else:
        raise AssertionError(f"expected a failure containing {message!r}")
