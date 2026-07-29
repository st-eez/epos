"""Classify signed labeled-corpus accuracy against the authoritative corpus."""

from __future__ import annotations

from collections import Counter, defaultdict
from pathlib import Path
from typing import Any

from audit_artifact import artifact_is_balanced, baseline_arm, read_rows
from audit_common import ACCURACY_BUCKETS, percentage
from corpus_reader import CorpusEntry, CorpusReadError, load_corpus


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


def authoritative_corpus(path: Path) -> tuple[dict[str, CorpusEntry], str | None]:
    """Load the corpus with the same strictness the label queue requires.

    The audit reports rather than raises: an unreadable or hand-edited corpus
    must degrade to historical evidence, never crash and never verify.
    """
    if not path.is_file():
        return {}, f"authoritative corpus is unavailable: {path}"
    try:
        return load_corpus(path).entries_by_file, None
    except (OSError, CorpusReadError) as error:
        return {}, f"authoritative corpus is unavailable: rejected by strict validation: {error}"


def matches_confirmed_reference(
    row: dict[str, Any], corpus: dict[str, CorpusEntry]
) -> bool:
    file = row.get("file")
    reference = row.get("humanIntendedTranscript")
    digest = row.get("audioSHA256")
    authoritative = corpus.get(file) if isinstance(file, str) else None
    return bool(
        authoritative
        and isinstance(reference, str)
        and isinstance(digest, str)
        and authoritative.verification_status == "human_confirmed"
        and authoritative.audio_sha256 == digest
        and authoritative.transcript_candidate == reference
    )


def accuracy_report(
    path: Path | None, requested: str | None, corpus_path: Path
) -> dict[str, Any]:
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
    corpus, corpus_error = authoritative_corpus(corpus_path)
    counts, errors = Counter(), Counter()
    components, score_sources = defaultdict(Counter), Counter()
    mixed, selected_malformed, scored, joined = 0, 0, 0, 0
    for row in selected:
        classified = classify(row)
        if classified is None:
            selected_malformed += 1
            continue
        bucket, row_score, is_mixed = classified
        selected_score = score_with_source(row)
        if selected_score:
            score_sources[selected_score[1]] += 1
            scored += 1
        joined += matches_confirmed_reference(row, corpus)
        counts[bucket] += 1
        errors[bucket] += row_score["wordErrors"]
        for name in ("substitutions", "insertions", "deletions"):
            components[bucket][name] += row_score[name]
        mixed += is_mixed
    total = sum(counts.values())
    verified_accuracy = bool(
        not corpus_error
        and scored > 0
        and scored == len(selected)
        and joined == len(selected)
        and selected_malformed == 0
    )
    if corpus_error:
        reference_provenance = "authoritative_corpus_unavailable"
    elif verified_accuracy:
        reference_provenance = "authoritative_human_confirmed"
    else:
        reference_provenance = "authoritative_join_mismatch"
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
        "referenceProvenance": reference_provenance,
        "verifiedAccuracy": verified_accuracy,
        "corpusSource": str(corpus_path),
        "corpusReason": corpus_error,
        "referenceJoinedRows": joined,
        "scoredRows": scored,
        "scoreSource": (
            next(iter(score_sources)) if len(score_sources) == 1
            else "mixed:" + ",".join(sorted(score_sources))
        ),
        "classificationRule": "largest error contributor; ties resolve substitution, insertion, deletion",
        "buckets": buckets, "totalContributedWordErrors": sum(errors.values()),
    }
