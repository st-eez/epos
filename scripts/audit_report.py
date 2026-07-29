"""Audit report assembly and human rendering."""

from __future__ import annotations

from pathlib import Path
from typing import Any

from audit_accuracy import accuracy_report
from audit_common import ACCURACY_BUCKETS, OPERATIONAL_BUCKETS
from audit_operational import operational_report


def build_report(
    log_path: Path, eval_path: Path | None, arm: str | None, corpus_path: Path
) -> dict[str, Any]:
    return {
        "schemaVersion": 1,
        "privacy": "transcript text excluded",
        "operational": operational_report(log_path),
        "labeledCorpusAccuracy": accuracy_report(eval_path, arm, corpus_path),
    }


def count(value: dict[str, Any]) -> str:
    return f"{value['count']} ({value['percent']:.2f}%)"


def timing_line(label: str, value: dict[str, Any] | None) -> str | None:
    if value is None:
        return None
    return (f"    {label}: p50 {value['p50Ms']:.2f} ms, "
            f"p95 {value['p95Ms']:.2f} ms (n={value['count']})")


def append_partition(lines: list[str], title: str, part: dict[str, Any],
                     terminal_key: str, terminal_label: str) -> None:
    lines.extend(["", f"  {title}"])
    if not part["recordingStarts"]:
        lines.append(f"    no {title.lower()} sessions found")
        return
    lines.append(f"    recordings: {part['recordingStarts']} ({part['incompleteCount']} incomplete)")
    for bucket in OPERATIONAL_BUCKETS:
        lines.append(f"    {bucket}: {count(part['buckets'][bucket])}")
    for label, value in (
        (terminal_label, part["timing"][terminal_key]),
        ("first-result latency", part["timing"]["firstResult"]),
    ):
        rendered = timing_line(label, value)
        if rendered:
            lines.append(rendered)


def format_human(report: dict[str, Any]) -> str:
    operational = report["operational"]
    lines = [
        "Epos local reliability audit", "", "Operational outcomes",
        f"  recordings: {operational['recordingStarts']}",
        f"  incomplete across partitions: {operational['incompleteCount']}",
    ]
    append_partition(lines, "Current structured (schema=1)",
                     operational["currentStructured"], "releaseToOutcome",
                     "release-to-outcome latency")
    append_partition(lines, "Unsupported structured schema",
                     operational["unsupportedStructured"], "releaseToOutcome",
                     "reported outcome latency")
    append_partition(lines, "Legacy inferred", operational["legacyInferred"],
                     "finalizeToDone", "inferred finalize-to-done timing")
    accuracy = report["labeledCorpusAccuracy"]
    lines.extend(["", "Corpus accuracy evidence"])
    if not accuracy["available"]:
        lines.append(f"  unavailable: {accuracy['reason']}")
    else:
        lines.extend([
            f"  selected artifact: {Path(accuracy['evalSource']).name}",
            f"  balanced arm coverage: {str(accuracy['artifactBalanced']).lower()}",
            f"  baseline arm: {accuracy['baselineArm']}",
            f"  score source: {accuracy['scoreSource']}",
            f"  reference provenance: {accuracy['referenceProvenance']}",
            f"  verified accuracy: {str(accuracy['verifiedAccuracy']).lower()}",
            f"  authoritative corpus: {accuracy['corpusSource']}",
            f"  reference joins: {accuracy['referenceJoinedRows']}/{accuracy['selectedRows']}",
            f"  scored rows: {accuracy['scoredRows']}/{accuracy['selectedRows']}",
            f"  rows: {accuracy['rows']}/{accuracy['selectedRows']} selected "
            f"({accuracy['selectedMalformedRows']} selected malformed; "
            f"{accuracy['fileMalformedRows']} file malformed)",
            f"  mixed-error rows: {accuracy['mixedErrorRows']}",
        ])
        if not accuracy["verifiedAccuracy"]:
            reason = accuracy["corpusReason"] or (
                "artifact rows did not all match file, audio SHA256, exact reference "
                "text, human-confirmed status, and valid scores"
            )
            lines.append(f"  warning: historical evidence only; {reason}")
        for bucket in ACCURACY_BUCKETS:
            value, parts = accuracy["buckets"][bucket], accuracy["buckets"][bucket]["errorComponents"]
            lines.append(
                f"  {bucket}: {count(value)}; word errors {value['contributedWordErrors']} "
                f"(S={parts['substitutions']}, I={parts['insertions']}, D={parts['deletions']})"
            )
        lines.append(f"  total contributed word errors: {accuracy['totalContributedWordErrors']}")
    lines.extend(["", "Privacy: transcript text was not read into report output."])
    return "\n".join(lines)
