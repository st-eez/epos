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
    remove_confirmation,
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
    result.add_argument(
        "--reconfirm",
        metavar="FILE",
        help="drop one recording's confirmation and confirm it again",
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
        if args.reconfirm and not confirmations:
            raise ConfirmationError(
                f"nothing is confirmed yet, so {args.reconfirm} cannot be redone"
            )
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
        if args.reconfirm:
            confirmations = reopen(
                confirmations_path, confirmations, selection, args.reconfirm
            )
            print(f"dropped the confirmation for {args.reconfirm}; confirming it again")
        return confirm(
            repo_root,
            recordings,
            selection,
            confirmations_path,
            confirmations,
            args,
            only=args.reconfirm,
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
    if confirmations and not exists:
        raise SelectionError(
            f"{len(confirmations)} recordings are confirmed but the frozen "
            f"selection is missing: {selection_path}. Computing a new one would "
            "orphan every confirmation, so nothing was written. Restore that file "
            "from a backup; the recordings directory is a purgeable macOS cache."
        )
    if exists and not args.reselect:
        selection = load_selection(selection_path)
        orphans = [
            row.file for row in confirmations
            if row.selection_sha256 != selection.sha256
        ]
        if orphans:
            raise SelectionError(
                f"{len(orphans)} confirmations were made under a different holdout "
                f"selection than {selection_path.name} freezes; restore the "
                "selection those confirmations belong to"
            )
        return selection, validate_selection(selection, corpus, recordings)
    return compute_selection(corpus, recordings, size=args.size), []


def reopen(
    confirmations_path: Path,
    confirmations: list[Confirmation],
    selection: Selection,
    file: str,
) -> list[Confirmation]:
    """Drop one confirmation so it can be redone, keeping every other row."""
    if all(recording.file != file for recording in selection.recordings):
        raise SelectionError(f"{file} is not in the frozen holdout")
    if all(row.file != file for row in confirmations):
        raise ConfirmationError(f"{file} is not confirmed; there is nothing to redo")
    remove_confirmation(confirmations_path, file)
    return [row for row in confirmations if row.file != file]


def confirm(
    repo_root: Path,
    recordings: Path,
    selection: Selection,
    confirmations_path: Path,
    confirmations: list[Confirmation],
    args: argparse.Namespace,
    *,
    only: str | None = None,
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
    held = (
        frozenset(item.file for item in selection.recordings if item.file != only)
        if only is not None
        else frozenset(row.file for row in confirmations)
    )
    summary = run_session(
        selection,
        recordings,
        confirmations_path,
        candidates.transcripts,
        candidates.source,
        terminal_io(),
        confirmed_files=held,
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
