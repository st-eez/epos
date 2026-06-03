#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from collections import Counter
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT = REPO_ROOT / ".build" / "evals" / "dogfood-residual-report.md"


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Generate a Markdown residual-error report from dogfood pipeline JSONL."
    )
    parser.add_argument("input_jsonl", type=Path, help="DogfoodPipelineEvalTests JSONL output")
    parser.add_argument(
        "--output",
        type=Path,
        default=DEFAULT_OUTPUT,
        help=f"Markdown output path (default: {DEFAULT_OUTPUT.relative_to(REPO_ROOT)})",
    )
    parser.add_argument(
        "--min-output-wer",
        type=float,
        default=0.0,
        help="Only include rows with output WER greater than this value.",
    )
    args = parser.parse_args()

    input_path = args.input_jsonl.expanduser()
    if not input_path.is_absolute():
        input_path = Path.cwd() / input_path
    output_path = args.output.expanduser()
    if not output_path.is_absolute():
        output_path = Path.cwd() / output_path

    rows = read_jsonl(input_path)
    report = render_report(
        rows=rows,
        input_path=input_path,
        min_output_wer=args.min_output_wer,
    )
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(report, encoding="utf-8")
    print(output_path)


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    with path.open(encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, start=1):
            stripped = line.strip()
            if not stripped:
                continue
            try:
                rows.append(json.loads(stripped))
            except json.JSONDecodeError as error:
                raise SystemExit(f"{path}:{line_number}: invalid JSONL: {error}") from error
    return rows


def render_report(
    rows: list[dict[str, Any]],
    input_path: Path,
    min_output_wer: float,
) -> str:
    scored_rows = [row for row in rows if score(row, "outputTranscriptScore") is not None]
    residual_rows = [
        row
        for row in scored_rows
        if wer(row, "outputTranscriptScore") > min_output_wer
    ]
    residual_rows.sort(
        key=lambda row: (
            wer(row, "outputTranscriptScore"),
            wer(row, "rawTranscriptScore"),
            row.get("file", ""),
        ),
        reverse=True,
    )

    lines = [
        "# Dogfood Residual Error Report",
        "",
        f"- input: `{display_path(input_path)}`",
        f"- rows: {len(rows)}",
        f"- scored rows: {len(scored_rows)}",
        f"- residual rows: {len(residual_rows)}",
        f"- output WER threshold: > {format_score(min_output_wer)}",
    ]

    if scored_rows:
        lines.extend(
            [
                f"- mean WER raw/can/out: {mean_wer(scored_rows, 'rawTranscriptScore')}/"
                f"{mean_wer(scored_rows, 'canonicalizedRawTranscriptScore')}/"
                f"{mean_wer(scored_rows, 'outputTranscriptScore')}",
                f"- output vs canonicalized raw: {output_vs_canonicalized_summary(scored_rows)}",
            ]
        )
    if residual_rows:
        residual_outcomes = Counter(str(row.get("outcome", "unknown")) for row in residual_rows)
        lines.append(f"- residual outcomes: {counter_summary(residual_outcomes)}")

    lines.extend(["", "## Residual Rows", ""])
    if not residual_rows:
        lines.append("No residual rows matched the threshold.")
        return "\n".join(lines) + "\n"

    lines.extend(summary_table(residual_rows))
    for row in residual_rows:
        lines.extend(["", *row_detail(row)])
    return "\n".join(lines) + "\n"


def summary_table(rows: list[dict[str, Any]]) -> list[str]:
    lines = [
        "| File | WER raw/can/out | Outcome | Canon helped | Polish changed | Guard |",
        "| --- | --- | --- | --- | --- | --- |",
    ]
    for row in rows:
        guard = row.get("guardRejectionReason") or ""
        lines.append(
            "| "
            + " | ".join(
                [
                    table_cell(str(row.get("file", ""))),
                    table_cell(score_triplet(row)),
                    table_cell(str(row.get("outcome", ""))),
                    table_cell(yes_no(canonicalizer_helped(row))),
                    table_cell(yes_no(bool(row.get("outputChangedFromCanonicalizedRaw")))),
                    table_cell(str(guard)),
                ]
            )
            + " |"
        )
    return lines


def row_detail(row: dict[str, Any]) -> list[str]:
    lines = [
        f"### {row.get('file', 'unknown')}",
        "",
        f"- WER raw/can/out: {score_triplet(row)}",
        f"- outcome: {row.get('outcome', 'unknown')}",
        f"- canonicalizer helped: {yes_no(canonicalizer_helped(row))}",
        f"- polish changed canonicalized raw: {yes_no(bool(row.get('outputChangedFromCanonicalizedRaw')))}",
    ]
    if row.get("guardRejectionReason"):
        lines.append(f"- guard rejection: {row['guardRejectionReason']}")
        if row.get("guardRejectionDiff"):
            lines.append(f"- guard diff: `{row['guardRejectionDiff']}`")

    lines.extend(
        [
            "",
            fenced("intended", row.get("humanIntendedTranscript")),
            fenced("raw", row.get("rawTranscript")),
        ]
    )
    if row.get("canonicalizedRaw") != row.get("rawTranscript"):
        lines.append(fenced("canonicalized raw", row.get("canonicalizedRaw")))
    lines.append(fenced("output", row.get("output")))
    if row.get("guardRejectionCandidate"):
        lines.append(fenced("guard candidate", row.get("guardRejectionCandidate")))
    if row.get("shadowRelaxedOutput"):
        lines.append(fenced("relaxed strict-gate output", row.get("shadowRelaxedOutput")))
    if row.get("shadowRelaxedGuardRejectionCandidate"):
        lines.append(fenced("relaxed rejected candidate", row.get("shadowRelaxedGuardRejectionCandidate")))
    return lines


def score(row: dict[str, Any], key: str) -> dict[str, Any] | None:
    value = row.get(key)
    return value if isinstance(value, dict) else None


def wer(row: dict[str, Any], key: str) -> float:
    value = score(row, key)
    if value is None:
        return 0.0
    return float(value.get("wordErrorRate", 0.0))


def mean_wer(rows: list[dict[str, Any]], key: str) -> str:
    scored = [row for row in rows if score(row, key) is not None]
    if not scored:
        return "n/a"
    return format_score(sum(wer(row, key) for row in scored) / len(scored))


def output_vs_canonicalized_summary(rows: list[dict[str, Any]]) -> str:
    counts = Counter()
    for row in rows:
        output = wer(row, "outputTranscriptScore")
        canonicalized = wer(row, "canonicalizedRawTranscriptScore")
        if output < canonicalized:
            counts["better"] += 1
        elif output > canonicalized:
            counts["worse"] += 1
        else:
            counts["same"] += 1
    return counter_summary(counts)


def canonicalizer_helped(row: dict[str, Any]) -> bool:
    return wer(row, "canonicalizedRawTranscriptScore") < wer(row, "rawTranscriptScore")


def score_triplet(row: dict[str, Any]) -> str:
    return (
        f"{format_score(wer(row, 'rawTranscriptScore'))}/"
        f"{format_score(wer(row, 'canonicalizedRawTranscriptScore'))}/"
        f"{format_score(wer(row, 'outputTranscriptScore'))}"
    )


def counter_summary(counter: Counter[str]) -> str:
    if not counter:
        return "none"
    return ", ".join(f"{key}={counter[key]}" for key in sorted(counter))


def table_cell(value: str) -> str:
    return value.replace("|", "\\|").replace("\n", " ")


def fenced(label: str, value: Any) -> str:
    text = "" if value is None else str(value)
    return f"{label}:\n````text\n{text}\n````"


def display_path(path: Path) -> str:
    try:
        return str(path.relative_to(REPO_ROOT))
    except ValueError:
        return str(path)


def format_score(value: float) -> str:
    return f"{value:.3f}"


def yes_no(value: bool) -> str:
    return "yes" if value else "no"


if __name__ == "__main__":
    main()
