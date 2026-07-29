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
from holdout_confirmations import CONFIRMATIONS_FILENAME


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
    try:
        rows = build_ledger(
            recordings_directory=args.recordings,
            legacy_manifest=manifest,
            frozen_membership=args.frozen_membership,
            confirmations=confirmations,
        )
        validate_output_path(args.output, args.recordings, manifest)
        write_ledger(args.output, rows, replace=args.replace)
    except (CorpusError, OSError) as error:
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


if __name__ == "__main__":
    raise SystemExit(main())
