"""Validate replay coverage against the provenance-aware evaluation corpus."""

from __future__ import annotations

import hashlib
from pathlib import Path

from corpus_reader import Corpus, load_corpus
from label_queue import Candidate, LabelQueueError


def validate_recording_coverage(
    candidates: list[Candidate],
    recordings_directory: Path,
    corpus_path: Path,
) -> Corpus:
    if not recordings_directory.is_dir():
        raise LabelQueueError(
            f"recordings directory does not exist: {recordings_directory}"
        )
    if not corpus_path.is_file():
        raise LabelQueueError(f"evaluation corpus does not exist: {corpus_path}")

    recording_files = {
        item.name for item in recordings_directory.iterdir()
        if item.is_file() and item.suffix.casefold() == ".wav"
    }
    corpus = load_corpus(corpus_path)
    corpus_files = set(corpus.entries_by_file)
    stale_corpus = corpus_files - recording_files
    recordings_absent_from_corpus = recording_files - corpus_files
    confirmed_files = {
        file for file, entry in corpus.entries_by_file.items()
        if entry.verification_status == "human_confirmed"
    }
    reviewable_files = corpus_files - confirmed_files
    source_files = {candidate.file for candidate in candidates}
    already_confirmed = source_files & confirmed_files
    missing_audio = source_files - recording_files
    missing_from_source = reviewable_files - source_files
    unexpected_source = source_files - reviewable_files
    if (
        stale_corpus
        or recordings_absent_from_corpus
        or already_confirmed
        or missing_audio
        or missing_from_source
        or unexpected_source
    ):
        raise LabelQueueError(
            "corpus coverage mismatch: "
            f"stale corpus rows={format_file_set(stale_corpus)}, "
            "recordings absent from corpus="
            f"{format_file_set(recordings_absent_from_corpus)}, "
            f"already human-confirmed={format_file_set(already_confirmed)}, "
            f"missing audio={format_file_set(missing_audio)}, "
            "reviewable recordings absent from artifact="
            f"{format_file_set(missing_from_source)}, "
            f"unexpected artifact files={format_file_set(unexpected_source)}"
        )

    candidates_by_file = {candidate.file: candidate for candidate in candidates}
    for file in sorted(recording_files):
        actual = file_sha256(recordings_directory / file)
        corpus_expected = corpus.entries_by_file[file].audio_sha256
        if actual != corpus_expected:
            raise LabelQueueError(
                f"{file}: audio SHA-256 mismatch; "
                f"corpus={corpus_expected}, recording={actual}"
            )
        candidate = candidates_by_file.get(file)
        if candidate is not None and candidate.audio_sha256 != corpus_expected:
            raise LabelQueueError(
                f"{file}: audio SHA-256 mismatch; "
                f"artifact={candidate.audio_sha256}, corpus={corpus_expected}"
            )
    return corpus


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def format_file_set(files: set[str]) -> str:
    return f"{len(files)}[{', '.join(sorted(files))}]"
