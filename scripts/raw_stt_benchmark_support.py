from __future__ import annotations

import json
import re
import subprocess
from datetime import datetime
from pathlib import Path


MODELS = {
    "parakeet": {
        "engine": "parakeet-mlx",
        "repo": "mlx-community/parakeet-tdt-0.6b-v2",
        "taskPrompt": None,
    },
    "whisper": {
        "engine": "mlx-whisper",
        "repo": "mlx-community/whisper-large-v3-turbo",
        "taskPrompt": None,
    },
    "granite": {
        "engine": "mlx-audio",
        "repo": "ibm-granite/granite-speech-4.1-2b",
        "taskPrompt": "can you transcribe the speech into a written format?",
    },
}

TOKEN_RE = re.compile(r"[$/]?[a-z0-9]+(?:[.'_-][a-z0-9]+)*|--+")
TIME_RSS_RE = re.compile(r"^\s*(\d+)\s+maximum resident set size", re.MULTILINE)
TIME_FOOTPRINT_RE = re.compile(r"^\s*(\d+)\s+peak memory footprint", re.MULTILINE)


def selected_manifest_rows(recordings_dir: Path, ground_truth: Path, args) -> list[dict]:
    manifest = read_jsonl(ground_truth)
    by_file = {row["file"]: row for row in manifest}
    selected_names = explicit_names(args)
    if selected_names:
        names = selected_names
    else:
        names = [row["file"] for row in manifest]
        if args.latest:
            names = sorted(names, reverse=True)
        if args.limit is not None:
            names = names[: max(0, args.limit)]
    rows = []
    for name in names:
        path = Path(name).expanduser()
        if not path.is_absolute():
            path = recordings_dir / name
        key = path.name
        if key not in by_file:
            raise SystemExit(f"{key} is not present in {ground_truth}")
        if not path.exists():
            raise SystemExit(f"Recording not found: {path}")
        rows.append({
            "file": key,
            "audioPath": str(path),
            "audioDurationSeconds": audio_duration_seconds(path),
            "humanIntendedTranscript": by_file[key]["humanIntendedTranscript"],
        })
    return rows


def explicit_names(args) -> list[str]:
    raw = args.files or ""
    if args.files_from:
        raw += "\n" + Path(args.files_from).read_text()
    return [part.strip() for part in re.split(r"[,\n]", raw) if part.strip()]


def audio_duration_seconds(path: Path) -> float:
    proc = subprocess.run(["/usr/bin/afinfo", str(path)], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    match = re.search(r"estimated duration:\s+([0-9.]+)\s+sec", proc.stdout)
    if proc.returncode != 0 or not match:
        raise SystemExit(f"Could not read audio duration for {path}: {proc.stderr}")
    return float(match.group(1))


def wer_score(reference: str, hypothesis: str) -> dict:
    ref = TOKEN_RE.findall(reference.lower())
    hyp = TOKEN_RE.findall(hypothesis.lower())
    previous = [(i, 0, i, 0) for i in range(len(hyp) + 1)]
    for ref_index, ref_token in enumerate(ref, 1):
        current = [(ref_index, 0, 0, ref_index)]
        for hyp_index, hyp_token in enumerate(hyp, 1):
            if ref_token == hyp[hyp_index - 1]:
                current.append(previous[hyp_index - 1])
            else:
                current.append(min([
                    add_substitution(previous[hyp_index - 1]),
                    add_deletion(previous[hyp_index]),
                    add_insertion(current[hyp_index - 1]),
                ], key=lambda cell: (cell[0], cell[1], cell[3], cell[2])))
        previous = current
    errors, substitutions, insertions, deletions = previous[len(hyp)]
    denominator = max(len(ref), 1)
    return {
        "referenceWordCount": len(ref),
        "comparedWordCount": len(hyp),
        "wordErrors": errors,
        "substitutions": substitutions,
        "insertions": insertions,
        "deletions": deletions,
        "wordErrorRate": errors / denominator,
        "wordAccuracy": max(0, 1 - errors / denominator),
    }


def add_substitution(cell: tuple[int, int, int, int]) -> tuple[int, int, int, int]:
    errors, substitutions, insertions, deletions = cell
    return errors + 1, substitutions + 1, insertions, deletions


def add_insertion(cell: tuple[int, int, int, int]) -> tuple[int, int, int, int]:
    errors, substitutions, insertions, deletions = cell
    return errors + 1, substitutions, insertions + 1, deletions


def add_deletion(cell: tuple[int, int, int, int]) -> tuple[int, int, int, int]:
    errors, substitutions, insertions, deletions = cell
    return errors + 1, substitutions, insertions, deletions + 1


def parse_peak_rss(stderr: str) -> int | None:
    match = TIME_RSS_RE.search(stderr)
    return int(match.group(1)) if match else None


def parse_peak_footprint(stderr: str) -> int | None:
    match = TIME_FOOTPRINT_RE.search(stderr)
    return int(match.group(1)) if match else None


def mib(value: int | None) -> float | None:
    return value / 1024 / 1024 if value else None


def fmt(value, digits: int = 6) -> str:
    return "n/a" if value is None else f"{value:.{digits}f}"


def read_jsonl(path: Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def write_jsonl(rows: list[dict], path: Path) -> None:
    path.write_text("".join(json.dumps(row, sort_keys=True) + "\n" for row in rows))


def append_jsonl(row: dict, path: Path) -> None:
    with path.open("a") as handle:
        handle.write(json.dumps(row, sort_keys=True) + "\n")


def timestamp() -> str:
    return datetime.now().strftime("%Y%m%d-%H%M%S")


def self_test() -> None:
    assert TOKEN_RE.findall("Use /goal with $HOME and cloud.md -- now".lower()) == [
        "use", "/goal", "with", "$home", "and", "cloud.md", "--", "now"
    ]
    score = wer_score("hello world", "hello there world")
    assert score["insertions"] == 1 and score["wordErrors"] == 1
    print("raw-stt-benchmark self-test passed")
