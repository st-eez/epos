"""Select and read signed labeled-corpus eval artifacts."""

from __future__ import annotations

from collections import defaultdict
import json
from pathlib import Path
from typing import Any


def read_rows(path: Path) -> tuple[list[dict[str, Any]], int]:
    rows, malformed = [], 0
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return [], 0
    for line in lines:
        if not line.strip():
            continue
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            malformed += 1
            continue
        if isinstance(value, dict):
            rows.append(value)
        else:
            malformed += 1
    return rows, malformed


def baseline_arm(rows: list[dict[str, Any]], requested: str | None) -> str | None:
    arms = sorted({str(row["arm"]) for row in rows if row.get("arm") is not None})
    if requested:
        return requested
    for preferred in ("baseline", "speech-progressive-fast", "production"):
        if preferred in arms:
            return preferred
    current = sorted({str(row["arm"]) for row in rows
                      if row.get("arm") is not None
                      and "current production" in str(row.get("configuration", "")).lower()})
    if len(current) == 1:
        return current[0]
    return arms[0] if len(arms) == 1 else None


def discover_best_signed_eval(directory: Path) -> Path | None:
    candidates = [path for path in directory.glob("*signed*.jsonl") if path.is_file()]
    scored = []
    for path in candidates:
        rows, _ = read_rows(path)
        arm = baseline_arm(rows, None)
        count = sum(arm is not None and str(row.get("arm")) == arm for row in rows)
        scored.append((
            count,
            artifact_is_balanced(rows),
            path.stat().st_mtime_ns,
            path.name,
            path,
        ))
    return max(scored)[-1] if scored else None


def artifact_is_balanced(rows: list[dict[str, Any]]) -> bool:
    by_arm: dict[str, list[str]] = defaultdict(list)
    for row in rows:
        arm, file = row.get("arm"), row.get("file")
        if arm is None or not isinstance(file, str) or not file:
            return False
        by_arm[str(arm)].append(file)
    file_sets = [set(files) for files in by_arm.values()]
    return len(file_sets) > 1 and all(
        len(files) == len(file_set)
        for files, file_set in zip(by_arm.values(), file_sets, strict=True)
    ) and all(file_set == file_sets[0] for file_set in file_sets[1:])
