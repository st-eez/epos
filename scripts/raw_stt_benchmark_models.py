from __future__ import annotations

import argparse
import json
import time
from pathlib import Path

from raw_stt_benchmark_support import MODELS, append_jsonl, read_jsonl, wer_score


def run_model_cli(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("model")
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--work-dir", required=True)
    args = parser.parse_args(argv)

    rows = read_jsonl(Path(args.manifest))
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("")
    work_dir = Path(args.work_dir)
    work_dir.mkdir(parents=True, exist_ok=True)
    cfg = MODELS[args.model]

    load_started = time.monotonic()
    try:
        transcriber = load_transcriber(args.model, cfg["repo"])
    except Exception as exc:
        load_seconds = time.monotonic() - load_started
        error = f"model load failed: {type(exc).__name__}: {exc}"
        for item in rows:
            append_jsonl(failed_row(args.model, cfg, item, load_seconds, error), output)
        print(json.dumps({"model": args.model, "error": error}), flush=True)
        return 1

    load_seconds = time.monotonic() - load_started
    for item in rows:
        row = transcribe_row(args.model, cfg, transcriber, item, load_seconds, work_dir)
        append_jsonl(row, output)
        print(json.dumps({"file": row["file"], "elapsedSeconds": row["elapsedSeconds"], "error": row["error"]}), flush=True)
    return 0


def load_transcriber(model: str, repo: str):
    if model == "parakeet":
        import mlx.core as mx
        import parakeet_mlx

        return parakeet_mlx.from_pretrained(repo, dtype=mx.bfloat16)
    if model == "whisper":
        from mlx_whisper.transcribe import ModelHolder
        import mlx.core as mx

        ModelHolder.get_model(repo, mx.float16)
        return repo
    if model == "granite":
        from mlx_audio.stt.generate import load_model

        return load_model(repo)
    raise ValueError(model)


def transcribe_row(model: str, cfg: dict, transcriber, item: dict, load_seconds: float, work_dir: Path) -> dict:
    started = time.monotonic()
    transcript = ""
    error = None
    try:
        transcript = transcribe_text(model, transcriber, item["audioPath"], work_dir).strip()
    except Exception as exc:  # Keep batch evals moving and make failures visible in JSONL.
        error = f"{type(exc).__name__}: {exc}"
    elapsed = time.monotonic() - started
    score = wer_score(item["humanIntendedTranscript"], transcript) if not error else None
    duration = item["audioDurationSeconds"]
    return {
        "model": model,
        "engine": cfg["engine"],
        "modelRepo": cfg["repo"],
        "taskPrompt": cfg["taskPrompt"],
        "file": item["file"],
        "audioPath": item["audioPath"],
        "audioDurationSeconds": duration,
        "humanIntendedTranscript": item["humanIntendedTranscript"],
        "transcript": transcript,
        "transcriptScore": score,
        "loadSeconds": load_seconds,
        "elapsedSeconds": elapsed,
        "rtf": duration / elapsed if elapsed > 0 else None,
        "error": error,
    }


def failed_row(model: str, cfg: dict, item: dict, load_seconds: float, error: str) -> dict:
    return {
        "model": model,
        "engine": cfg["engine"],
        "modelRepo": cfg["repo"],
        "taskPrompt": cfg["taskPrompt"],
        "file": item["file"],
        "audioPath": item["audioPath"],
        "audioDurationSeconds": item["audioDurationSeconds"],
        "humanIntendedTranscript": item["humanIntendedTranscript"],
        "transcript": "",
        "transcriptScore": None,
        "loadSeconds": load_seconds,
        "elapsedSeconds": 0,
        "rtf": None,
        "error": error,
    }


def transcribe_text(model: str, transcriber, audio_path: str, work_dir: Path) -> str:
    if model == "parakeet":
        result = transcriber.transcribe(audio_path, chunk_duration=None)
        return getattr(result, "text", "") or " ".join(getattr(s, "text", "") for s in result.sentences)
    if model == "whisper":
        import mlx_whisper

        result = mlx_whisper.transcribe(
            audio_path,
            path_or_hf_repo=transcriber,
            verbose=None,
            language="en",
            task="transcribe",
            initial_prompt=None,
            condition_on_previous_text=False,
        )
        return result["text"]
    if model == "granite":
        from mlx_audio.stt.generate import generate_transcription

        output_path = work_dir / f"{Path(audio_path).stem}-granite"
        result = generate_transcription(
            model=transcriber,
            audio=audio_path,
            output_path=str(output_path),
            format="txt",
            verbose=False,
            prompt=MODELS["granite"]["taskPrompt"],
            language="en",
        )
        return getattr(result, "text", str(result))
    raise ValueError(model)
