"""Self-test holdout audio measurement, selection freezing, and the confirm loop."""

from __future__ import annotations

from pathlib import Path
import struct
from types import SimpleNamespace

from confirm_cli import resolve_selection
from confirm_session_self_test import run_self_test as run_session_self_test
from corpus_reader import Corpus, CorpusEntry
from holdout_audio import HoldoutAudioError, file_sha256, wav_duration_seconds
from holdout_confirmations import Confirmation
from holdout_freeze import load_selection, validate_selection, write_selection
from holdout_selection import (
    CHRONOLOGICAL_STRATA,
    DURATION_STRATA,
    Selection,
    SelectionError,
    compute_selection,
)


SAMPLE_RATE = 48000
BLOCK_ALIGN = 4
DATA_HEADER_END = 44
POOL_SIZE = 60
SELECTION_SIZE = 12


def run_self_test(root: Path) -> None:
    run_audio_self_test(root)
    recordings = root / "recordings"
    recordings.mkdir()
    corpus = fixture_corpus(recordings)
    run_selection_self_test(root, recordings, corpus)
    run_session_self_test(root, recordings, corpus)


def run_audio_self_test(root: Path) -> None:
    audio = root / "audio"
    audio.mkdir()
    exact = write_wav(audio / "exact.wav", 2.5)
    assert abs(wav_duration_seconds(exact) - 2.5) < 1e-9

    (audio / "not-riff.wav").write_bytes(b"ID3" + b"\0" * 40)
    expect_error(
        lambda: wav_duration_seconds(audio / "not-riff.wav"),
        "not a RIFF/WAVE file",
        HoldoutAudioError,
    )
    truncated = audio / "truncated.wav"
    truncated.write_bytes(exact.read_bytes()[:20])
    expect_error(
        lambda: wav_duration_seconds(truncated),
        "truncated fmt chunk",
        HoldoutAudioError,
    )
    lying = audio / "lying.wav"
    header = bytearray(exact.read_bytes()[:DATA_HEADER_END])
    header[DATA_HEADER_END - 4:] = struct.pack("<I", 1 << 30)
    lying.write_bytes(bytes(header))
    expect_error(
        lambda: wav_duration_seconds(lying),
        "data chunk exceeds file size",
        HoldoutAudioError,
    )


def run_selection_self_test(root: Path, recordings: Path, corpus: Corpus) -> None:
    selection = compute_selection(corpus, recordings, size=SELECTION_SIZE)
    again = compute_selection(corpus, recordings, size=SELECTION_SIZE)
    assert selection == again, "selection must be reproducible without any state"
    assert len(selection.recordings) == SELECTION_SIZE
    assert selection.pool_size == POOL_SIZE
    assert len({item.file for item in selection.recordings}) == SELECTION_SIZE
    assert [item.file for item in selection.recordings] == sorted(
        item.file for item in selection.recordings
    ), "the session must walk the holdout in chronological order"

    pooled = {
        file for file, entry in corpus.entries_by_file.items()
        if entry.verification_status == "unlabeled"
    }
    assert {item.file for item in selection.recordings} <= pooled, (
        "inferred and confirmed recordings are contaminated as a holdout"
    )
    cells = {
        (item.duration_stratum, item.chronological_stratum)
        for item in selection.recordings
    }
    assert len(cells) == DURATION_STRATA * CHRONOLOGICAL_STRATA, (
        "every duration-by-chronology cell must be represented"
    )
    for stratum in range(1, DURATION_STRATA + 1):
        picks = [
            item for item in selection.recordings if item.duration_stratum == stratum
        ]
        assert len(picks) >= SELECTION_SIZE // DURATION_STRATA - 1, len(picks)

    expect_error(
        lambda: compute_selection(corpus, recordings, size=POOL_SIZE + 1),
        "pool holds 60",
    )
    run_freeze_self_test(root, recordings, corpus, selection)


def run_freeze_self_test(
    root: Path,
    recordings: Path,
    corpus: Corpus,
    selection: Selection,
) -> None:
    path = root / "holdout-selection.json"
    write_selection(path, selection, replace=False)
    assert load_selection(path) == selection, "freezing must round-trip exactly"
    expect_error(
        lambda: write_selection(path, selection, replace=False),
        "already frozen",
    )
    assert validate_selection(selection, corpus, recordings) == []

    frozen = path.read_text(encoding="utf-8")
    path.write_text(
        frozen.replace(selection.recordings[0].file, "swapped.wav"),
        encoding="utf-8",
    )
    expect_error(lambda: load_selection(path), "edited after freezing")
    path.write_text(frozen, encoding="utf-8")

    changed = recordings / selection.recordings[0].file
    original = changed.read_bytes()
    write_wav(changed, 9.5)
    expect_error(
        lambda: validate_selection(selection, corpus, recordings),
        "audio changed since selection",
    )
    changed.write_bytes(original)
    drifted = Corpus(corpus.entries_by_file, "f" * 64)
    assert validate_selection(selection, drifted, recordings), (
        "a regenerated corpus must be reported, not treated as tampering"
    )
    run_never_recompute_self_test(path, recordings, corpus, selection)
    assert not path.exists()


def run_never_recompute_self_test(
    path: Path,
    recordings: Path,
    corpus: Corpus,
    selection: Selection,
) -> None:
    """A confirmation may only ever resume against the selection it was made under."""
    resume = SimpleNamespace(reselect=False, size=len(selection.recordings))
    confirmed = [sample_confirmation(selection.recordings[0].file, selection.sha256)]
    assert resolve_selection(path, corpus, recordings, resume, confirmed)[0] == selection
    orphan = [sample_confirmation(selection.recordings[0].file, "0" * 64)]
    expect_error(
        lambda: resolve_selection(path, corpus, recordings, resume, orphan),
        "made under a different holdout selection",
    )
    path.unlink()
    expect_error(
        lambda: resolve_selection(path, corpus, recordings, resume, confirmed),
        "the frozen selection is missing",
    )
    expect_error(
        lambda: resolve_selection(
            path,
            corpus,
            recordings,
            SimpleNamespace(reselect=True, size=resume.size),
            confirmed,
        ),
        "--reselect would invalidate them",
    )
    fresh, notes = resolve_selection(path, corpus, recordings, resume, [])
    assert (fresh, notes) == (selection, []), (
        "with nothing confirmed, an absent selection is computed as before"
    )


def sample_confirmation(file: str, selection_sha256: str) -> Confirmation:
    return Confirmation(
        file=file,
        audio_sha256="a" * 64,
        human_intended_transcript="Confirmed text.",
        candidate_shown=None,
        candidate_source=None,
        candidate_edited=True,
        selection_sha256=selection_sha256,
    )


def fixture_corpus(recordings: Path) -> Corpus:
    """A pool shaped like the real one: unlabeled recordings plus labeled decoys."""
    entries: dict[str, CorpusEntry] = {}
    for index in range(POOL_SIZE):
        file = f"2026-06-{index // 24 + 1:02d}_{index % 24:02d}-00-{index:03d}.wav"
        duration = 1.0 + (index * 7 % 23) * 0.5
        entries[file] = entry(write_wav(recordings / file, duration), "unlabeled")
    for index in range(5):
        file = f"2026-05-01_00-00-{index:03d}.wav"
        entries[file] = entry(
            write_wav(recordings / file, 3.0 + index),
            "inferred" if index else "human_confirmed",
        )
    return Corpus(entries, "e" * 64)


def entry(path: Path, status: str) -> CorpusEntry:
    return CorpusEntry(
        file=path.name,
        audio_sha256=file_sha256(path),
        transcript_candidate=None if status == "unlabeled" else "Historical text.",
        verification_status=status,
        legacy_ordinal=None if status == "unlabeled" else 1,
        designation="legacy" if status == "human_confirmed" else None,
    )


def write_wav(path: Path, seconds: float) -> Path:
    """Write the 48 kHz mono 32-bit float shape Epos records."""
    frames = round(seconds * SAMPLE_RATE)
    data = bytes(frames * BLOCK_ALIGN)
    fmt = struct.pack(
        "<HHIIHH", 3, 1, SAMPLE_RATE, SAMPLE_RATE * BLOCK_ALIGN, BLOCK_ALIGN, 32
    )
    body = (
        b"WAVE"
        + b"fmt " + struct.pack("<I", len(fmt)) + fmt
        + b"data" + struct.pack("<I", len(data)) + data
    )
    path.write_bytes(b"RIFF" + struct.pack("<I", len(body)) + body)
    return path


def expect_error(action, message: str, kind: type[Exception] = SelectionError) -> None:
    try:
        action()
    except kind as error:
        assert message in str(error), (message, str(error))
    else:
        raise AssertionError(f"expected {kind.__name__} containing {message!r}")
