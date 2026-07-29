"""Drive the confirm loop with scripted input; no terminal, no audio playback."""

from __future__ import annotations

import json
from pathlib import Path

from confirm_candidates import discover_candidates
from confirm_plan import format_plan
from confirm_session import SessionError, SessionIO, run_session
from corpus_reader import Corpus
from holdout_confirmations import load_confirmations
from holdout_selection import Selection, compute_selection


SELECTION_SIZE = 4


class ScriptedIO:
    """Feed the loop a fixed answer list and record what it played and printed."""

    def __init__(self, answers: list[str]) -> None:
        self.answers = list(answers)
        self.printed: list[str] = []
        self.played: list[str] = []

    def io(self) -> SessionIO:
        return SessionIO(self.read_line, self.printed.append, self.play)

    def read_line(self, prompt: str) -> str:
        if not self.answers:
            raise EOFError
        return self.answers.pop(0)

    def play(self, path: Path) -> None:
        self.played.append(path.name)


def run_self_test(root: Path, recordings: Path, corpus: Corpus) -> None:
    selection = compute_selection(corpus, recordings, size=SELECTION_SIZE)
    files = [recording.file for recording in selection.recordings]
    candidates = {files[0]: "Recognizer guess one.", files[1]: "Recognizer guess two."}
    confirmations = root / "session-confirmations.jsonl"

    scripted = ScriptedIO(["r", "", "Typed correction.", "s", "q"])
    summary = run_session(
        selection,
        recordings,
        confirmations,
        candidates,
        "replay.jsonl",
        scripted.io(),
        confirmed_files=frozenset(),
    )
    assert scripted.played == [files[0], files[0], *files[1:]], (
        "r must replay the same recording without advancing"
    )
    assert (summary.confirmed, summary.accepted, summary.edited) == (2, 1, 1)
    assert (summary.skipped, summary.remaining, summary.quit_early) == (1, 2, True)

    rows = {row.file: row for row in load_confirmations(confirmations)}
    assert list(rows) == files[:2], "a skip must leave the recording unconfirmed"
    accepted = rows[files[0]]
    assert accepted.human_intended_transcript == candidates[files[0]]
    assert accepted.candidate_shown == candidates[files[0]]
    assert accepted.candidate_edited is False
    assert accepted.candidate_source == "replay.jsonl"
    assert accepted.selection_sha256 == selection.sha256
    corrected = rows[files[1]]
    assert corrected.human_intended_transcript == "Typed correction."
    assert corrected.candidate_shown == candidates[files[1]]
    assert corrected.candidate_edited is True, (
        "an edited candidate must never be recorded as accepted"
    )

    run_resume_self_test(selection, recordings, confirmations, files)
    run_guard_self_test(selection, recordings, root, files)
    run_candidate_self_test(root, recordings, selection)
    assert format_plan(selection, root / "s.json", root / "c.jsonl", ["drift"], True)


def run_resume_self_test(
    selection: Selection,
    recordings: Path,
    confirmations: Path,
    files: list[str],
) -> None:
    scripted = ScriptedIO(["Skipped one.", "Last one."])
    summary = run_session(
        selection,
        recordings,
        confirmations,
        {},
        None,
        scripted.io(),
        confirmed_files=frozenset(files[:2]),
    )
    assert scripted.played == files[2:], "resume must replay only unconfirmed rows"
    assert (summary.confirmed, summary.remaining) == (2, 0)
    rows = load_confirmations(confirmations)
    assert [row.file for row in rows] == files, "resume must preserve earlier rows"
    assert rows[-1].candidate_shown is None
    assert rows[-1].candidate_edited is True


def run_guard_self_test(
    selection: Selection,
    recordings: Path,
    root: Path,
    files: list[str],
) -> None:
    """A recording that changed after freezing must never be written through."""
    target = recordings / files[0]
    original = target.read_bytes()
    target.write_bytes(original + b"\0" * 4)
    fresh = root / "guard-confirmations.jsonl"
    try:
        run_session(
            selection,
            recordings,
            fresh,
            {},
            None,
            ScriptedIO(["Text for changed audio."]).io(),
            confirmed_files=frozenset(),
        )
    except SessionError as error:
        assert "audio changed since the holdout was frozen" in str(error)
    else:
        raise AssertionError("expected SessionError for changed audio")
    assert not fresh.exists(), "a rejected recording must not create a confirmations file"
    target.write_bytes(original)


def run_candidate_self_test(
    root: Path,
    recordings: Path,
    selection: Selection,
) -> None:
    """A missing or stale artifact degrades to no candidate rather than bad truth."""
    digests = {item.file: item.audio_sha256 for item in selection.recordings}
    empty = discover_candidates(root / "absent-repo", digests)
    assert empty.transcripts == {} and empty.reason
    artifact = root / "reviewable-context-fixture.jsonl"
    file = selection.recordings[0].file
    stale = selection.recordings[1].file
    artifact.write_text(
        "\n".join([
            row(file, digests[file], "Production text."),
            row(file, digests[file], "Other arm.", variant="production-setContext"),
            row(stale, "0" * 64, "Text for audio that changed."),
            row("2026-01-01_00-00-000.wav", "0" * 64, "Not in the holdout."),
        ]) + "\n",
        encoding="utf-8",
    )
    found = discover_candidates(root, digests, artifact)
    assert found.transcripts == {file: "Production text."}, (
        "only the production arm, and only where the audio digest still matches"
    )
    assert found.source == artifact.name and found.reason is None


def row(
    file: str,
    digest: str,
    text: str,
    variant: str = "production-alternatives",
) -> str:
    return json.dumps({
        "file": file,
        "variant": variant,
        "audioSHA256": digest,
        "variantCanonicalized": text,
    })
