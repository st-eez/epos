#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path

from raw_stt_benchmark_models import run_model_cli
from raw_stt_benchmark_support import (
    MODELS,
    fmt,
    mib,
    parse_peak_footprint,
    parse_peak_rss,
    read_jsonl,
    selected_manifest_rows,
    self_test,
    timestamp,
    write_jsonl,
)


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] == "_run_model":
        return run_model_cli(sys.argv[2:])

    parser = argparse.ArgumentParser(description="Run raw STT model benchmarks over Epos saved audio.")
    parser.add_argument("--recordings-dir", default=str(Path.home() / "Library/Caches/Epos/recordings"))
    parser.add_argument("--ground-truth")
    parser.add_argument("--output-dir")
    parser.add_argument("--models", default="parakeet,whisper,granite")
    parser.add_argument("--limit", type=int)
    parser.add_argument("--latest", action="store_true")
    parser.add_argument("--files", help="Comma- or newline-separated recording filenames or paths.")
    parser.add_argument("--files-from")
    parser.add_argument("--venv-python", default=".build/stt-bench/venv/bin/python")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        self_test()
        return 0
    return run_parent(args)


def run_parent(args: argparse.Namespace) -> int:
    root = Path.cwd()
    recordings_dir = Path(args.recordings_dir).expanduser()
    ground_truth = Path(args.ground_truth).expanduser() if args.ground_truth else recordings_dir / "ground-truth.jsonl"
    output_dir = Path(args.output_dir or root / ".build/evals" / f"raw-stt-benchmark-{timestamp()}")
    output_dir.mkdir(parents=True, exist_ok=True)

    selected = selected_manifest_rows(recordings_dir, ground_truth, args)
    manifest_path = output_dir / "selection.jsonl"
    write_jsonl(selected, manifest_path)

    summaries = []
    for model in [item.strip() for item in args.models.split(",") if item.strip()]:
        if model not in MODELS:
            raise SystemExit(f"Unknown model {model!r}; choose from {', '.join(MODELS)}")
        rows_path = output_dir / f"{model}.jsonl"
        log_path = output_dir / f"{model}.log"
        summary = run_one_model(model, manifest_path, rows_path, log_path, Path(args.venv_python), root)
        summaries.append(summary)

    summary_json = output_dir / "summary.json"
    summary_md = output_dir / "summary.md"
    summary_json.write_text(json.dumps({"selection": str(manifest_path), "models": summaries}, indent=2) + "\n")
    summary_md.write_text(summary_markdown(summaries, manifest_path) + "\n")
    print(summary_md.read_text())
    print(f"JSON summary: {summary_json}")
    return 1 if any(summary["exitCode"] != 0 for summary in summaries) else 0


def run_one_model(model: str, manifest: Path, rows_path: Path, log_path: Path, python: Path, root: Path) -> dict:
    script = Path(__file__).resolve()
    command = [
        "/usr/bin/time", "-l", str(root / python), str(script), "_run_model", model,
        "--manifest", str(manifest), "--output", str(rows_path),
        "--work-dir", str(rows_path.parent / f"{model}-work"),
    ]
    started = time.monotonic()
    proc = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    wall = time.monotonic() - started
    log_path.write_text(
        "COMMAND " + " ".join(command) + "\n\nSTDOUT\n" + proc.stdout + "\nSTDERR\n" + proc.stderr
    )
    rows = read_jsonl(rows_path) if rows_path.exists() else []
    summary = summarize_model(model, rows, wall, proc.returncode, proc.stderr, rows_path, log_path)
    print(f"{model}: exit={proc.returncode} rows={summary['rows']} failed={summary['failedRows']}")
    return summary


def summarize_model(model: str, rows: list[dict], wall: float, code: int, stderr: str, rows_path: Path, log_path: Path) -> dict:
    scored = [row["transcriptScore"] for row in rows if row.get("transcriptScore")]
    successes = [row for row in rows if not row.get("error")]
    failures = [row for row in rows if row.get("error")]
    selected_audio = sum(row["audioDurationSeconds"] for row in rows)
    audio = sum(row["audioDurationSeconds"] for row in successes)
    elapsed = sum(row["elapsedSeconds"] for row in successes)
    ref_words = sum(score["referenceWordCount"] for score in scored)
    errors = sum(score["wordErrors"] for score in scored)
    mean_wer = sum(score["wordErrorRate"] for score in scored) / len(scored) if scored else None
    rss = parse_peak_rss(stderr)
    footprint = parse_peak_footprint(stderr)
    return {
        "model": model,
        "engine": MODELS[model]["engine"],
        "modelRepo": MODELS[model]["repo"],
        "taskPrompt": MODELS[model]["taskPrompt"],
        "exitCode": code,
        "rows": len(rows),
        "successfulRows": len(successes),
        "scoredRows": len(scored),
        "failedRows": len(failures),
        "meanRowWER": mean_wer,
        "corpusWER": errors / ref_words if ref_words else None,
        "wordErrors": errors,
        "referenceWords": ref_words,
        "selectedAudioSeconds": selected_audio,
        "successfulAudioSeconds": audio,
        "transcriptionSeconds": elapsed,
        "processWallSeconds": wall,
        "warmRTFx": audio / elapsed if elapsed > 0 else None,
        "wallRTFx": audio / wall if audio > 0 and wall > 0 else None,
        "loadSeconds": rows[0].get("loadSeconds") if rows else None,
        "peakRSSBytes": rss,
        "peakRSSMiB": mib(rss),
        "peakMemoryFootprintBytes": footprint,
        "peakMemoryFootprintMiB": mib(footprint),
        "rowsPath": str(rows_path),
        "logPath": str(log_path),
    }


def summary_markdown(summaries: list[dict], manifest_path: Path) -> str:
    lines = [f"# Raw STT Benchmark", "", f"Selection: `{manifest_path}`", ""]
    lines.append("| Model | Exit | Rows | OK | Mean row WER | Corpus WER | Warm RTFx | Wall RTFx | RSS MiB | Footprint MiB | Load s | Failures |")
    lines.append("| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
    for item in summaries:
        lines.append(
            f"| {item['model']} | {item['exitCode']} | {item['rows']} | {item['successfulRows']} | "
            f"{fmt(item['meanRowWER'])} | {fmt(item['corpusWER'])} | "
            f"{fmt(item['warmRTFx'], 2)} | {fmt(item['wallRTFx'], 2)} | {fmt(item['peakRSSMiB'], 1)} | "
            f"{fmt(item['peakMemoryFootprintMiB'], 1)} | {fmt(item['loadSeconds'], 2)} | {item['failedRows']} |"
        )
    prompted = [item for item in summaries if item.get("taskPrompt")]
    if prompted:
        lines.append("")
        lines.append("Task prompts:")
        for item in prompted:
            lines.append(f"- {item['model']}: `{item['taskPrompt']}`")
    return "\n".join(lines)


if __name__ == "__main__":
    raise SystemExit(main())
