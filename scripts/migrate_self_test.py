"""Self-test the corpus migration against temp fixtures, never real recordings."""

from __future__ import annotations

from pathlib import Path

from migrate_cli import LABEL_FILENAMES, MigrateError, apply_migration, plan_migration


def run_self_test(root: Path) -> None:
    check_happy_path(root / "happy")
    check_dotfile_left_behind(root / "dotfile")
    check_missing_source(root / "missing")
    check_empty_source(root / "empty")
    check_unexpected_entry(root / "unexpected")
    check_destination_with_recordings(root / "occupied")
    check_destination_with_labels(root / "labelled")


def check_happy_path(case: Path) -> None:
    source = make_source(case, recordings=2, labels=LABEL_FILENAMES)
    destination = case / "Application Support" / "Epos" / "recordings"
    backup = destination.parent / "corpus-backup"
    backup.mkdir(parents=True)
    (backup / "ground-truth.jsonl").write_text("backup\n", encoding="utf-8")

    moved, labels = apply_migration(plan_migration(source, destination))

    assert (moved, labels) == (2, 3), (moved, labels)
    names = sorted(path.name for path in destination.iterdir())
    assert names == sorted(["0.wav", "1.wav", *LABEL_FILENAMES]), names
    assert (destination / "0.wav").read_bytes() == b"audio 0"
    assert (backup / "ground-truth.jsonl").read_text(encoding="utf-8") == "backup\n"
    assert not source.exists()


def check_dotfile_left_behind(case: Path) -> None:
    source = make_source(case, recordings=1, labels=())
    (source / ".DS_Store").write_bytes(b"junk")
    destination = case / "destination"

    apply_migration(plan_migration(source, destination))

    assert (destination / "0.wav").exists()
    remaining = sorted(path.name for path in source.iterdir())
    assert remaining == [".DS_Store"], remaining


def check_missing_source(case: Path) -> None:
    source = case / "Caches" / "Epos" / "recordings"
    expect_error(
        lambda: plan_migration(source, case / "destination"),
        "no recordings directory",
    )


def check_empty_source(case: Path) -> None:
    source = make_source(case, recordings=0, labels=())
    expect_error(
        lambda: plan_migration(source, case / "destination"), "no .wav recordings"
    )


def check_unexpected_entry(case: Path) -> None:
    source = make_source(case, recordings=1, labels=())
    (source / "notes.txt").write_text("keep me\n", encoding="utf-8")
    destination = case / "destination"
    expect_error(
        lambda: plan_migration(source, destination), "does not own: notes.txt"
    )
    assert not destination.exists()
    assert (source / "0.wav").exists()


def check_destination_with_recordings(case: Path) -> None:
    source = make_source(case, recordings=1, labels=())
    destination = case / "destination"
    destination.mkdir(parents=True)
    (destination / "existing.wav").write_bytes(b"existing")
    expect_error(lambda: plan_migration(source, destination), "refusing to merge")
    assert (source / "0.wav").exists()


def check_destination_with_labels(case: Path) -> None:
    source = make_source(case, recordings=1, labels=("ground-truth.jsonl",))
    destination = case / "destination"
    destination.mkdir(parents=True)
    (destination / "ground-truth.jsonl").write_text("kept\n", encoding="utf-8")
    expect_error(lambda: plan_migration(source, destination), "refusing to overwrite")
    assert (destination / "ground-truth.jsonl").read_text(encoding="utf-8") == "kept\n"


def make_source(case: Path, recordings: int, labels: tuple[str, ...]) -> Path:
    source = case / "Caches" / "Epos" / "recordings"
    source.mkdir(parents=True)
    for index in range(recordings):
        (source / f"{index}.wav").write_bytes(f"audio {index}".encode())
    for name in labels:
        (source / name).write_text(f"{name}\n", encoding="utf-8")
    return source


def expect_error(action, message: str) -> None:
    try:
        action()
    except MigrateError as error:
        assert message in str(error), (message, str(error))
    else:
        raise AssertionError(f"expected MigrateError containing {message!r}")
