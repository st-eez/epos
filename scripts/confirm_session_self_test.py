"""Drive the confirm loop with scripted input; no terminal, no audio playback."""

from __future__ import annotations

import json
from pathlib import Path

from confirm_candidates import discover_candidates
from confirm_cli import reopen
from confirm_plan import format_plan
from confirm_session import SessionError, SessionIO, ask, run_session
from corpus_reader import Corpus
from holdout_confirmations import ConfirmationError, load_confirmations
from holdout_selection import Selection, SelectionError, compute_selection


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

    scripted = ScriptedIO(["r", "", "Typed correction.", "y", "s", "q"])
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
    run_prompt_self_test(recordings, files)
    run_reconfirm_self_test(selection, recordings, confirmations, files)
    run_guard_self_test(selection, recordings, root, files)
    run_candidate_self_test(root, recordings, selection)
    assert format_plan(selection, root / "s.json", root / "c.jsonl", ["drift"], True)


def run_resume_self_test(
    selection: Selection,
    recordings: Path,
    confirmations: Path,
    files: list[str],
) -> None:
    scripted = ScriptedIO(["Skipped one for real.", "Last one for real."])
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


def run_prompt_self_test(recordings: Path, files: list[str]) -> None:
    """Control keys are case-insensitive, and short text needs an explicit yes."""
    audio = recordings / files[0]
    upper = ScriptedIO(["R", "Q"])
    assert ask(upper.io(), audio, "Candidate.") == ("quit", "")
    assert upper.played == [files[0], files[0]], (
        "an uppercase R replays instead of becoming ground truth"
    )
    assert ask(ScriptedIO([" S "]).io(), audio, None) == ("skip", "")
    assert ask(ScriptedIO(["Three words here."]).io(), audio, None) == (
        "confirm", "Three words here."
    ), "a normal transcript is committed on the first answer"

    gated = ScriptedIO(["Ok", "", "Ok", "maybe", "y"])
    assert ask(gated.io(), audio, "Candidate.") == ("confirm", "Ok")
    assert any('ground truth: "Ok"' in line for line in gated.printed), gated.printed
    assert ask(ScriptedIO(["Two words", "yes"]).io(), audio, None) == (
        "confirm", "Two words"
    )
    assert ask(ScriptedIO(["Ok"]).io(), audio, "Candidate.") == ("quit", ""), (
        "an unanswered short-text prompt discards the text instead of writing it"
    )


def run_reconfirm_self_test(
    selection: Selection,
    recordings: Path,
    confirmations: Path,
    files: list[str],
) -> None:
    """--reconfirm drops exactly one row, then confirms only that recording."""
    rows = load_confirmations(confirmations)
    assert [row.file for row in rows] == files
    kept = reopen(confirmations, rows, selection, files[1])
    assert [row.file for row in kept] == [files[0], files[2], files[3]]
    assert [row.file for row in load_confirmations(confirmations)] == [
        files[0], files[2], files[3]
    ], "dropping one confirmation must preserve every other row"
    expect(
        lambda: reopen(confirmations, kept, selection, files[1]),
        ConfirmationError,
        "is not confirmed",
    )
    expect(
        lambda: reopen(confirmations, kept, selection, "absent.wav"),
        SelectionError,
        "not in the frozen holdout",
    )
    scripted = ScriptedIO(["Redone transcript here."])
    summary = run_session(
        selection,
        recordings,
        confirmations,
        {},
        None,
        scripted.io(),
        confirmed_files=frozenset(
            item.file for item in selection.recordings if item.file != files[1]
        ),
    )
    assert scripted.played == [files[1]], "only the reopened recording replays"
    assert (summary.confirmed, summary.skipped, summary.remaining) == (1, 0, 0)
    redone = {row.file: row for row in load_confirmations(confirmations)}
    assert len(redone) == len(files)
    assert redone[files[1]].human_intended_transcript == "Redone transcript here."


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


def expect(action, kind: type[Exception], message: str) -> None:
    try:
        action()
    except kind as error:
        assert message in str(error), (message, str(error))
    else:
        raise AssertionError(f"expected {kind.__name__} containing {message!r}")


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
