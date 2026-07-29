"""Score and select a deterministic human-labeling queue."""

from __future__ import annotations

from dataclasses import dataclass
from difflib import SequenceMatcher
import re
from typing import Literal


QUEUE_SIZE = 30
PRIORITY_COUNT = 24
CORRECTION_AUDIT_COUNT = 3
CONTROL_COUNT = 3
IGNORED_PUNCTUATION = frozenset(".,!?;:")
TOKEN_PATTERN = re.compile(r"[^\W_]+(?:['’][^\W_]+)*|[^\w\s]", re.UNICODE)
SelectionBucket = Literal["priority", "correction-audit", "control"]


class LabelQueueError(ValueError):
    """The replay artifact cannot safely produce a review queue."""


@dataclass(frozen=True)
class DisagreementSpan:
    recognized_span: str
    alternative_span: str
    distinct_file_count: int


@dataclass(frozen=True)
class Candidate:
    file: str
    audio_sha256: str
    production_transcript: str
    canonicalized_transcript: str
    baseline_text: str
    baseline_canonicalized: str
    audio_duration_seconds: float
    alternatives: tuple[str, ...]
    confidence_mean: float | None
    confidence_minimum: float | None
    max_alternative_word_edits: int
    canonicalizer_changed: bool
    production_mode_disagreement: bool
    repeated_disagreement_spans: tuple[DisagreementSpan, ...]
    repeated_span_max_files: int
    applied_correction_record_ids: tuple[str, ...]
    correction_attribution_available: bool
    correction_dictionary_fingerprint: str
    score: int
    reason_codes: tuple[str, ...]


@dataclass(frozen=True)
class QueueEntry:
    candidate: Candidate
    rank: int
    selection_bucket: SelectionBucket


def normalized_tokens(text: str) -> list[str]:
    return [
        token.casefold()
        for token in TOKEN_PATTERN.findall(text)
        if token not in IGNORED_PUNCTUATION
    ]


def word_edit_distance(left: str, right: str) -> int:
    source = normalized_tokens(left)
    target = normalized_tokens(right)
    previous = list(range(len(target) + 1))
    for source_index, source_token in enumerate(source, start=1):
        current = [source_index]
        for target_index, target_token in enumerate(target, start=1):
            current.append(min(
                current[-1] + 1,
                previous[target_index] + 1,
                previous[target_index - 1] + (source_token != target_token),
            ))
        previous = current
    return previous[-1]


def disagreement_spans(top: str, alternative: str) -> set[tuple[str, str]]:
    top_tokens = normalized_tokens(top)
    alternative_tokens = normalized_tokens(alternative)
    spans: set[tuple[str, str]] = set()
    for operation, i1, i2, j1, j2 in SequenceMatcher(
        None, top_tokens, alternative_tokens, autojunk=False
    ).get_opcodes():
        if operation != "equal":
            source = " ".join(top_tokens[i1:i2]) or "∅"
            target = " ".join(alternative_tokens[j1:j2]) or "∅"
            spans.add((source, target))
    return spans


def score_candidate(
    max_edits: int,
    mean: float | None,
    minimum: float | None,
    canonicalizer_changed: bool,
    repeated_span_max_files: int,
    production_mode_disagreement: bool,
) -> tuple[int, tuple[str, ...]]:
    score = 0
    reasons: list[str] = []
    if max_edits >= 2:
        score += 4
        reasons.append("alternative-edits-2-plus")
    elif max_edits == 1:
        score += 2
        reasons.append("alternative-edits-1")
    if mean is not None and mean <= 0.65:
        score += 3
        reasons.append("mean-confidence-065-or-lower")
    elif mean is not None and mean <= 0.75:
        score += 1
        reasons.append("mean-confidence-075-or-lower")
    if minimum is not None and minimum <= 0.20:
        score += 3
        reasons.append("minimum-confidence-020-or-lower")
    elif minimum is not None and minimum <= 0.35:
        score += 1
        reasons.append("minimum-confidence-035-or-lower")
    if canonicalizer_changed:
        score += 2
        reasons.append("canonicalizer-changed")
    if repeated_span_max_files >= 3:
        score += 3
        reasons.append("repeated-disagreement-3-plus")
    elif repeated_span_max_files == 2:
        score += 1
        reasons.append("repeated-disagreement-2")
    if production_mode_disagreement:
        score += 3
        reasons.append("production-mode-disagreement")
    return score, tuple(reasons)


def select_queue(candidates: list[Candidate]) -> list[QueueEntry]:
    if len(candidates) < QUEUE_SIZE:
        raise LabelQueueError(
            f"need at least {QUEUE_SIZE} recordings, found {len(candidates)}"
        )
    ranked = sorted(candidates, key=priority_sort_key)
    selected: list[tuple[Candidate, SelectionBucket]] = [
        (candidate, "priority") for candidate in ranked[:PRIORITY_COUNT]
    ]
    selected_files = {candidate.file for candidate, _ in selected}

    correction_audits = sorted(
        (
            candidate for candidate in candidates
            if candidate.canonicalizer_changed and candidate.file not in selected_files
        ),
        key=priority_sort_key,
    )
    for candidate in correction_audits[:CORRECTION_AUDIT_COUNT]:
        selected.append((candidate, "correction-audit"))
        selected_files.add(candidate.file)

    controls = sorted(
        (
            candidate for candidate in candidates
            if candidate.file not in selected_files and candidate.score <= 2
        ),
        key=control_sort_key,
    )
    for candidate in controls[:CONTROL_COUNT]:
        selected.append((candidate, "control"))
        selected_files.add(candidate.file)

    bucket_counts = {
        bucket: sum(1 for _, selected_bucket in selected if selected_bucket == bucket)
        for bucket in ("priority", "correction-audit", "control")
    }
    expected = {
        "priority": PRIORITY_COUNT,
        "correction-audit": CORRECTION_AUDIT_COUNT,
        "control": CONTROL_COUNT,
    }
    if bucket_counts != expected:
        raise LabelQueueError(
            "corpus cannot supply 24 priority, 3 correction-audit, "
            f"and 3 control rows; found {bucket_counts}"
        )
    return [
        QueueEntry(candidate, rank, bucket)
        for rank, (candidate, bucket) in enumerate(selected, start=1)
    ]


def priority_sort_key(candidate: Candidate) -> tuple[int | float | str, ...]:
    return (
        -candidate.score,
        -candidate.max_alternative_word_edits,
        float("inf") if candidate.confidence_mean is None else candidate.confidence_mean,
        float("inf") if candidate.confidence_minimum is None else candidate.confidence_minimum,
        candidate.file,
    )


def control_sort_key(candidate: Candidate) -> tuple[int | float | str, ...]:
    return (
        candidate.score,
        candidate.max_alternative_word_edits,
        -(candidate.confidence_mean if candidate.confidence_mean is not None else -1),
        -(candidate.confidence_minimum if candidate.confidence_minimum is not None else -1),
        candidate.file,
    )
