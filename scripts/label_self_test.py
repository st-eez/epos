"""Behavioral checks for the deterministic audio label queue."""

from __future__ import annotations

import json
from pathlib import Path
from typing import cast

from label_artifact import JsonObject, build_candidates
from label_cli import discover_input, validate_output_paths, write_outputs
from label_corpus_self_test import build_fixture, run_corpus_self_tests
from label_queue import (
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

    fixture = build_fixture(root)
    recordings = fixture.recordings
    rows = fixture.rows
    artifact = fixture.artifact
    loaded = fixture.loaded
    digest = fixture.artifact_sha256
    candidates = fixture.candidates
    corpus_path = fixture.corpus_path
    corpus = fixture.corpus
    run_corpus_self_tests(fixture, root)
    entries = select_queue(candidates)
    rendered = render_jsonl(
        entries,
        artifact.name,
        digest,
        corpus,
        corpus_path.name,
    )
    queue = [
        cast(JsonObject, json.loads(line))
        for line in rendered.splitlines()
    ]

    assert len(candidates) == 113
    assert len(entries) == 30
    assert len({entry.candidate.file for entry in entries}) == 30
    assert [entry.rank for entry in entries] == list(range(1, 31))
    assert all(row["status"] == "unreviewed" for row in queue)
    assert all(row["humanIntendedTranscript"] is None for row in queue)
    assert all(not row["recognizerEvidenceIsGroundTruth"] for row in queue)
    assert all(
        not row["historicalTranscriptCandidateIsGroundTruth"]
        for row in queue
    )
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
    correction_row = entry_row(
        correction_entry,
        artifact.name,
        digest,
        corpus,
        corpus_path.name,
    )
    assert cast(JsonObject, correction_row["signals"])["appliedCorrectionRecordIDs"]
    markdown = render_markdown(entries, recordings, corpus)
    assert "# Epos audio label queue" in markdown
    assert "Historical transcript candidate, not ground truth:" in markdown
    inferred_rows = [
        row for row in queue if row["sourceVerificationStatus"] == "inferred"
    ]
    assert inferred_rows
    assert all(row["historicalTranscriptCandidate"] for row in inferred_rows)
    unlabeled_rows = [
        row for row in queue if row["sourceVerificationStatus"] == "unlabeled"
    ]
    assert unlabeled_rows
    assert all(row["historicalTranscriptCandidate"] is None for row in unlabeled_rows)

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

    mixed_dictionary = [dict(row) for row in loaded]
    for row in mixed_dictionary:
        if row["file"] == "sample-00.wav":
            row["correctionDictionaryFingerprint"] = "1" * 64
    expect_error(mixed_dictionary, "mixes correction dictionary fingerprints")

    invalid_hash = [
        dict(row) for row in loaded if row["file"] == "sample-00.wav"
    ]
    invalid_hash[-1]["audioSHA256"] = "A" * 64
    expect_error(invalid_hash, "64 lowercase hex characters")

    unsafe = dict(rows[0])
    unsafe["file"] = "../escape.wav"
    expect_error([unsafe], "unsafe recording filename")

    invalid_confidence_rows = [
        dict(row) for row in rows if row["file"] == "sample-00.wav"
    ]
    invalid_confidence_rows[-1]["variantConfidenceMean"] = float("nan")
    expect_error(invalid_confidence_rows, "finite within 0...1")

    try:
        validate_output_paths(
            artifact,
            corpus_path,
            recordings / "evaluation-corpus-v2.jsonl",
            root / "review.md",
            recordings,
        )
    except LabelQueueError as error:
        assert "must not be inside the recordings directory" in str(error)
    else:
        raise AssertionError("recordings-directory output was accepted")

    try:
        validate_output_paths(
            artifact,
            corpus_path,
            corpus_path,
            root / "review.md",
            recordings,
        )
    except LabelQueueError as error:
        assert "must not replace replay or corpus inputs" in str(error)
    else:
        raise AssertionError("corpus-replacing output was accepted")

    first_output = root / "first-output"
    first_output.write_text("old", encoding="utf-8")
    blocked_output = root / "blocked-output"
    blocked_output.mkdir()
    (blocked_output / "child").write_text("keep", encoding="utf-8")
    try:
        write_outputs(
            {
                first_output: "new",
                blocked_output: "cannot replace a nonempty directory",
            },
            replace=True,
        )
    except OSError:
        assert first_output.read_text(encoding="utf-8") == "old"
        assert (blocked_output / "child").read_text(encoding="utf-8") == "keep"
    else:
        raise AssertionError("transaction failure test did not fail")

    collision = root / "noncooperating-collision"
    collision.write_text("keep", encoding="utf-8")
    try:
        write_outputs({collision: "replace"}, replace=False)
    except FileExistsError:
        assert collision.read_text(encoding="utf-8") == "keep"
    else:
        raise AssertionError("non-replace write overwrote an existing output")

    evals = root / ".build" / "evals"
    evals.mkdir(parents=True)
    unlabeled_replay = evals / "unlabeled233-context-newer.jsonl"
    unlabeled_replay.touch()
    reviewable_old = evals / "reviewable312-context-old.jsonl"
    reviewable_old.touch()
    reviewable_new = evals / "reviewable312-context-new.jsonl"
    reviewable_new.touch()
    reviewable_old.touch()
    assert discover_input(root) == reviewable_old
    reviewable_old.unlink()
    reviewable_new.unlink()
    assert discover_input(root) == unlabeled_replay


def expect_error(rows: list[JsonObject], message: str) -> None:
    try:
        build_candidates(rows)
    except LabelQueueError as error:
        assert message in str(error), str(error)
    else:
        raise AssertionError(f"expected artifact failure containing: {message}")
