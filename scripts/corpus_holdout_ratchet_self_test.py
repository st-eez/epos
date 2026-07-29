"""Check that the committed confirmed-holdout ratchet detects a purged cache."""

from __future__ import annotations

from pathlib import Path

from corpus_holdout_self_test import digest, expect_error, ledger
from corpus_membership import (
    freeze_confirmed_ratchet,
    load_confirmed_ratchet,
    recording_identity_digest,
)
from holdout_confirmations import (
    append_confirmation,
    load_confirmations,
    remove_confirmation,
)


def run_self_test(
    root: Path,
    recordings: Path,
    manifest: Path,
    membership: Path,
    confirmations: Path,
) -> None:
    ratchet = root / "holdout-confirmed-recordings.sha256"
    confirmed = load_confirmations(confirmations)
    assert len(confirmed) == 2, confirmed
    assert load_confirmed_ratchet(ratchet) == set(), (
        "an absent ratchet file is the valid nothing-frozen-yet state"
    )
    assert ledger(recordings, manifest, membership, confirmations, ratchet=ratchet)

    assert freeze_confirmed_ratchet(ratchet, pairs(confirmed)) == (0, 2)
    assert load_confirmed_ratchet(ratchet) == {
        recording_identity_digest(row.file, row.audio_sha256) for row in confirmed
    }
    lines = ratchet.read_text(encoding="utf-8").splitlines()
    assert lines == sorted(lines) and len(lines) == 2, lines
    assert all(
        row.file not in line and row.human_intended_transcript not in line
        for row in confirmed
        for line in lines
    ), "the ratchet must carry no filenames and no transcripts"
    assert freeze_confirmed_ratchet(ratchet, pairs(confirmed)) == (2, 2), (
        "re-freezing an unchanged confirmation set is a no-op"
    )
    assert ledger(recordings, manifest, membership, confirmations, ratchet=ratchet)

    dropped = remove_confirmation(confirmations, confirmed[0].file)
    expect_error(
        lambda: ledger(recordings, manifest, membership, confirmations, ratchet=ratchet),
        "frozen as confirmed in holdout-confirmed-recordings.sha256 are missing",
    )
    remaining = pairs(load_confirmations(confirmations))
    expect_error(
        lambda: freeze_confirmed_ratchet(ratchet, remaining),
        "refusing to shrink the confirmed ratchet",
    )
    expect_error(
        lambda: freeze_confirmed_ratchet(ratchet, []),
        "no confirmations to freeze",
    )
    changed = [(dropped.file, digest("absent.wav")), *pairs([confirmed[1]])]
    expect_error(
        lambda: freeze_confirmed_ratchet(ratchet, changed),
        "refusing to shrink the confirmed ratchet",
    )
    append_confirmation(confirmations, dropped)
    assert ledger(recordings, manifest, membership, confirmations, ratchet=ratchet), (
        "restoring the confirmation must clear the ratchet failure"
    )


def pairs(confirmations) -> list[tuple[str, str]]:
    return [(row.file, row.audio_sha256) for row in confirmations]
