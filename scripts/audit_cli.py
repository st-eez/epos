#!/usr/bin/env python3
"""Report Epos operational reliability and signed-corpus accuracy."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys
import tempfile

from audit_accuracy import discover_best_signed_eval
from audit_report import build_report, format_human
from audit_self_test import run_self_test


def parser() -> argparse.ArgumentParser:
    repo_root = Path(__file__).resolve().parent.parent
    default_logs = Path.home() / "Library" / "Caches" / "Epos" / "logs"
    result = argparse.ArgumentParser(
        description=(
            "Summarize privacy-safe recording outcomes separately from "
            "signed labeled-corpus accuracy."
        )
    )
    result.add_argument(
        "--logs",
        type=Path,
        default=default_logs,
        help=f"diagnostic log file or directory (default: {default_logs})",
    )
    result.add_argument(
        "--eval",
        dest="eval_path",
        type=Path,
        help=(
            "signed JSONL eval artifact "
            f"(default: latest *signed*.jsonl in {repo_root / '.build' / 'evals'})"
        ),
    )
    result.add_argument(
        "--eval-arm",
        help="baseline arm name when it cannot be selected unambiguously",
    )
    result.add_argument(
        "--json",
        action="store_true",
        help="emit machine-readable JSON",
    )
    result.add_argument(
        "--self-test",
        action="store_true",
        help="run deterministic parser and classification checks",
    )
    return result


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    if args.self_test:
        with tempfile.TemporaryDirectory(prefix="epos-audit-") as directory:
            run_self_test(Path(directory))
        print("audit self-test: passed")
        return 0

    repo_root = Path(__file__).resolve().parent.parent
    eval_path = args.eval_path
    if eval_path is None:
        eval_path = discover_best_signed_eval(repo_root / ".build" / "evals")
    report = build_report(args.logs.expanduser(), eval_path, args.eval_arm)
    if args.json:
        json.dump(report, sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
    else:
        print(format_human(report))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
