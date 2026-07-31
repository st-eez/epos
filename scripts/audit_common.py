"""Shared constants and numeric helpers for the local audit."""

from __future__ import annotations

import math
from typing import Any, Iterable

OPERATIONAL_BUCKETS = (
    "setup_failure", "permission_failure", "cancelled_before_audio",
    "no_audio_input", "recognizer_failure", "empty_transcript",
    "target_refusal", "backend_refusal", "delivery_mismatch",
    "verified_delivery", "accepted_unverified", "incomplete_ambiguous",
)
ACCURACY_BUCKETS = (
    "exact", "residual_substitution", "residual_insertion",
    "residual_deletion", "empty_error",
)
OUTCOME_ALIASES = {
    "setup-failed": "setup_failure", "setup-failure": "setup_failure",
    "cancelled-before-audio": "cancelled_before_audio",
    "no-input": "no_audio_input", "no-audio-input": "no_audio_input",
    "recognizer-failed": "recognizer_failure",
    "recognizer-failure": "recognizer_failure",
    "empty-transcript": "empty_transcript",
    "target-refused": "target_refusal", "target-refusal": "target_refusal",
    "backend-refused": "backend_refusal", "backend-refusal": "backend_refusal",
    "delivery-mismatch": "delivery_mismatch",
    "delivery-verified": "verified_delivery",
    "verified-delivery": "verified_delivery",
    "ax-verified-delivery": "verified_delivery",
    "write-accepted-unverified": "accepted_unverified",
    "accepted-unverified": "accepted_unverified",
    "accepted-but-unverified-delivery": "accepted_unverified",
    "incomplete-ambiguous": "incomplete_ambiguous",
    # A fully sent IME commit that was never acknowledged: the transcript may
    # have landed or been lost, so it is ambiguous, never an accepted write.
    "ime-commit-unacknowledged": "incomplete_ambiguous",
    # The mic died mid-hold and the recording was cut short: a truncated
    # transcript may still have been written, so the recording is ambiguous.
    "capture-interrupted": "incomplete_ambiguous",
    # A revoked grant, not a pipeline that failed to set up and not a user who
    # said nothing: macOS feeds a denied process silent buffers, and an
    # untrusted process cannot read the insertion target at all.
    "microphone-denied": "permission_failure",
    "accessibility-untrusted": "permission_failure",
}


def percentage(count: int, total: int) -> float:
    return round(100.0 * count / total, 2) if total else 0.0


def numeric(value: Any) -> float | None:
    if isinstance(value, bool):
        return None
    try:
        parsed = float(value)
    except (TypeError, ValueError):
        return None
    return parsed if math.isfinite(parsed) else None


def percentile(values: Iterable[float], fraction: float) -> float | None:
    ordered = sorted(float(value) for value in values)
    if not ordered:
        return None
    rank = (len(ordered) - 1) * fraction
    low, high = math.floor(rank), math.ceil(rank)
    value = ordered[low]
    if low != high:
        value += (ordered[high] - value) * (rank - low)
    return round(value, 2)


def timing(values: Iterable[float]) -> dict[str, Any] | None:
    collected = list(values)
    if not collected:
        return None
    return {
        "count": len(collected),
        "p50Ms": percentile(collected, 0.50),
        "p95Ms": percentile(collected, 0.95),
    }
