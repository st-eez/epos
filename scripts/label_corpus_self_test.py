"""Fixtures and behavioral checks for the v2 evaluation corpus contract."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
from pathlib import Path

from label_artifact import JsonObject, build_candidates, load_rows
from label_corpus import CorpusCoverage, load_corpus, validate_recording_coverage
from label_queue import Candidate, LabelQueueError


@dataclass(frozen=True)
class LabelFixture:
    recordings: Path
    rows: list[JsonObject]
    artifact: Path
    loaded: list[JsonObject]
    artifact_sha256: str
    candidates: list[Candidate]
    corpus_rows: list[JsonObject]
    corpus_path: Path
    corpus: CorpusCoverage
    confirmed_file: str


def build_fixture(root: Path) -> LabelFixture:
    recordings = root / "recordings"
    recordings.mkdir()
    rows: list[JsonObject] = []
    corpus_rows: list[JsonObject] = []
    confirmed_file = "confirmed-01.wav"
    for ordinal in range(1, 36):
        file = f"confirmed-{ordinal:02d}.wav"
        audio = f"confirmed audio {ordinal}".encode()
        (recordings / file).write_bytes(audio)
        corpus_rows.append({
            "schemaVersion": 2,
            "file": file,
            "audioSHA256": hashlib.sha256(audio).hexdigest(),
            "transcriptCandidate": f"human confirmed transcript {ordinal}",
            "verificationStatus": "human_confirmed",
            "legacyOrdinal": ordinal,
        })
    for index in range(113):
        file = f"sample-{index:02d}.wav"
        audio = f"audio {index}".encode()
        (recordings / file).write_bytes(audio)
        audio_sha256 = hashlib.sha256(audio).hexdigest()
        inferred = index < 79
        corpus_rows.append({
            "schemaVersion": 2,
            "file": file,
            "audioSHA256": audio_sha256,
            "transcriptCandidate": f"historical candidate {index}"
            if inferred else None,
            "verificationStatus": "inferred" if inferred else "unlabeled",
            "legacyOrdinal": index + 36 if inferred else None,
        })
        rows.extend(replay_rows(index, file, audio_sha256))

    artifact = root / "context.jsonl"
    write_jsonl(artifact, rows)
    loaded, artifact_sha256 = load_rows(artifact)
    candidates = build_candidates(loaded)
    corpus_path = root / "evaluation-corpus-v2.jsonl"
    write_jsonl(corpus_path, corpus_rows)
    corpus = validate_recording_coverage(candidates, recordings, corpus_path)
    return LabelFixture(
        recordings,
        rows,
        artifact,
        loaded,
        artifact_sha256,
        candidates,
        corpus_rows,
        corpus_path,
        corpus,
        confirmed_file,
    )


def replay_rows(index: int, file: str, audio_sha256: str) -> list[JsonObject]:
    top = f"sample phrase {index}"
    canonicalized = f"corrected phrase {index}" if index >= 30 else top
    alternative = f"sample other phrase {index}" if index < 28 else top
    return [{
        "file": file,
        "audioSHA256": audio_sha256,
        "variant": variant,
        "variantText": top,
        "variantCanonicalized": canonicalized,
        "baselineText": top,
        "baselineCanonicalized": top,
        "variantAlternativeTranscriptCandidates": [alternative]
        if variant == "production-alternatives" else [],
        "variantConfidenceMean": 0.50 + ((index % 40) * 0.01),
        "variantConfidenceMinimum": 0.10 + ((index % 40) * 0.01),
        "audioDurationSeconds": 1.5,
        "localeIdentifier": "en-US",
        "contextReadbackMatches": True,
        "includeAlternatives": variant == "production-alternatives",
        "evalSchemaVersion": 1,
        "correctionDictionaryFingerprint": "f" * 64,
        "appliedCorrectionRecordIDs": [f"correction-{index}"]
        if index >= 30 else [],
    } for variant in (
        "production-setContext",
        "production-initializer",
        "production-alternatives",
    )]


def run_corpus_self_tests(fixture: LabelFixture, root: Path) -> None:
    assert status_counts(fixture.corpus) == {
        "human_confirmed": 35,
        "inferred": 79,
        "unlabeled": 34,
    }
    assert fixture.confirmed_file not in {
        candidate.file for candidate in fixture.candidates
    }

    confirmed_source_rows = copy_rows(fixture.corpus_rows)
    confirmed_source_rows[35]["verificationStatus"] = "human_confirmed"
    write_jsonl(fixture.corpus_path, confirmed_source_rows)
    expect_load_error(
        fixture.corpus_path,
        "human-confirmed legacyOrdinal must be within 1...35",
    )

    stale_rows = copy_rows(fixture.corpus_rows)
    stale_rows.append({
        "schemaVersion": 2,
        "file": "stale.wav",
        "audioSHA256": "0" * 64,
        "transcriptCandidate": None,
        "verificationStatus": "unlabeled",
        "legacyOrdinal": None,
    })
    write_jsonl(fixture.corpus_path, stale_rows)
    expect_coverage_error(fixture, "stale corpus rows=1[stale.wav]")
    write_jsonl(fixture.corpus_path, fixture.corpus_rows)

    changed_audio = fixture.recordings / fixture.candidates[0].file
    original_audio = changed_audio.read_bytes()
    changed_audio.write_bytes(b"changed")
    expect_coverage_error(fixture, "audio SHA-256 mismatch")
    changed_audio.write_bytes(original_audio)

    expect_coverage_error(
        fixture,
        "evaluation corpus does not exist",
        root / "missing-corpus.jsonl",
    )
    expect_invalid_corpus(
        fixture, 35, {"transcriptCandidate": None},
        "inferred rows require a transcriptCandidate",
    )
    expect_invalid_corpus(
        fixture, 114, {"legacyOrdinal": 99},
        "unlabeled rows require null transcriptCandidate and legacyOrdinal",
    )
    expect_invalid_corpus(
        fixture, 36, {"legacyOrdinal": 36}, "duplicate legacyOrdinal",
    )
    expect_invalid_corpus(
        fixture, 35, {"file": "../escape.wav"}, "unsafe recording filename",
    )
    missing_field_rows = copy_rows(fixture.corpus_rows)
    del missing_field_rows[35]["transcriptCandidate"]
    write_jsonl(fixture.corpus_path, missing_field_rows)
    expect_load_error(fixture.corpus_path, "missing fields: transcriptCandidate")
    write_jsonl(fixture.corpus_path, fixture.corpus_rows)


def expect_coverage_error(
    fixture: LabelFixture,
    message: str,
    corpus_path: Path | None = None,
) -> None:
    try:
        validate_recording_coverage(
            fixture.candidates,
            fixture.recordings,
            corpus_path or fixture.corpus_path,
        )
    except LabelQueueError as error:
        assert message in str(error), str(error)
    else:
        raise AssertionError(f"expected coverage failure containing: {message}")


def expect_invalid_corpus(
    fixture: LabelFixture,
    row_index: int,
    changes: JsonObject,
    message: str,
) -> None:
    rows = copy_rows(fixture.corpus_rows)
    rows[row_index].update(changes)
    write_jsonl(fixture.corpus_path, rows)
    expect_load_error(fixture.corpus_path, message)


def expect_load_error(path: Path, message: str) -> None:
    try:
        load_corpus(path)
    except LabelQueueError as error:
        assert message in str(error), str(error)
    else:
        raise AssertionError(f"expected corpus failure containing: {message}")


def copy_rows(rows: list[JsonObject]) -> list[JsonObject]:
    return [dict(row) for row in rows]


def write_jsonl(path: Path, rows: list[JsonObject]) -> None:
    path.write_text(
        "".join(json.dumps(row) + "\n" for row in rows),
        encoding="utf-8",
    )


def status_counts(corpus: CorpusCoverage) -> dict[str, int]:
    return {
        status: sum(
            entry.verification_status == status
            for entry in corpus.entries_by_file.values()
        )
        for status in ("human_confirmed", "inferred", "unlabeled")
    }
