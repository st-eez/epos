#!/usr/bin/env python3
"""Operator command for confirming the frozen Epos holdout by listening."""

from __future__ import annotations

import argparse
from pathlib import Path
import sys
import tempfile

from confirm_candidates import discover_candidates
from confirm_plan import format_plan
from confirm_session import SessionError, run_session, terminal_io
from corpus_reader import Corpus, CorpusReadError, load_corpus
from holdout_confirmations import (
    Confirmation,
    ConfirmationError,
    default_confirmations_path,
    load_confirmations,
)
from holdout_freeze import (
    default_selection_path,
    load_selection,
    validate_selection,
    write_selection,
)
from holdout_selection import (
    SELECTION_SIZE,
    Selection,
    SelectionError,
    compute_selection,
)


def parser() -> argparse.ArgumentParser:
    repo_root = Path(__file__).resolve().parent.parent
    recordings_default = Path.home() / "Library" / "Caches" / "Epos" / "recordings"
    result = argparse.ArgumentParser(
        description=(
            "Freeze a 40-recording holdout and confirm each transcript by listening."
        )
    )
    result.add_argument("--recordings", type=Path, default=recordings_default)
    result.add_argument(
        "--corpus",
        type=Path,
        default=repo_root / ".build" / "evals" / "evaluation-corpus-v2.jsonl",
    )
    result.add_argument("--selection", type=Path, help="frozen holdout selection JSON")
    result.add_argument("--confirmations", type=Path, help="confirmation JSONL")
    result.add_argument(
        "--artifact",
        type=Path,
        help="replay artifact for candidate prefill; defaults to the newest in .build/evals",
    )
    result.add_argument("--size", type=int, default=SELECTION_SIZE)
    result.add_argument(
        "--plan",
        action="store_true",
        help="print the selection and exit without writing anything",
    )
    result.add_argument(
        "--reselect",
        action="store_true",
        help="discard an unused frozen selection and recompute it",
    )
    result.add_argument("--test", action="store_true")
    return result


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    if args.test:
        from confirm_self_test import run_self_test

        with tempfile.TemporaryDirectory(prefix="epos-confirm-") as directory:
            run_self_test(Path(directory))
        print("confirm self-test passed")
        return 0

    repo_root = Path(__file__).resolve().parent.parent
    recordings = args.recordings.expanduser()
    selection_path = args.selection or default_selection_path(recordings)
    confirmations_path = args.confirmations or default_confirmations_path(recordings)
    try:
        validate_output_path(selection_path, recordings, repo_root)
        validate_output_path(confirmations_path, recordings, repo_root)
        corpus = load_corpus(args.corpus.expanduser())
        confirmations = load_confirmations(confirmations_path)
        frozen = selection_path.is_file() and not args.reselect
        selection, notes = resolve_selection(
            selection_path, corpus, recordings, args, confirmations
        )
        if args.plan:
            print(format_plan(selection, selection_path, args.corpus, notes, frozen))
            return 0
        for note in notes:
            print(f"note: {note}")
        if not frozen:
            write_selection(selection_path, selection, replace=args.reselect)
        return confirm(
            repo_root, recordings, selection, confirmations_path, confirmations, args
        )
    except (
        ConfirmationError,
        CorpusReadError,
        SelectionError,
        SessionError,
        OSError,
    ) as error:
        print(f"confirm: {error}", file=sys.stderr)
        return 1


def resolve_selection(
    selection_path: Path,
    corpus: Corpus,
    recordings: Path,
    args: argparse.Namespace,
    confirmations: list[Confirmation],
) -> tuple[Selection, list[str]]:
    exists = selection_path.is_file()
    if args.reselect and confirmations:
        raise SelectionError(
            f"{len(confirmations)} recordings are already confirmed; "
            "--reselect would invalidate them"
        )
    if exists and not args.reselect:
        selection = load_selection(selection_path)
        return selection, validate_selection(selection, corpus, recordings)
    return compute_selection(corpus, recordings, size=args.size), []


def confirm(
    repo_root: Path,
    recordings: Path,
    selection: Selection,
    confirmations_path: Path,
    confirmations: list[Confirmation],
    args: argparse.Namespace,
) -> int:
    digests = {
        recording.file: recording.audio_sha256 for recording in selection.recordings
    }
    candidates = discover_candidates(repo_root, digests, args.artifact)
    if candidates.reason:
        print(f"no candidate prefill ({candidates.reason}); type every transcript")
    print(
        f"holdout: {len(selection.recordings)} recordings, "
        f"{len(confirmations)} already confirmed. "
        "Listen, then accept or correct the candidate."
    )
    summary = run_session(
        selection,
        recordings,
        confirmations_path,
        candidates.transcripts,
        candidates.source,
        terminal_io(),
        confirmed_files=frozenset(row.file for row in confirmations),
    )
    print("")
    print(
        f"confirmed {summary.confirmed} ({summary.accepted} accepted, "
        f"{summary.edited} corrected), skipped {summary.skipped}, "
        f"{summary.remaining} left"
    )
    print(f"confirmations: {confirmations_path}")
    if summary.remaining:
        print("rerun scripts/confirm to continue where you stopped")
    else:
        print("run scripts/corpus --replace to fold them into the ledger")
    return 0


def validate_output_path(output: Path, recordings: Path, repo_root: Path) -> None:
    resolved = output.resolve()
    if not resolved.is_relative_to(recordings.resolve()):
        raise SelectionError(f"output must live in the recordings directory: {output}")
    if resolved.is_relative_to(repo_root.resolve()):
        raise SelectionError(f"output must not resolve inside the repository: {output}")
    if resolved.suffix.casefold() == ".wav" or resolved.name == "ground-truth.jsonl":
        raise SelectionError(f"output must not replace corpus audio or labels: {output}")


if __name__ == "__main__":
    raise SystemExit(main())
