"""Recording-scoped operational log parsing and classification."""

from __future__ import annotations

from collections import Counter
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
import re
from typing import Any, Iterable

from audit_common import OPERATIONAL_BUCKETS, OUTCOME_ALIASES, numeric, percentage, timing

ID_RE = re.compile(r"(?:^|\s)recordingID=([A-Za-z0-9._-]+)(?:\s|$)")
START_RE = re.compile(r"(?:^|\s)recordingID=[A-Za-z0-9._-]+ recording start$")
KV_RE = re.compile(r"(?<!\S)([A-Za-z][A-Za-z0-9]*)=([^\s]+)")
FINAL_RE = re.compile(r"\bfinalChars=(\d+)\b")
INPUT_RE = re.compile(r"\bhadInput=(true|false)\b")
STAMP_RE = re.compile(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?Z$")


@dataclass
class Event:
    timestamp: str
    message: str
    recording_id: str | None
    sequence: int


@dataclass
class Session:
    recording_id: str
    start_timestamp: str
    events: list[Event] = field(default_factory=list)


def log_files(path: Path) -> list[Path]:
    if path.is_file():
        return [path]
    return sorted(item for item in path.iterdir() if item.is_file()) if path.is_dir() else []


def events(paths: Iterable[Path]) -> list[Event]:
    result, seen = [], set()
    sequence = 0
    for path in paths:
        try:
            lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError:
            continue
        for line in lines:
            if line in seen:
                continue
            seen.add(line)
            columns = line.split("\t", 3)
            if len(columns) != 4 or not STAMP_RE.match(columns[0]):
                continue
            sequence += 1
            match = ID_RE.search(columns[3])
            result.append(Event(columns[0], columns[3], match.group(1) if match else None, sequence))
    return sorted(result, key=lambda item: (item.timestamp, item.sequence))


def sessions(parsed: Iterable[Event]) -> list[Session]:
    result, active = [], {}
    for event in parsed:
        if event.recording_id is None:
            continue
        if START_RE.search(event.message):
            session = Session(event.recording_id, event.timestamp, [event])
            result.append(session)
            active[event.recording_id] = session
        elif event.recording_id in active:
            active[event.recording_id].events.append(event)
    return result


def fields(message: str) -> dict[str, str]:
    return dict(KV_RE.findall(message))


def first_result(messages: list[str]) -> float | None:
    for message in messages:
        if "transcript timing " in message:
            value = numeric(fields(message).get("elapsedMs"))
            if value is not None and value >= 0:
                return value
    return None


def timestamp(value: str) -> datetime | None:
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def finalize_latency(parsed: list[Event]) -> float | None:
    start = next((timestamp(e.timestamp) for e in parsed if "recording finalize" in e.message), None)
    end = next((timestamp(e.timestamp) for e in reversed(parsed) if "recording done " in e.message), None)
    if start is None or end is None or end < start:
        return None
    return round((end - start).total_seconds() * 1000, 2)


def infer(messages: list[str]) -> tuple[str, bool]:
    combined = "\n".join(messages)
    rules = (
        ("recording setup failed:", "setup_failure"),
        ("cancelledBeforeAudioStart=true", "cancelled_before_audio"),
        ("transcription failed:", "recognizer_failure"),
        ("final insertion refused: Accessibility permission is not granted", "permission_failure"),
        ("final insertion refused: fn-press target changed", "target_refusal"),
        ("guarded final insertion refused", "target_refusal"),
        ("final insertion refused: keystroke backend unavailable", "backend_refusal"),
        ("insertion refused: Accessibility is not trusted", "backend_refusal"),
        ("insertion refused: could not create Unicode keyboard events", "backend_refusal"),
    )
    for marker, bucket in rules:
        if marker in combined:
            return bucket, False
    inputs = [m.group(1) for line in messages if (m := INPUT_RE.search(line))]
    if inputs[-1:] == ["false"]:
        return "no_audio_input", False
    chars = [int(m.group(1)) for line in messages if (m := FINAL_RE.search(line))]
    if chars[-1:] == [0] and inputs[-1:] == ["true"]:
        return "empty_transcript", False
    if "final insertion wrote chars=" in combined:
        return "accepted_unverified", False
    return "incomplete_ambiguous", True


def classify(session: Session) -> dict[str, Any]:
    messages = [event.message for event in session.events]
    starts = [fields(line) for line in messages if "reliability start " in line]
    outcomes = [fields(line) for line in messages if "reliability outcome " in line]
    has_schema_one_start = any(item.get("schema") == "1" for item in starts)
    schema_one_outcomes = [item for item in outcomes if item.get("schema") == "1"]
    first = first_result(messages)
    if len(schema_one_outcomes) == 1 and "outcome" in schema_one_outcomes[0]:
        raw = schema_one_outcomes[0]["outcome"].lower().replace("_", "-")
        bucket = OUTCOME_ALIASES.get(raw, "incomplete_ambiguous")
        latency = numeric(schema_one_outcomes[0].get("latencyMs"))
        latency = latency if latency is not None and latency >= 0 else None
        return {"bucket": bucket, "source": "structured",
                "incomplete": bucket == "incomplete_ambiguous",
                "latencyMs": latency, "firstResultLatencyMs": first}
    if has_schema_one_start or schema_one_outcomes:
        return {"bucket": "incomplete_ambiguous", "source": "structured",
                "incomplete": True, "latencyMs": None, "firstResultLatencyMs": first}
    if starts or outcomes:
        return {"bucket": "incomplete_ambiguous", "source": "unsupported",
                "incomplete": True, "latencyMs": None, "firstResultLatencyMs": first}
    bucket, incomplete = infer(messages)
    return {"bucket": bucket, "source": "inferred", "incomplete": incomplete,
            "latencyMs": finalize_latency(session.events), "firstResultLatencyMs": first}


def partition(items: list[dict[str, Any]], terminal_name: str) -> dict[str, Any]:
    counts, total = Counter(item["bucket"] for item in items), len(items)
    return {
        "recordingStarts": total,
        "incompleteCount": sum(item["incomplete"] for item in items),
        "buckets": {name: {"count": counts[name], "percent": percentage(counts[name], total)}
                    for name in OPERATIONAL_BUCKETS},
        "timing": {
            terminal_name: timing(item["latencyMs"] for item in items if item["latencyMs"] is not None),
            "firstResult": timing(item["firstResultLatencyMs"] for item in items
                                  if item["firstResultLatencyMs"] is not None),
        },
    }


def operational_report(path: Path) -> dict[str, Any]:
    files = log_files(path)
    classified = [classify(session) for session in sessions(events(files))]
    structured = [item for item in classified if item["source"] == "structured"]
    unsupported = [item for item in classified if item["source"] == "unsupported"]
    inferred = [item for item in classified if item["source"] == "inferred"]
    return {
        "logSource": str(path), "filesRead": len(files),
        "recordingStarts": len(classified), "classifiedRecordings": len(classified),
        "incompleteCount": sum(item["incomplete"] for item in classified),
        "currentStructured": partition(structured, "releaseToOutcome"),
        "unsupportedStructured": partition(unsupported, "releaseToOutcome"),
        "legacyInferred": partition(inferred, "finalizeToDone"),
    }
