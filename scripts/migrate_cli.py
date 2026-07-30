#!/usr/bin/env python3
"""Operator command that moves the Epos recording corpus out of purgeable Caches.

macOS may delete `~/Library/Caches` under disk pressure, so the frozen evaluation
corpus now lives in `~/Library/Application Support/Epos/recordings`. This command
performs the one-time move. It refuses rather than merges, and it never touches the
`corpus-backup` directory that sits beside the destination.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import os
from pathlib import Path
import subprocess
import sys
import tempfile

LABEL_FILENAMES = (
    "ground-truth.jsonl",
    "holdout-selection.json",
    "holdout-confirmations.jsonl",
)


class MigrateError(RuntimeError):
    """Refusal to migrate. Nothing has moved when this is raised."""


@dataclass(frozen=True)
class Plan:
    source: Path
    destination: Path
    recordings: tuple[Path, ...]
    labels: tuple[Path, ...]


def default_source() -> Path:
    return Path.home() / "Library" / "Caches" / "Epos" / "recordings"


def default_destination() -> Path:
    return Path.home() / "Library" / "Application Support" / "Epos" / "recordings"


def plan_migration(source: Path, destination: Path) -> Plan:
    if not source.is_dir():
        raise MigrateError(f"no recordings directory at {source}")
    entries = sorted(source.iterdir())
    recordings = tuple(
        entry for entry in entries if entry.is_file() and entry.suffix == ".wav"
    )
    labels = tuple(
        entry for entry in entries if entry.is_file() and entry.name in LABEL_FILENAMES
    )
    known = set(recordings) | set(labels)
    unexpected = [
        entry
        for entry in entries
        if entry not in known and not entry.name.startswith(".")
    ]
    if unexpected:
        listing = ", ".join(entry.name for entry in unexpected)
        raise MigrateError(
            f"{source} holds entries this command does not own: {listing}; "
            "move or delete them by hand, then re-run"
        )
    if not recordings:
        raise MigrateError(f"no .wav recordings under {source}")
    check_destination(destination)
    check_same_volume(source, destination)
    return Plan(
        source=source, destination=destination, recordings=recordings, labels=labels
    )


def check_destination(destination: Path) -> None:
    if not destination.is_dir():
        return
    existing = sorted(destination.iterdir())
    wavs = [entry for entry in existing if entry.is_file() and entry.suffix == ".wav"]
    if wavs:
        raise MigrateError(
            f"{destination} already holds {len(wavs)} .wav recordings; "
            "refusing to merge two corpora"
        )
    collisions = [entry.name for entry in existing if entry.name in LABEL_FILENAMES]
    if collisions:
        raise MigrateError(
            f"{destination} already holds {', '.join(sorted(collisions))}; "
            "refusing to overwrite"
        )


def check_same_volume(source: Path, destination: Path) -> None:
    anchor = destination
    while not anchor.exists():
        anchor = anchor.parent
    if os.stat(source).st_dev != os.stat(anchor).st_dev:
        raise MigrateError(
            f"{source} and {anchor} are on different volumes; "
            "copy the corpus by hand instead"
        )


def apply_migration(plan: Plan) -> tuple[int, int]:
    plan.destination.mkdir(parents=True, exist_ok=True)
    for path in plan.recordings + plan.labels:
        os.rename(path, plan.destination / path.name)
    if not any(plan.source.iterdir()):
        plan.source.rmdir()
    return len(plan.recordings), len(plan.labels)


def running_epos_pids() -> list[str]:
    result = subprocess.run(
        ["/usr/bin/pgrep", "-x", "Epos"],
        capture_output=True,
        text=True,
        check=False,
    )
    return result.stdout.split()


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Move the Epos recording corpus from ~/Library/Caches to "
            "~/Library/Application Support."
        )
    )
    parser.add_argument("--source", type=Path, default=default_source())
    parser.add_argument("--destination", type=Path, default=default_destination())
    parser.add_argument("--test", action="store_true")
    args = parser.parse_args()

    if args.test:
        from migrate_self_test import run_self_test

        with tempfile.TemporaryDirectory() as directory:
            run_self_test(Path(directory))
        print("migrate self-test passed")
        return 0

    pids = running_epos_pids()
    if pids:
        print(
            f"Epos is running (pid {', '.join(pids)}); quit it from the menu bar "
            "first so no recording lands in the old directory mid-move",
            file=sys.stderr,
        )
        return 1

    try:
        plan = plan_migration(args.source, args.destination)
        moved, labels = apply_migration(plan)
    except MigrateError as error:
        print(f"migrate: {error}", file=sys.stderr)
        return 1

    print(f"moved {moved} recordings and {labels} label files")
    print(f"  from {plan.source}")
    print(f"  to   {plan.destination}")
    backup = plan.destination.parent / "corpus-backup"
    if backup.is_dir():
        print(f"left untouched: {backup}")
    print("next: scripts/corpus --replace")
    return 0


if __name__ == "__main__":
    sys.exit(main())
