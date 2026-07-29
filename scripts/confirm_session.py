"""Drive the listen-and-confirm loop over the frozen holdout selection."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import subprocess
from typing import Callable

from holdout_audio import file_sha256
from holdout_confirmations import Confirmation, append_confirmation
from holdout_selection import Selection

REPLAY = "r"
SKIP = "s"
QUIT = "q"
PROMPT = "  enter=accept  text=correct  r=replay  s=skip  q=quit > "
SHORT_TRANSCRIPT_WORDS = 2
SHORT_PROMPT = "  y=yes, that is the whole transcript  enter=no, let me retype > "


class SessionError(RuntimeError):
    """The confirmation loop hit a condition that must not be written through."""


@dataclass(frozen=True)
class SessionIO:
    read_line: Callable[[str], str]
    write_line: Callable[[str], None]
    play: Callable[[Path], None]


@dataclass(frozen=True)
class SessionSummary:
    confirmed: int
    accepted: int
    edited: int
    skipped: int
    remaining: int
    quit_early: bool


def play_with_afplay(path: Path) -> None:
    subprocess.run(["/usr/bin/afplay", str(path)], check=False)


def terminal_io() -> SessionIO:
    return SessionIO(read_line=input, write_line=print, play=play_with_afplay)


def run_session(
    selection: Selection,
    recordings_directory: Path,
    confirmations_path: Path,
    candidates: dict[str, str],
    candidate_source: str | None,
    io: SessionIO,
    *,
    confirmed_files: frozenset[str],
) -> SessionSummary:
    pending = [
        recording for recording in selection.recordings
        if recording.file not in confirmed_files
    ]
    total = len(selection.recordings)
    done = total - len(pending)
    accepted = edited = skipped = 0
    quit_early = False
    for offset, recording in enumerate(pending):
        io.write_line("")
        io.write_line(
            f"[{done + offset + 1}/{total}] {recording.file} "
            f"({recording.duration_seconds:.1f}s)"
        )
        candidate = candidates.get(recording.file)
        io.write_line(
            f"  candidate: {candidate}" if candidate
            else "  candidate: none - type what you hear"
        )
        action, transcript = ask(io, recordings_directory / recording.file, candidate)
        if action == "quit":
            quit_early = True
            break
        if action == "skip":
            skipped += 1
            continue
        was_edited = transcript != candidate
        write_confirmation(
            confirmations_path,
            recording.file,
            recordings_directory / recording.file,
            recording.audio_sha256,
            transcript,
            candidate,
            candidate_source,
            was_edited,
            selection.sha256,
        )
        accepted += 0 if was_edited else 1
        edited += 1 if was_edited else 0
    confirmed = accepted + edited
    return SessionSummary(
        confirmed=confirmed,
        accepted=accepted,
        edited=edited,
        skipped=skipped,
        remaining=len(pending) - confirmed,
        quit_early=quit_early,
    )


def ask(io: SessionIO, audio: Path, candidate: str | None) -> tuple[str, str]:
    """Play the recording and read one decision as (action, transcript)."""
    io.play(audio)
    while True:
        try:
            answer = io.read_line(PROMPT)
        except EOFError:
            return "quit", ""
        stripped = answer.strip()
        control = stripped.casefold()
        if control == QUIT:
            return "quit", ""
        if control == SKIP:
            return "skip", ""
        if control == REPLAY:
            io.play(audio)
            continue
        if not stripped:
            if candidate:
                return "confirm", candidate
            io.write_line("  no candidate to accept; type the transcript, s, or q")
            continue
        if len(stripped.split()) > SHORT_TRANSCRIPT_WORDS or confirm_short(io, stripped):
            return "confirm", stripped


def confirm_short(io: SessionIO, transcript: str) -> bool:
    """Re-ask on a very short transcript, which is where a mistyped key lands.

    Ground truth is written once and has no correction path inside the loop, so
    text short enough to be a fumbled control key needs an explicit yes.
    """
    io.write_line(f'  recording as ground truth: "{transcript}"')
    while True:
        try:
            answer = io.read_line(SHORT_PROMPT)
        except EOFError:
            return False
        decision = answer.strip().casefold()
        if decision in {"y", "yes"}:
            return True
        if decision in {"", "n", "no"}:
            return False
        io.write_line("  answer y or n")


def write_confirmation(
    confirmations_path: Path,
    file: str,
    audio: Path,
    expected_sha256: str,
    transcript: str,
    candidate: str | None,
    candidate_source: str | None,
    was_edited: bool,
    selection_sha256: str,
) -> None:
    digest = file_sha256(audio)
    if digest != expected_sha256:
        raise SessionError(
            f"{file}: audio changed since the holdout was frozen; nothing was written"
        )
    append_confirmation(
        confirmations_path,
        Confirmation(
            file=file,
            audio_sha256=digest,
            human_intended_transcript=transcript,
            candidate_shown=candidate,
            candidate_source=candidate_source if candidate else None,
            candidate_edited=was_edited,
            selection_sha256=selection_sha256,
        ),
    )
