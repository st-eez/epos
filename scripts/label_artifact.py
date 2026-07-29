"""Load and strictly validate SpeechContext labeling artifacts."""

from __future__ import annotations

from collections import defaultdict
import hashlib
import json
import math
from pathlib import Path
import re
from typing import Iterable, TypeAlias, cast

from label_queue import (
    Candidate,
    DisagreementSpan,
    LabelQueueError,
    disagreement_spans,
    normalized_tokens,
    score_candidate,
    word_edit_distance,
)


JsonObject: TypeAlias = dict[str, object]
PRODUCTION_ALTERNATIVES = "production-alternatives"
REQUIRED_PRODUCTION_VARIANTS = frozenset({
    "production-setContext",
    "production-initializer",
    PRODUCTION_ALTERNATIVES,
})
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}")


def load_rows(path: Path) -> tuple[list[JsonObject], str]:
    digest = hashlib.sha256()
    rows: list[JsonObject] = []
    with path.open("rb") as stream:
        for line_number, raw_line in enumerate(stream, start=1):
            digest.update(raw_line)
            stripped = raw_line.strip()
            if not stripped:
                continue
            try:
                decoded: object = json.loads(stripped)
            except json.JSONDecodeError as error:
                raise LabelQueueError(
                    f"{path}: line {line_number} is not valid JSON: {error.msg}"
                ) from error
            if not isinstance(decoded, dict):
                raise LabelQueueError(f"{path}: line {line_number} must be a JSON object")
            rows.append(cast(JsonObject, decoded))
    if not rows:
        raise LabelQueueError(f"{path}: no JSONL rows found")
    return rows, digest.hexdigest()


def build_candidates(rows: Iterable[JsonObject]) -> list[Candidate]:
    rows_by_file: dict[str, dict[str, JsonObject]] = defaultdict(dict)
    canonical_filenames: dict[str, str] = {}
    for row in rows:
        file = required_string(row, "file")
        validate_recording_filename(file)
        prior_file = canonical_filenames.setdefault(file.casefold(), file)
        if prior_file != file:
            raise LabelQueueError(
                f"recording filenames differ only by case: {prior_file}, {file}"
            )
        variant = required_string(row, "variant")
        if variant in rows_by_file[file]:
            raise LabelQueueError(f"duplicate row for {file} variant {variant}")
        rows_by_file[file][variant] = row

    production_rows: dict[str, JsonObject] = {}
    span_files: dict[tuple[str, str], set[str]] = defaultdict(set)
    spans_by_file: dict[str, set[tuple[str, str]]] = defaultdict(set)
    for file, variants in rows_by_file.items():
        if any(row.get("humanIntendedTranscript") is not None for row in variants.values()):
            raise LabelQueueError(f"{file} already contains a human intended transcript")
        missing_variants = REQUIRED_PRODUCTION_VARIANTS - variants.keys()
        if missing_variants:
            raise LabelQueueError(
                f"{file} is missing variants: {', '.join(sorted(missing_variants))}"
            )
        validate_production_group(file, variants)
        production = variants[PRODUCTION_ALTERNATIVES]
        alternatives = string_list(production, "variantAlternativeTranscriptCandidates")
        top = required_string(production, "variantText")
        production_rows[file] = production
        for alternative in unique_normalized_strings(alternatives, excluding=top):
            for span in disagreement_spans(top, alternative):
                spans_by_file[file].add(span)
                span_files[span].add(file)

    candidates: list[Candidate] = []
    for file in sorted(rows_by_file):
        variants = rows_by_file[file]
        row = production_rows[file]
        top = required_string(row, "variantText")
        canonicalized = required_string(row, "variantCanonicalized")
        alternatives = tuple(unique_normalized_strings(
            string_list(row, "variantAlternativeTranscriptCandidates"),
            excluding=top,
        ))
        max_edits = max((word_edit_distance(top, item) for item in alternatives), default=0)
        normalized_top_texts = {
            tuple(normalized_tokens(required_string(variants[name], "variantText")))
            for name in REQUIRED_PRODUCTION_VARIANTS
        }
        repeated = tuple(
            DisagreementSpan(source, target, len(span_files[(source, target)]))
            for source, target in sorted(spans_by_file[file])
            if len(span_files[(source, target)]) >= 2
        )
        repeated_max = max(
            (entry.distinct_file_count for entry in repeated),
            default=0,
        )
        mean = optional_number(row, "variantConfidenceMean")
        minimum = optional_number(row, "variantConfidenceMinimum")
        canonicalizer_changed = top != canonicalized
        mode_disagreement = len(normalized_top_texts) > 1
        score, reason_codes = score_candidate(
            max_edits,
            mean,
            minimum,
            canonicalizer_changed,
            repeated_max,
            mode_disagreement,
        )
        candidates.append(Candidate(
            file=file,
            audio_sha256=required_sha256(row, "audioSHA256"),
            production_transcript=top,
            canonicalized_transcript=canonicalized,
            baseline_text=required_string(row, "baselineText"),
            baseline_canonicalized=required_string(row, "baselineCanonicalized"),
            audio_duration_seconds=required_number(row, "audioDurationSeconds"),
            alternatives=alternatives,
            confidence_mean=mean,
            confidence_minimum=minimum,
            max_alternative_word_edits=max_edits,
            canonicalizer_changed=canonicalizer_changed,
            production_mode_disagreement=mode_disagreement,
            repeated_disagreement_spans=repeated,
            repeated_span_max_files=repeated_max,
            applied_correction_record_ids=tuple(
                string_list(row, "appliedCorrectionRecordIDs")
            ),
            correction_attribution_available=True,
            correction_dictionary_fingerprint=required_sha256(
                row, "correctionDictionaryFingerprint"
            ),
            score=score,
            reason_codes=reason_codes,
        ))
    fingerprints = {
        candidate.correction_dictionary_fingerprint
        for candidate in candidates
    }
    if len(fingerprints) != 1:
        raise LabelQueueError(
            "replay mixes correction dictionary fingerprints: "
            + ", ".join(sorted(fingerprints))
        )
    return candidates


def validate_production_group(
    file: str,
    variants: dict[str, JsonObject],
) -> None:
    production = [variants[name] for name in sorted(REQUIRED_PRODUCTION_VARIANTS)]
    alternatives_row = variants[PRODUCTION_ALTERNATIVES]
    if alternatives_row.get("includeAlternatives") is not True:
        raise LabelQueueError(
            f"{file}: {PRODUCTION_ALTERNATIVES} must include alternatives"
        )
    alternatives = string_list(
        alternatives_row,
        "variantAlternativeTranscriptCandidates",
    )
    if not alternatives or len(set(alternatives)) != len(alternatives):
        raise LabelQueueError(f"{file}: alternatives must be non-empty and unique")
    for row in production:
        if row.get("evalSchemaVersion") != 1:
            raise LabelQueueError(f"{file}: unsupported eval schema")
        if row.get("contextReadbackMatches") is not True:
            raise LabelQueueError(f"{file}: production context readback did not match")
        required_string(row, "variantText")
        required_sha256(row, "correctionDictionaryFingerprint")
        required_sha256(row, "audioSHA256")
        string_list(row, "appliedCorrectionRecordIDs")
        optional_number(row, "variantConfidenceMean")
        optional_number(row, "variantConfidenceMinimum")
        required_number(row, "audioDurationSeconds")
    for field in (
        "audioSHA256",
        "audioDurationSeconds",
        "localeIdentifier",
        "baselineText",
        "baselineCanonicalized",
        "correctionDictionaryFingerprint",
    ):
        values = {json.dumps(row.get(field), sort_keys=True) for row in production}
        if len(values) != 1:
            raise LabelQueueError(f"{file}: production rows disagree on {field}")


def required_string(row: JsonObject, key: str) -> str:
    value = row.get(key)
    if not isinstance(value, str) or not value.strip():
        raise LabelQueueError(
            f"{row.get('file', '<unknown>')}: {key} must be a non-empty string"
        )
    return value.strip()


def required_sha256(row: JsonObject, key: str) -> str:
    value = row.get(key)
    if not isinstance(value, str) or SHA256_PATTERN.fullmatch(value) is None:
        raise LabelQueueError(
            f"{row.get('file', '<unknown>')}: {key} must be 64 lowercase hex characters"
        )
    return value


def string_list(row: JsonObject, key: str) -> list[str]:
    value = row.get(key)
    if not isinstance(value, list) or any(not isinstance(item, str) for item in value):
        raise LabelQueueError(
            f"{row.get('file', '<unknown>')}: {key} must be a string array"
        )
    return [item.strip() for item in value if item.strip()]


def optional_number(row: JsonObject, key: str) -> float | None:
    value = row.get(key)
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise LabelQueueError(
            f"{row.get('file', '<unknown>')}: {key} must be numeric or null"
        )
    parsed = float(value)
    if not math.isfinite(parsed) or not 0 <= parsed <= 1:
        raise LabelQueueError(
            f"{row.get('file', '<unknown>')}: {key} must be finite within 0...1"
        )
    return parsed


def required_number(row: JsonObject, key: str) -> float:
    value = row.get(key)
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise LabelQueueError(f"{row.get('file', '<unknown>')}: {key} must be numeric")
    parsed = float(value)
    if not math.isfinite(parsed) or parsed <= 0:
        raise LabelQueueError(
            f"{row.get('file', '<unknown>')}: {key} must be finite and positive"
        )
    return parsed


def validate_recording_filename(file: str) -> None:
    path = Path(file)
    if path.name != file or file in {".", ".."} or not file.casefold().endswith(".wav"):
        raise LabelQueueError(f"unsafe recording filename: {file}")


def unique_normalized_strings(items: Iterable[str], excluding: str) -> list[str]:
    seen = {tuple(normalized_tokens(excluding))}
    unique: list[str] = []
    for item in items:
        key = tuple(normalized_tokens(item))
        if key not in seen:
            seen.add(key)
            unique.append(item)
    return unique
