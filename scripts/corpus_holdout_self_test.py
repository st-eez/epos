"""Check that confirmed holdout rows merge into the ledger and fail closed."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

from corpus_ledger import CorpusError, build_ledger
from corpus_membership import MembershipError, recording_identity_digest
from corpus_reader_self_test import holdout_row
from holdout_confirmations import (
    Confirmation,
    ConfirmationError,
    append_confirmation,
    load_confirmations,
)
from holdout_freeze import SELECTION_FILENAME, write_selection
from holdout_selection import SelectedRecording, Selection, finalize


AUDIO = {
    "confirmed.wav": b"confirmed audio",
    "inferred.wav": b"inferred audio",
    "unlabeled.wav": b"unlabeled audio",
    "spare.wav": b"spare audio",
}
FIXTURE_SELECTION_PATH = object()


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
    selection = recordings / SELECTION_FILENAME

    baseline = ledger(recordings, manifest, membership, confirmations)
    assert {row["file"]: row["verificationStatus"] for row in baseline} == {
        "confirmed.wav": "human_confirmed",
        "inferred.wav": "inferred",
        "spare.wav": "unlabeled",
        "unlabeled.wav": "unlabeled",
    }, "no confirmations and no frozen selection is the valid pre-session state"
    write_selection(selection, SELECTION, replace=False)

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
        (
            confirmation("unlabeled.wav", selection_sha256="d" * 64),
            "the confirmation is orphaned",
        ),
    ):
        path = written(root / "case.jsonl", row)
        expect_error(
            lambda path=path: ledger(recordings, manifest, membership, path),
            message,
        )
    expect_error(
        lambda: ledger(recordings, manifest, membership, confirmations, selection=None),
        "confirmations require the frozen selection path",
    )
    frozen = selection.read_text(encoding="utf-8")
    selection.unlink()
    expect_error(
        lambda: ledger(recordings, manifest, membership, confirmations),
        "confirmations exist but the frozen selection is missing",
    )
    selection.write_text(
        frozen.replace('"poolSize": 4', '"poolSize": 3'), encoding="utf-8"
    )
    expect_error(
        lambda: ledger(recordings, manifest, membership, confirmations),
        "was edited after freezing",
    )
    selection.write_text(frozen, encoding="utf-8")
    # Imported here: the ratchet test reuses this module's fixture helpers.
    from corpus_holdout_ratchet_self_test import run_self_test as run_ratchet_self_test

    run_ratchet_self_test(root, recordings, manifest, membership, confirmations)


def fixture_selection() -> Selection:
    """A real frozen selection, so its digest survives load_selection's checks."""
    return finalize(
        tuple(
            SelectedRecording(
                file=name,
                audio_sha256=digest(name),
                duration_seconds=1.0 + index,
                duration_stratum=1,
                chronological_stratum=1,
            )
            for index, name in enumerate(sorted(AUDIO))
        ),
        len(AUDIO),
        "a" * 64,
    )


def confirmation(
    file: str,
    *,
    edited: bool = False,
    audio_sha256: str | None = None,
    selection_sha256: str | None = None,
) -> Confirmation:
    transcript = f"Confirmed {file}."
    return Confirmation(
        file=file,
        audio_sha256=audio_sha256 or digest(file),
        human_intended_transcript=transcript,
        candidate_shown=None if edited else transcript,
        candidate_source=None if edited else "replay.jsonl",
        candidate_edited=edited,
        selection_sha256=selection_sha256 or SELECTION.sha256,
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
    *,
    selection: Path | None | object = FIXTURE_SELECTION_PATH,
    ratchet: Path | None = None,
) -> list[dict]:
    return build_ledger(
        recordings,
        manifest,
        membership,
        confirmations,
        (
            recordings / SELECTION_FILENAME
            if selection is FIXTURE_SELECTION_PATH else selection
        ),
        ratchet,
        expected_manifest_sha256=hashlib.sha256(manifest.read_bytes()).hexdigest(),
        expected_legacy_rows=2,
        human_confirmed_rows=1,
        minimum_recordings=len(AUDIO),
        expected_frozen_rows=len(AUDIO),
    )


def expect_error(action, message: str) -> None:
    try:
        action()
    except (ConfirmationError, CorpusError, MembershipError) as error:
        assert message in str(error), (message, str(error))
    else:
        raise AssertionError(f"expected a failure containing {message!r}")


SELECTION = fixture_selection()
