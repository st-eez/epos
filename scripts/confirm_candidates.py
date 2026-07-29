"""Prefill confirmation candidates from the newest production replay artifact."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from label_artifact import PRODUCTION_ALTERNATIVES, load_rows
from label_cli import discover_input
from label_queue import LabelQueueError


@dataclass(frozen=True)
class CandidateSet:
    """Production-pipeline transcripts keyed by recording, plus their source."""

    transcripts: dict[str, str]
    source: str | None
    reason: str | None


def discover_candidates(
    repo_root: Path,
    digests_by_file: dict[str, str],
    artifact: Path | None = None,
) -> CandidateSet:
    """Read the production arm, keeping only rows whose audio digest still matches.

    A missing or stale artifact is not an error: the operator then types every
    transcript, which is slower but never lets unverified text become truth.
    """
    try:
        path = artifact or discover_input(repo_root)
        rows, _ = load_rows(path)
    except (LabelQueueError, OSError) as error:
        return CandidateSet({}, None, str(error))
    transcripts: dict[str, str] = {}
    for row in rows:
        if row.get("variant") != PRODUCTION_ALTERNATIVES:
            continue
        file = row.get("file")
        if not isinstance(file, str) or digests_by_file.get(file) is None:
            continue
        if row.get("audioSHA256") != digests_by_file[file]:
            continue
        text = row.get("variantCanonicalized")
        if isinstance(text, str) and text.strip():
            transcripts[file] = text.strip()
    return CandidateSet(transcripts, path.name, None)
