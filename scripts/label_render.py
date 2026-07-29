"""Render typed labeling queue entries as JSONL and Markdown."""

from __future__ import annotations

import json
from pathlib import Path
from typing import TypeAlias

from label_artifact import PRODUCTION_ALTERNATIVES
from corpus_reader import Corpus
from label_queue import QueueEntry


JsonObject: TypeAlias = dict[str, object]
SCHEMA_VERSION = 1
GENERATOR_VERSION = 1


def render_jsonl(
    entries: list[QueueEntry],
    source_name: str,
    source_sha256: str,
    corpus: Corpus,
    corpus_name: str,
) -> str:
    return "".join(
        json.dumps(
            entry_row(
                entry,
                source_name,
                source_sha256,
                corpus,
                corpus_name,
            ),
            sort_keys=True,
        ) + "\n"
        for entry in entries
    )


def render_markdown(
    entries: list[QueueEntry],
    recordings_directory: Path,
    corpus: Corpus,
) -> str:
    lines = [
        "# Epos audio label queue",
        "",
        "These are review candidates, not ground truth. Listen to each recording and fill",
        "`humanIntendedTranscript` only with the words actually spoken. Leave uncertain",
        "audio unlabeled.",
        "",
    ]
    for entry in entries:
        candidate = entry.candidate
        corpus_entry = corpus.entries_by_file[candidate.file]
        lines.extend([
            f"## {entry.rank}. `{candidate.file}`",
            "",
            f"- Bucket: `{entry.selection_bucket}`",
            f"- Review score: {candidate.score}",
            f"- Recognizer, not truth: {candidate.production_transcript}",
            f"- Canonicalized: {candidate.canonicalized_transcript}",
            f"- Confidence: mean {format_number(candidate.confidence_mean)}, "
            f"minimum {format_number(candidate.confidence_minimum)}",
            f"- Maximum alternative word edits: {candidate.max_alternative_word_edits}",
            f"- Canonicalizer changed text: {str(candidate.canonicalizer_changed).lower()}",
            f"- Corpus verification status: `{corpus_entry.verification_status}`",
            f"- Audio: `{recordings_directory / candidate.file}`",
            "- Human intended transcript:",
            "",
        ])
        if corpus_entry.transcript_candidate is not None:
            lines.insert(
                len(lines) - 3,
                "- Historical transcript candidate, not ground truth: "
                f"{corpus_entry.transcript_candidate}",
            )
        if candidate.alternatives:
            lines.append("Alternatives:")
            lines.append("")
            for alternative in candidate.alternatives:
                lines.append(f"- {alternative}")
            lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def entry_row(
    entry: QueueEntry,
    source_name: str,
    source_sha256: str,
    corpus: Corpus,
    corpus_name: str,
) -> JsonObject:
    candidate = entry.candidate
    corpus_entry = corpus.entries_by_file[candidate.file]
    spans: list[JsonObject] = [
        {
            "recognizedSpan": span.recognized_span,
            "alternativeSpan": span.alternative_span,
            "distinctFileCount": span.distinct_file_count,
        }
        for span in candidate.repeated_disagreement_spans
    ]
    signals: JsonObject = {
        "confidenceMean": candidate.confidence_mean,
        "confidenceMinimum": candidate.confidence_minimum,
        "maxAlternativeWordEdits": candidate.max_alternative_word_edits,
        "canonicalizerChanged": candidate.canonicalizer_changed,
        "productionModeDisagreement": candidate.production_mode_disagreement,
        "repeatedDisagreementSpans": spans,
        "appliedCorrectionRecordIDs": list(candidate.applied_correction_record_ids),
        "correctionAttributionAvailable": candidate.correction_attribution_available,
    }
    provenance: JsonObject = {
        "sourceArtifact": source_name,
        "sourceArtifactSHA256": source_sha256,
        "sourceCorpus": corpus_name,
        "sourceCorpusSHA256": corpus.sha256,
        "sourceVariant": PRODUCTION_ALTERNATIVES,
        "sourceEvalSchemaVersion": 1,
        "audioSHA256": candidate.audio_sha256,
        "correctionDictionaryFingerprint": candidate.correction_dictionary_fingerprint,
        "generator": "scripts/label",
        "generatorVersion": GENERATOR_VERSION,
        "selectionPolicy": "24-priority-3-correction-audit-3-control",
    }
    return {
        "schemaVersion": SCHEMA_VERSION,
        "file": candidate.file,
        "rank": entry.rank,
        "selectionBucket": entry.selection_bucket,
        "reviewScore": candidate.score,
        "reasonCodes": list(candidate.reason_codes),
        "status": "unreviewed",
        "humanIntendedTranscript": None,
        "sourceVerificationStatus": corpus_entry.verification_status,
        "historicalTranscriptCandidate": corpus_entry.transcript_candidate,
        "historicalTranscriptCandidateIsGroundTruth": False,
        "productionTranscript": candidate.production_transcript,
        "canonicalizedTranscript": candidate.canonicalized_transcript,
        "recognizerEvidenceIsGroundTruth": False,
        "baselineText": candidate.baseline_text,
        "baselineCanonicalized": candidate.baseline_canonicalized,
        "audioDurationSeconds": candidate.audio_duration_seconds,
        "alternativeTranscriptCandidates": list(candidate.alternatives),
        "signals": signals,
        "provenance": provenance,
    }


def format_number(value: float | None) -> str:
    return "unavailable" if value is None else f"{value:.3f}"
