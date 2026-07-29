"""Validate the privacy-safe frozen recording membership set."""

from __future__ import annotations

import hashlib
from pathlib import Path
import re


FROZEN_MEMBERSHIP_ROWS = 347
DIGEST_PATTERN = re.compile(r"[0-9a-f]{64}")


class MembershipError(Exception):
    """The frozen membership file is malformed."""


def load_frozen_membership(
    path: Path,
    *,
    expected_rows: int = FROZEN_MEMBERSHIP_ROWS,
) -> set[str]:
    if not path.is_file():
        raise MembershipError(f"frozen membership file does not exist: {path}")
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
    if len(digests) != expected_rows:
        raise MembershipError(
            f"frozen membership must contain {expected_rows} rows; "
            f"found {len(digests)}"
        )
    if len(set(digests)) != len(digests):
        raise MembershipError("frozen membership contains duplicate digests")
    if digests != sorted(digests):
        raise MembershipError("frozen membership digests must be sorted")
    return set(digests)


def recording_identity_digest(filename: str, audio_sha256: str) -> str:
    identity = filename.encode("utf-8") + b"\0" + audio_sha256.encode("ascii")
    return hashlib.sha256(identity).hexdigest()
