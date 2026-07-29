"""Fixtures and coverage checks for the label queue's corpus contract."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
from pathlib import Path

from corpus_reader import Corpus, CorpusReadError
from corpus_reader_self_test import corpus_rows
from label_artifact import JsonObject, build_candidates, load_rows
from label_corpus import validate_recording_coverage
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
    corpus: Corpus
    confirmed_file: str


def build_fixture(root: Path) -> LabelFixture:
    recordings = root / "recordings"
    recordings.mkdir()
    rows: list[JsonObject] = []
    confirmed: list[tuple[str, str, str]] = []
    inferred: list[tuple[str, str, str]] = []
    unlabeled: list[tuple[str, str]] = []
    confirmed_file = "confirmed-01.wav"
    for ordinal in range(1, 36):
        file = f"confirmed-{ordinal:02d}.wav"
        confirmed.append((
            file,
            write_recording(recordings, file, f"confirmed audio {ordinal}"),
            f"human confirmed transcript {ordinal}",
        ))
    for index in range(113):
        file = f"sample-{index:02d}.wav"
        audio_sha256 = write_recording(recordings, file, f"audio {index}")
        if index < 79:
            inferred.append((file, audio_sha256, f"historical candidate {index}"))
        else:
            unlabeled.append((file, audio_sha256))
        rows.extend(replay_rows(index, file, audio_sha256))

    artifact = root / "context.jsonl"
    write_jsonl(artifact, rows)
    loaded, artifact_sha256 = load_rows(artifact)
    candidates = build_candidates(loaded)
    corpus_path = root / "evaluation-corpus-v2.jsonl"
    ledger_rows = corpus_rows(
        confirmed=confirmed,
        inferred=inferred,
        unlabeled=unlabeled,
    )
    write_jsonl(corpus_path, ledger_rows)
    corpus = validate_recording_coverage(candidates, recordings, corpus_path)
    return LabelFixture(
        recordings,
        rows,
        artifact,
        loaded,
        artifact_sha256,
        candidates,
        ledger_rows,
        corpus_path,
        corpus,
        confirmed_file,
    )


def write_recording(recordings: Path, file: str, content: str) -> str:
    audio = content.encode()
    (recordings / file).write_bytes(audio)
    return hashlib.sha256(audio).hexdigest()


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

    invalid_rows = copy_rows(fixture.corpus_rows)
    invalid_rows[0]["verificationStatus"] = "inferred"
    write_jsonl(fixture.corpus_path, invalid_rows)
    expect_coverage_error(fixture, "inferred legacyOrdinal must be within 36...114")
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
    except (CorpusReadError, LabelQueueError) as error:
        assert message in str(error), str(error)
    else:
        raise AssertionError(f"expected coverage failure containing: {message}")


def copy_rows(rows: list[JsonObject]) -> list[JsonObject]:
    return [dict(row) for row in rows]


def write_jsonl(path: Path, rows: list[JsonObject]) -> None:
    path.write_text(
        "".join(json.dumps(row) + "\n" for row in rows),
        encoding="utf-8",
    )


def status_counts(corpus: Corpus) -> dict[str, int]:
    return {
        status: sum(
            entry.verification_status == status
            for entry in corpus.entries_by_file.values()
        )
        for status in ("human_confirmed", "inferred", "unlabeled")
    }
