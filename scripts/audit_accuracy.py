"""Signed labeled-corpus artifact selection and accuracy classification."""

from __future__ import annotations

from collections import Counter, defaultdict
import json
from pathlib import Path
from typing import Any

from audit_common import ACCURACY_BUCKETS, percentage


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


def natural(value: Any) -> int | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, int) and value >= 0:
        return value
    if isinstance(value, float) and value >= 0 and value.is_integer():
        return int(value)
    return None


SCORE_FIELDS = (
    "productionOutputTranscriptScore",
    "outputTranscriptScore",
    "canonicalizedRawTranscriptScore",
    "transcriptScore",
    "score",
)


def score_with_source(row: dict[str, Any]) -> tuple[dict[str, int], str] | None:
    for field in SCORE_FIELDS:
        candidate = row.get(field)
        if not isinstance(candidate, dict):
            continue
        substitutions = natural(candidate.get("substitutions"))
        insertions = natural(candidate.get("insertions"))
        deletions = natural(candidate.get("deletions"))
        if None in (substitutions, insertions, deletions):
            continue
        errors = natural(candidate.get("wordErrors"))
        component_total = substitutions + insertions + deletions
        if errors is None or errors != component_total:
            continue
        return ({"substitutions": substitutions, "insertions": insertions,
                 "deletions": deletions, "wordErrors": errors}, field)
    return None


def score(row: dict[str, Any]) -> dict[str, int] | None:
    result = score_with_source(row)
    return result[0] if result else None


def explicit_empty_or_error(row: dict[str, Any]) -> bool:
    if row.get("error") not in (None, "", False):
        return True
    if str(row.get("status", "")).lower() in {"error", "failed", "empty"}:
        return True
    return "transcript" in row and not str(row.get("transcript") or "").strip()


def classify(row: dict[str, Any]) -> tuple[str, dict[str, int], bool] | None:
    row_score = score(row)
    if explicit_empty_or_error(row):
        return "empty_error", row_score or {
            "substitutions": 0, "insertions": 0, "deletions": 0, "wordErrors": 0}, False
    if row_score is None:
        return None
    if row_score["wordErrors"] == 0:
        return "exact", row_score, False
    contributions = {
        "residual_substitution": row_score["substitutions"],
        "residual_insertion": row_score["insertions"],
        "residual_deletion": row_score["deletions"],
    }
    priority = {"residual_substitution": 2, "residual_insertion": 1, "residual_deletion": 0}
    bucket = max(contributions, key=lambda name: (contributions[name], priority[name]))
    return bucket, row_score, sum(value > 0 for value in contributions.values()) > 1


def accuracy_report(path: Path | None, requested: str | None) -> dict[str, Any]:
    if path is None or not path.is_file():
        return {"available": False, "evalSource": str(path) if path else None,
                "baselineArm": requested, "reason": "no readable signed eval artifact found"}
    rows, file_malformed = read_rows(path)
    arm = baseline_arm(rows, requested)
    selected = [row for row in rows if arm is not None and str(row.get("arm")) == arm]
    if arm is None or not selected:
        reason = "baseline arm is ambiguous; pass --eval-arm" if arm is None else "selected baseline arm has no rows"
        return {"available": False, "evalSource": str(path), "baselineArm": arm,
                "reason": reason, "malformedRows": file_malformed}
    counts, errors, components, score_sources = Counter(), Counter(), defaultdict(Counter), Counter()
    mixed, selected_malformed = 0, 0
    for row in selected:
        classified = classify(row)
        if classified is None:
            selected_malformed += 1
            continue
        bucket, row_score, is_mixed = classified
        selected_score = score_with_source(row)
        if selected_score:
            score_sources[selected_score[1]] += 1
        counts[bucket] += 1
        errors[bucket] += row_score["wordErrors"]
        for name in ("substitutions", "insertions", "deletions"):
            components[bucket][name] += row_score[name]
        mixed += is_mixed
    total = sum(counts.values())
    buckets = {
        name: {
            "count": counts[name], "percent": percentage(counts[name], total),
            "contributedWordErrors": errors[name],
            "errorComponents": {part: components[name][part]
                                for part in ("substitutions", "insertions", "deletions")},
        } for name in ACCURACY_BUCKETS
    }
    return {
        "available": True, "evalSource": str(path), "baselineArm": arm,
        "rows": total, "selectedRows": len(selected),
        "malformedRows": file_malformed + selected_malformed,
        "fileMalformedRows": file_malformed,
        "selectedMalformedRows": selected_malformed,
        "artifactBalanced": artifact_is_balanced(rows), "mixedErrorRows": mixed,
        "scoreSource": (
            next(iter(score_sources)) if len(score_sources) == 1
            else "mixed:" + ",".join(sorted(score_sources))
        ),
        "classificationRule": "largest error contributor; ties resolve substitution, insertion, deletion",
        "buckets": buckets, "totalContributedWordErrors": sum(errors.values()),
    }
