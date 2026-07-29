"""Privacy-safe frozen digest sets: corpus membership and confirmed holdout rows.

Both files hold nothing but sorted `SHA256(UTF8(filename) + NUL + audio SHA-256)`
lines, so they can be committed without leaking filenames, audio, or transcripts.
"""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
import re
import tempfile
from typing import Iterable


FROZEN_MEMBERSHIP_ROWS = 347
CONFIRMED_RATCHET_FILENAME = "holdout-confirmed-recordings.sha256"
DIGEST_PATTERN = re.compile(r"[0-9a-f]{64}")


class MembershipError(Exception):
    """A frozen digest file is malformed, or a frozen recording went missing."""


def load_frozen_membership(
    path: Path,
    *,
    expected_rows: int = FROZEN_MEMBERSHIP_ROWS,
) -> set[str]:
    if not path.is_file():
        raise MembershipError(f"frozen membership file does not exist: {path}")
    digests = load_digest_lines(path)
    if len(digests) != expected_rows:
        raise MembershipError(
            f"frozen membership must contain {expected_rows} rows; "
            f"found {len(digests)}"
        )
    return set(digests)


def load_digest_lines(path: Path) -> list[str]:
    digests: list[str] = []
    for line_number, raw_line in enumerate(
        path.read_text(encoding="utf-8").splitlines(),
        start=1,
    ):
        digest = raw_line.strip()
        if not DIGEST_PATTERN.fullmatch(digest):
            raise MembershipError(
                f"{path}: line {line_number} must be a lowercase SHA-256 digest"
            )
        digests.append(digest)
    if len(set(digests)) != len(digests):
        raise MembershipError(f"{path.name} contains duplicate digests")
    if digests != sorted(digests):
        raise MembershipError(f"{path.name} digests must be sorted")
    return digests


def load_confirmed_ratchet(path: Path) -> set[str]:
    """Digests already merged as confirmed holdout rows; absent means none yet."""
    if not path.is_file():
        return set()
    return set(load_digest_lines(path))


def ratchet_digests(recordings: Iterable[tuple[str, str]]) -> set[str]:
    """Identity digests for (filename, audio SHA-256) pairs."""
    return {
        recording_identity_digest(file, audio_sha256)
        for file, audio_sha256 in recordings
    }


def validate_confirmed_ratchet(
    path: Path,
    recordings: Iterable[tuple[str, str]],
) -> None:
    """Fail closed when a recording the repo says is confirmed is no longer.

    Confirmations live in a purgeable cache, so without this a purge would
    silently revert confirmed holdout rows to unlabeled.
    """
    missing = load_confirmed_ratchet(path) - ratchet_digests(recordings)
    if missing:
        raise MembershipError(
            f"{len(missing)} recordings frozen as confirmed in {path.name} are "
            "missing from the confirmations file or their audio changed; restore "
            "the confirmations before rebuilding the ledger"
        )


def freeze_confirmed_ratchet(
    path: Path,
    recordings: Iterable[tuple[str, str]],
) -> tuple[int, int]:
    """Grow the ratchet to cover every current confirmation; never shrink it."""
    frozen = load_confirmed_ratchet(path)
    current = ratchet_digests(recordings)
    if not current:
        raise MembershipError("there are no confirmations to freeze")
    lost = frozen - current
    if lost:
        raise MembershipError(
            f"refusing to shrink the confirmed ratchet: {len(lost)} of "
            f"{len(frozen)} frozen recordings are absent from the confirmations"
        )
    write_digest_lines(path, current)
    return len(frozen), len(current)


def write_digest_lines(path: Path, digests: set[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        dir=path.parent,
        prefix=f".{path.name}.",
        delete=False,
    ) as stream:
        staged = Path(stream.name)
        stream.write("".join(f"{digest}\n" for digest in sorted(digests)))
        stream.flush()
        os.fsync(stream.fileno())
    try:
        os.replace(staged, path)
    except OSError:
        staged.unlink(missing_ok=True)
        raise


def recording_identity_digest(filename: str, audio_sha256: str) -> str:
    identity = filename.encode("utf-8") + b"\0" + audio_sha256.encode("ascii")
    return hashlib.sha256(identity).hexdigest()
