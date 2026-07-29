"""Behavioral checks for the deterministic audio label queue."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import cast

from label_artifact import (
    JsonObject,
    build_candidates,
    load_rows,
)
from label_corpus import validate_recording_coverage
from label_cli import validate_output_paths, write_outputs
from label_queue import (
    Candidate,
    LabelQueueError,
    disagreement_spans,
    normalized_tokens,
    select_queue,
    word_edit_distance,
)
from label_render import entry_row, render_jsonl, render_markdown


def run_self_test(root: Path) -> None:
    assert normalized_tokens("Hello, C++!") == ["hello", "c", "+", "+"]
    assert word_edit_distance("run tests", "run the tests") == 1
    assert word_edit_distance("same.", "Same!") == 0
    assert disagreement_spans("run tests", "run the tests") == {("∅", "the")}

    recordings = root / "recordings"
    recordings.mkdir()
    rows: list[JsonObject] = []
    for index in range(36):
        file = f"sample-{index:02d}.wav"
        audio = f"audio {index}".encode()
        (recordings / file).write_bytes(audio)
        audio_sha256 = hashlib.sha256(audio).hexdigest()
        top = f"sample phrase {index}"
        canonicalized = f"corrected phrase {index}" if index >= 30 else top
        alternative = f"sample other phrase {index}" if index < 28 else top
        mean = 0.50 + (index * 0.01)
        minimum = 0.10 + (index * 0.01)
        for variant in (
            "production-setContext",
            "production-initializer",
            "production-alternatives",
        ):
            rows.append({
                "file": file,
                "audioSHA256": audio_sha256,
                "variant": variant,
                "variantText": top,
                "variantCanonicalized": canonicalized,
                "baselineText": top,
                "baselineCanonicalized": top,
                "variantAlternativeTranscriptCandidates": [alternative]
                if variant == "production-alternatives" else [],
                "variantConfidenceMean": mean,
                "variantConfidenceMinimum": minimum,
                "audioDurationSeconds": 1.5,
                "localeIdentifier": "en-US",
                "contextReadbackMatches": True,
                "includeAlternatives": variant == "production-alternatives",
                "evalSchemaVersion": 1,
                "correctionDictionaryFingerprint": "f" * 64,
                "appliedCorrectionRecordIDs": [f"correction-{index}"]
                if index >= 30 else [],
            })

    artifact = root / "context.jsonl"
    artifact.write_text(
        "".join(json.dumps(row) + "\n" for row in rows),
        encoding="utf-8",
    )
    loaded, digest = load_rows(artifact)
    candidates = build_candidates(loaded)
    ground_truth = recordings / "ground-truth.jsonl"
    ground_truth.write_text("", encoding="utf-8")
    validate_recording_coverage(candidates, recordings, ground_truth)
    ground_truth.unlink()
    validate_recording_coverage(candidates, recordings, ground_truth)
    ground_truth.write_text("", encoding="utf-8")
    entries = select_queue(candidates)
    rendered = render_jsonl(entries, artifact.name, digest)
    queue = [
        cast(JsonObject, json.loads(line))
        for line in rendered.splitlines()
    ]

    assert len(candidates) == 36
    assert len(entries) == 30
    assert len({entry.candidate.file for entry in entries}) == 30
    assert [entry.rank for entry in entries] == list(range(1, 31))
    assert all(row["status"] == "unreviewed" for row in queue)
    assert all(row["humanIntendedTranscript"] is None for row in queue)
    assert all(not row["recognizerEvidenceIsGroundTruth"] for row in queue)
    assert all(
        cast(JsonObject, row["provenance"])["sourceArtifactSHA256"] == digest
        for row in queue
    )
    assert all(
        cast(JsonObject, row["provenance"])["audioSHA256"]
        == entry.candidate.audio_sha256
        for row, entry in zip(queue, entries, strict=True)
    )
    assert any(entry.selection_bucket == "correction-audit" for entry in entries)
    assert any(entry.selection_bucket == "control" for entry in entries)
    correction_entry = next(
        entry for entry in entries if entry.candidate.applied_correction_record_ids
    )
    correction_row = entry_row(correction_entry, artifact.name, digest)
    assert cast(JsonObject, correction_row["signals"])["appliedCorrectionRecordIDs"]
    assert "# Epos audio label queue" in render_markdown(entries, recordings)

    duplicate = loaded + [loaded[0]]
    expect_error(duplicate, "duplicate row")

    missing = [row for row in loaded if not (
        row["file"] == "sample-00.wav"
        and row["variant"] == "production-alternatives"
    )]
    expect_error(missing, "missing variants")

    extra = [dict(row) for row in loaded]
    extra.append({
        **loaded[0],
        "variant": "production-stale-experiment",
        "variantText": "unrelated stale result",
    })
    extra_candidates = build_candidates(extra)
    assert not next(
        item for item in extra_candidates if item.file == "sample-00.wav"
    ).production_mode_disagreement

    inconsistent_hash = [
        dict(row) for row in loaded if row["file"] == "sample-00.wav"
    ]
    inconsistent_hash[-1]["audioSHA256"] = "0" * 64
    expect_error(inconsistent_hash, "production rows disagree on audioSHA256")

    invalid_hash = [
        dict(row) for row in loaded if row["file"] == "sample-00.wav"
    ]
    invalid_hash[-1]["audioSHA256"] = "A" * 64
    expect_error(invalid_hash, "64 lowercase hex characters")

    ground_truth.write_text(
        json.dumps({
            "file": candidates[0].file,
            "humanIntendedTranscript": "confirmed",
        }) + "\n",
        encoding="utf-8",
    )
    expect_coverage_error(
        candidates, recordings, ground_truth, "already labeled=1["
    )

    ground_truth.write_text(
        json.dumps({
            "file": "stale.wav",
            "humanIntendedTranscript": "confirmed",
        }) + "\n",
        encoding="utf-8",
    )
    expect_coverage_error(candidates, recordings, ground_truth, "stale labels=1[stale.wav]")
    ground_truth.write_text("", encoding="utf-8")

    changed_audio = recordings / candidates[0].file
    original_audio = changed_audio.read_bytes()
    changed_audio.write_bytes(b"changed")
    expect_coverage_error(candidates, recordings, ground_truth, "audio SHA-256 mismatch")
    changed_audio.write_bytes(original_audio)

    unsafe = dict(rows[0])
    unsafe["file"] = "../escape.wav"
    expect_error([unsafe], "unsafe recording filename")

    invalid_confidence_rows = [
        dict(row) for row in rows if row["file"] == "sample-00.wav"
    ]
    invalid_confidence_rows[-1]["variantConfidenceMean"] = float("nan")
    expect_error(invalid_confidence_rows, "finite within 0...1")

    invalid_manifest = recordings / "invalid-ground-truth.jsonl"
    invalid_manifest.write_text(
        json.dumps({
            "file": candidates[0].file,
            "humanIntendedTranscript": " ",
        }) + "\n",
        encoding="utf-8",
    )
    expect_coverage_error(
        candidates, recordings, invalid_manifest, "humanIntendedTranscript"
    )

    try:
        validate_output_paths(
            artifact,
            recordings / "ground-truth.jsonl",
            root / "review.md",
            recordings,
        )
    except LabelQueueError as error:
        assert "must not be inside the recordings directory" in str(error)
    else:
        raise AssertionError("recordings-directory output was accepted")

    first_output = root / "first-output"
    first_output.write_text("old", encoding="utf-8")
    blocked_output = root / "blocked-output"
    blocked_output.mkdir()
    (blocked_output / "child").write_text("keep", encoding="utf-8")
    try:
        write_outputs({
            first_output: "new",
            blocked_output: "cannot replace a nonempty directory",
        })
    except OSError:
        assert first_output.read_text(encoding="utf-8") == "old"
        assert (blocked_output / "child").read_text(encoding="utf-8") == "keep"
    else:
        raise AssertionError("transaction failure test did not fail")


def expect_error(rows: list[JsonObject], message: str) -> None:
    try:
        build_candidates(rows)
    except LabelQueueError as error:
        assert message in str(error), str(error)
    else:
        raise AssertionError(f"expected artifact failure containing: {message}")


def expect_coverage_error(
    candidates: list[Candidate],
    recordings: Path,
    manifest: Path,
    message: str,
) -> None:
    try:
        validate_recording_coverage(candidates, recordings, manifest)
    except LabelQueueError as error:
        assert message in str(error), str(error)
    else:
        raise AssertionError(f"expected coverage failure containing: {message}")
