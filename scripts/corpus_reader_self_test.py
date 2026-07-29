"""Full-shape corpus fixtures and strict-loader behavioral checks."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any, Sequence

from corpus_reader import (
    CONFIRMED_LEGACY_ORDINALS,
    INFERRED_LEGACY_ORDINALS,
    CorpusReadError,
    load_corpus,
)


CONFIRMED_ROWS = len(CONFIRMED_LEGACY_ORDINALS)
INFERRED_ROWS = len(INFERRED_LEGACY_ORDINALS)
LabeledRow = tuple[str, str, str]


def corpus_rows(
    *,
    confirmed: Sequence[LabeledRow] = (),
    inferred: Sequence[LabeledRow] = (),
    unlabeled: Sequence[tuple[str, str]] = (),
) -> list[dict[str, Any]]:
    """Rows in the exact shape `scripts/corpus` emits, padded to the frozen counts."""
    rows = [
        labeled_row(entry, ordinal, "human_confirmed")
        for ordinal, entry in enumerate(
            padded(confirmed, CONFIRMED_ROWS, "filler-confirmed"), start=1
        )
    ]
    rows.extend(
        labeled_row(entry, ordinal, "inferred")
        for ordinal, entry in enumerate(
            padded(inferred, INFERRED_ROWS, "filler-inferred"),
            start=CONFIRMED_ROWS + 1,
        )
    )
    rows.extend({
        "schemaVersion": 2,
        "file": file,
        "audioSHA256": audio_sha256,
        "transcriptCandidate": None,
        "verificationStatus": "unlabeled",
        "legacyOrdinal": None,
    } for file, audio_sha256 in unlabeled)
    return rows


def padded(
    supplied: Sequence[LabeledRow],
    count: int,
    prefix: str,
) -> list[LabeledRow]:
    assert len(supplied) <= count, f"{prefix}: {len(supplied)} exceeds {count} rows"
    rows = list(supplied)
    for index in range(len(rows), count):
        file = f"{prefix}-{index + 1:03d}.wav"
        rows.append((
            file,
            hashlib.sha256(file.encode()).hexdigest(),
            f"{prefix} transcript {index + 1}",
        ))
    return rows


def labeled_row(entry: LabeledRow, ordinal: int, status: str) -> dict[str, Any]:
    file, audio_sha256, transcript = entry
    return {
        "schemaVersion": 2,
        "file": file,
        "audioSHA256": audio_sha256,
        "transcriptCandidate": transcript,
        "verificationStatus": status,
        "legacyOrdinal": ordinal,
    }


def run_self_test(root: Path) -> None:
    directory = root / "reader"
    directory.mkdir()
    path = directory / "evaluation-corpus-v2.jsonl"
    rows = corpus_rows(unlabeled=[("new-recording.wav", "a" * 64)])
    write_rows(path, rows)

    corpus = load_corpus(path)
    assert len(corpus.entries_by_file) == CONFIRMED_ROWS + INFERRED_ROWS + 1
    assert corpus.sha256 == hashlib.sha256(path.read_bytes()).hexdigest()
    assert status_counts(corpus.entries_by_file) == {
        "human_confirmed": CONFIRMED_ROWS,
        "inferred": INFERRED_ROWS,
        "unlabeled": 1,
    }
    confirmed = corpus.entries_by_file[rows[0]["file"]]
    assert confirmed.verification_status == "human_confirmed"
    assert confirmed.legacy_ordinal == 1

    expect_error(
        path,
        [dict(row, verificationStatus="human_confirmed") for row in rows],
        "human-confirmed legacyOrdinal must be within 1...35",
    )
    expect_error(
        path,
        [{key: value for key, value in row.items() if key != "legacyOrdinal"}
         for row in rows],
        "is missing fields: legacyOrdinal",
    )
    expect_error(
        path,
        [dict(row) for row in rows if row["legacyOrdinal"] != CONFIRMED_ROWS],
        "human-confirmed legacy ordinals must be exactly 1...35",
    )
    expect_error(
        path,
        [dict(row) for row in rows if row["legacyOrdinal"] != CONFIRMED_ROWS + 1],
        "inferred legacy ordinals must be exactly 36...114",
    )
    expect_error(
        path,
        [*rows, dict(rows[0])],
        f"duplicate corpus file {rows[0]['file']}",
    )
    expect_error(
        path,
        [*rows, dict(rows[0], file=rows[0]["file"].upper())],
        "filenames differ only by case",
    )
    expect_error(
        path,
        [dict(row, legacyOrdinal=1) if index == 1 else row
         for index, row in enumerate(rows)],
        "duplicate legacyOrdinal 1",
    )
    expect_error(
        path,
        [dict(rows[0], file="../escape.wav"), *rows[1:]],
        "unsafe recording filename",
    )
    expect_error(
        path,
        [dict(rows[0], schemaVersion=1), *rows[1:]],
        "has unsupported schemaVersion",
    )
    expect_error(
        path,
        [dict(rows[0], audioSHA256="not-a-digest"), *rows[1:]],
        "audioSHA256 must be 64 lowercase hex characters",
    )
    expect_error(
        path,
        [dict(rows[0], transcriptCandidate=None), *rows[1:]],
        "human_confirmed rows require a transcriptCandidate",
    )
    expect_error(
        path,
        [*rows[:-1], dict(rows[-1], legacyOrdinal=200)],
        "unlabeled rows require null transcriptCandidate and legacyOrdinal",
    )
    expect_error(
        path,
        [dict(rows[0], verificationStatus="assumed"), *rows[1:]],
        "unsupported verificationStatus assumed",
    )

    path.write_text("{not json}\n", encoding="utf-8")
    expect_load_error(path, "line 1 is not valid UTF-8 JSON")
    path.write_text("[]\n", encoding="utf-8")
    expect_load_error(path, "line 1 must be a JSON object")
    path.write_text("\n\n", encoding="utf-8")
    expect_load_error(path, "no evaluation corpus rows found")
    expect_load_error(directory / "missing.jsonl", "cannot read evaluation corpus")


def expect_error(path: Path, rows: list[dict[str, Any]], message: str) -> None:
    write_rows(path, rows)
    expect_load_error(path, message)


def expect_load_error(path: Path, message: str) -> None:
    try:
        load_corpus(path)
    except CorpusReadError as error:
        assert message in str(error), (message, str(error))
    else:
        raise AssertionError(f"expected CorpusReadError containing {message!r}")


def write_rows(path: Path, rows: list[dict[str, Any]]) -> None:
    path.write_text(
        "".join(json.dumps(row) + "\n" for row in rows),
        encoding="utf-8",
    )


def status_counts(entries: dict[str, Any]) -> dict[str, int]:
    return {
        status: sum(
            entry.verification_status == status for entry in entries.values()
        )
        for status in ("human_confirmed", "inferred", "unlabeled")
    }
