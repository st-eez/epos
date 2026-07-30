#!/usr/bin/env python3
"""Operator command for provenance-aware Epos audio labeling queues."""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import os
from pathlib import Path
import shutil
import sys
import tempfile

from corpus_reader import CorpusReadError
from label_artifact import (
    build_candidates,
    load_rows,
)
from label_corpus import validate_recording_coverage
from label_queue import LabelQueueError, select_queue
from label_render import render_jsonl, render_markdown


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(
        description="Build a human review queue from a SpeechContext JSONL artifact."
    )
    parser.add_argument("input", nargs="?", type=Path)
    parser.add_argument(
        "--output",
        type=Path,
        default=repo_root / ".build" / "evals" / "label-queue.jsonl",
    )
    parser.add_argument(
        "--markdown",
        type=Path,
        default=repo_root / ".build" / "evals" / "label-queue.md",
    )
    parser.add_argument(
        "--recordings",
        type=Path,
        default=Path.home() / "Library" / "Application Support" / "Epos" / "recordings",
    )
    parser.add_argument(
        "--corpus",
        type=Path,
        default=repo_root / ".build" / "evals" / "evaluation-corpus-v2.jsonl",
    )
    parser.add_argument("--replace", action="store_true")
    parser.add_argument("--test", action="store_true")
    args = parser.parse_args()

    if args.test:
        from label_self_test import run_self_test

        with tempfile.TemporaryDirectory() as directory:
            run_self_test(Path(directory))
        print("label self-test passed")
        return 0

    try:
        input_path = args.input or discover_input(repo_root)
        source_rows, source_sha256 = load_rows(input_path)
        candidates = build_candidates(source_rows)
        corpus = validate_recording_coverage(
            candidates,
            args.recordings,
            args.corpus,
        )
        entries = select_queue(candidates)
        validate_output_paths(
            input_path,
            args.corpus,
            args.output,
            args.markdown,
            args.recordings,
        )
        with output_locks((args.output, args.markdown)):
            collisions = [
                path for path in (args.output, args.markdown)
                if path.exists()
            ]
            if collisions and not args.replace:
                raise LabelQueueError(
                    "output exists; pass --replace to overwrite: "
                    + ", ".join(str(path) for path in collisions)
                )
            write_outputs(
                {
                    args.output: render_jsonl(
                        entries,
                        input_path.name,
                        source_sha256,
                        corpus,
                        args.corpus.name,
                    ),
                    args.markdown: render_markdown(
                        entries,
                        args.recordings,
                        corpus,
                    ),
                },
                replace=args.replace,
            )
    except (OSError, CorpusReadError, LabelQueueError) as error:
        print(f"label: {error}", file=sys.stderr)
        return 1

    print(f"queued {len(entries)} of {len(candidates)} recordings")
    print(f"jsonl: {args.output}")
    print(f"review: {args.markdown}")
    return 0


def discover_input(repo_root: Path) -> Path:
    evals = repo_root / ".build" / "evals"
    for pattern in (
        "reviewable*-context-*.jsonl",
        "unlabeled*-context-*.jsonl",
    ):
        candidates = sorted(
            evals.glob(pattern),
            key=lambda path: (path.stat().st_mtime_ns, path.name),
            reverse=True,
        )
        if candidates:
            return candidates[0]
    raise LabelQueueError("no reviewable context replay artifact found")


def validate_output_paths(
    input_path: Path,
    corpus_path: Path,
    output_path: Path,
    markdown_path: Path,
    recordings_directory: Path,
) -> None:
    resolved_inputs = {input_path.resolve(), corpus_path.resolve()}
    resolved_outputs = {output_path.resolve(), markdown_path.resolve()}
    resolved_recordings = recordings_directory.resolve()
    if len(resolved_outputs) != 2:
        raise LabelQueueError("JSONL and Markdown outputs must be different paths")
    source_collisions = resolved_inputs & resolved_outputs
    if source_collisions:
        raise LabelQueueError(
            "outputs must not replace replay or corpus inputs: "
            + ", ".join(str(path) for path in sorted(source_collisions))
        )
    protected_outputs = sorted(
        str(path) for path in resolved_outputs
        if path.is_relative_to(resolved_recordings)
    )
    if protected_outputs:
        raise LabelQueueError(
            "outputs must not be inside the recordings directory: "
            + ", ".join(protected_outputs)
        )


@contextmanager
def output_locks(paths: tuple[Path, Path]):
    lock_root = Path(tempfile.gettempdir()) / "epos-label-locks"
    lock_root.mkdir(parents=True, exist_ok=True)
    handles = []
    try:
        for target in sorted({path.resolve() for path in paths}, key=str):
            digest = hashlib.sha256(str(target).encode()).hexdigest()
            handle = (lock_root / digest).open("a+", encoding="utf-8")
            fcntl.flock(handle, fcntl.LOCK_EX)
            handles.append(handle)
        yield
    finally:
        for handle in reversed(handles):
            fcntl.flock(handle, fcntl.LOCK_UN)
            handle.close()


def write_outputs(outputs: dict[Path, str], *, replace: bool) -> None:
    staged: dict[Path, Path] = {}
    backups: dict[Path, Path] = {}
    replaced: list[Path] = []
    try:
        for target, content in outputs.items():
            target.parent.mkdir(parents=True, exist_ok=True)
            with tempfile.NamedTemporaryFile(
                mode="w",
                encoding="utf-8",
                dir=target.parent,
                prefix=f".{target.name}.",
                delete=False,
            ) as stream:
                stream.write(content)
                staged[target] = Path(stream.name)
            if replace and target.is_file():
                with tempfile.NamedTemporaryFile(
                    dir=target.parent,
                    prefix=f".{target.name}.backup.",
                    delete=False,
                ) as backup:
                    backups[target] = Path(backup.name)
                shutil.copyfile(target, backups[target])

        for target, staged_path in staged.items():
            if replace:
                os.replace(staged_path, target)
            else:
                os.link(staged_path, target)
            replaced.append(target)
    except OSError:
        for target in reversed(replaced):
            backup = backups.get(target)
            if backup is not None and backup.exists():
                os.replace(backup, target)
            else:
                target.unlink(missing_ok=True)
        raise
    finally:
        for path in (*staged.values(), *backups.values()):
            path.unlink(missing_ok=True)


if __name__ == "__main__":
    raise SystemExit(main())
