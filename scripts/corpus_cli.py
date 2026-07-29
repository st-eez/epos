#!/usr/bin/env python3
"""Operator command for the frozen Epos evaluation-corpus v2 ledger."""

from __future__ import annotations

import argparse
from pathlib import Path
import sys
import tempfile

from corpus_ledger import (
    CorpusError,
    build_ledger,
    validate_output_path,
    write_ledger,
)
from corpus_membership import (
    CONFIRMED_RATCHET_FILENAME,
    MembershipError,
    freeze_confirmed_ratchet,
)
from holdout_confirmations import (
    CONFIRMATIONS_FILENAME,
    ConfirmationError,
    load_confirmations,
)
from holdout_freeze import SELECTION_FILENAME


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    recordings_default = Path.home() / "Library" / "Caches" / "Epos" / "recordings"
    parser = argparse.ArgumentParser(
        description="Build a provenance-aware ledger for the frozen Epos audio corpus."
    )
    parser.add_argument(
        "--recordings",
        type=Path,
        default=recordings_default,
    )
    parser.add_argument(
        "--manifest",
        type=Path,
        help="legacy manifest; defaults to RECORDINGS/ground-truth.jsonl",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=repo_root / ".build" / "evals" / "evaluation-corpus-v2.jsonl",
    )
    parser.add_argument(
        "--frozen-membership",
        type=Path,
        default=repo_root / "specs" / "evaluation-corpus-frozen-recordings.sha256",
    )
    parser.add_argument(
        "--confirmations",
        type=Path,
        help=(
            "holdout confirmations from scripts/confirm; defaults to "
            f"RECORDINGS/{CONFIRMATIONS_FILENAME} and may be absent"
        ),
    )
    parser.add_argument(
        "--selection",
        type=Path,
        help=(
            "frozen holdout selection every confirmation must belong to; "
            f"defaults to RECORDINGS/{SELECTION_FILENAME}"
        ),
    )
    parser.add_argument(
        "--confirmed-ratchet",
        type=Path,
        default=repo_root / "specs" / CONFIRMED_RATCHET_FILENAME,
        help="repo-committed floor of already-merged holdout confirmations",
    )
    parser.add_argument(
        "--freeze-confirmations",
        action="store_true",
        help=(
            "validate everything, then record the current confirmations in the "
            "ratchet file so a purged confirmations file fails closed"
        ),
    )
    parser.add_argument("--replace", action="store_true")
    parser.add_argument("--test", action="store_true")
    args = parser.parse_args()

    if args.test:
        from corpus_self_test import run_self_test

        with tempfile.TemporaryDirectory() as directory:
            run_self_test(Path(directory))
        print("corpus self-test passed")
        return 0

    manifest = args.manifest or args.recordings / "ground-truth.jsonl"
    confirmations = args.confirmations or args.recordings / CONFIRMATIONS_FILENAME
    selection = args.selection or args.recordings / SELECTION_FILENAME
    try:
        rows = build_ledger(
            recordings_directory=args.recordings,
            legacy_manifest=manifest,
            frozen_membership=args.frozen_membership,
            confirmations=confirmations,
            selection=selection,
            confirmed_ratchet=args.confirmed_ratchet,
        )
        if args.freeze_confirmations:
            return freeze_confirmations(args.confirmed_ratchet, confirmations)
        validate_output_path(args.output, args.recordings, manifest)
        write_ledger(args.output, rows, replace=args.replace)
    except (CorpusError, ConfirmationError, MembershipError, OSError) as error:
        print(f"corpus: {error}", file=sys.stderr)
        return 1

    counts = {
        status: sum(row["verificationStatus"] == status for row in rows)
        for status in ("human_confirmed", "inferred", "unlabeled")
    }
    holdout = sum(row.get("designation") == "holdout" for row in rows)
    print(
        f"wrote {len(rows)} recordings: "
        f"{counts['human_confirmed']} human-confirmed "
        f"({counts['human_confirmed'] - holdout} legacy, {holdout} holdout), "
        f"{counts['inferred']} inferred, {counts['unlabeled']} unlabeled"
    )
    print(f"ledger: {args.output}")
    return 0


def freeze_confirmations(ratchet: Path, confirmations: Path) -> int:
    """Ratchet the confirmations a full validated build just accepted."""
    rows = load_confirmations(confirmations)
    before, after = freeze_confirmed_ratchet(
        ratchet, [(row.file, row.audio_sha256) for row in rows]
    )
    print(f"froze {after} confirmed holdout recordings ({after - before} new)")
    print(f"ratchet: {ratchet}")
    print("commit that file: it is the only floor under the confirmations cache")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
