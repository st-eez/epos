"""Bounded deterministic checks for audit parsing and reporting."""

from __future__ import annotations

import json
from pathlib import Path

from audit_accuracy import artifact_is_balanced, discover_best_signed_eval
from audit_common import OUTCOME_ALIASES
from audit_report import build_report, format_human


def run_self_test(root: Path) -> None:
    logs = root / "logs"
    logs.mkdir()
    lines = [
        "2026-07-29T00:00:00.000Z\tinfo\tcoordinator\trecordingID=a recording start",
        ("2026-07-29T00:00:00.040Z\tinfo\tcoordinator\trecordingID=a "
         "transcript timing seq=1 kind=partial elapsedMs=40 eventChars=4"),
        ("2026-07-29T00:00:00.100Z\tinfo\treliability\trecordingID=a "
         "reliability outcome writeAccepted=true outcome=delivery-verified "
         "schema=1 latencyMs=100 extra=ok"),
        "2026-07-29T00:01:00.000Z\tinfo\tcoordinator\trecordingID=b recording start",
        ("2026-07-29T00:01:00.200Z\tinfo\tcoordinator\trecordingID=b "
         "transcript timing seq=1 kind=partial elapsedMs=200 eventChars=4"),
        "2026-07-29T00:01:01.000Z\tinfo\ttranscriber\trecordingID=b session finished (hadInput=false)",
        "2026-07-29T00:01:01.100Z\tinfo\tcoordinator\trecordingID=b recording done (finalChars=0)",
        "2026-07-29T00:02:00.000Z\tinfo\tcoordinator\trecordingID=c recording start",
        "2026-07-29T00:02:00.200Z\tinfo\tcoordinator\trecordingID=c recording finalize",
        "2026-07-29T00:02:00.250Z\tinfo\tinject\trecordingID=c final insertion wrote chars=12",
        "2026-07-29T00:02:00.300Z\tinfo\tcoordinator\trecordingID=c recording done (finalChars=12)",
        "2026-07-29T00:03:00.000Z\tinfo\tcoordinator\trecordingID=d recording start",
        ("2026-07-29T00:03:00.100Z\tinfo\treliability\trecordingID=d "
         "reliability outcome schema=1 outcome=backend-refused latencyMs=50"),
        ("2026-07-29T00:03:00.101Z\tinfo\treliability\trecordingID=d "
         "reliability outcome schema=1 outcome=backend-refused latencyMs=51"),
        "2026-07-29T00:04:00.000Z\tinfo\tcoordinator\trecordingID=e recording start",
        ("2026-07-29T00:04:00.010Z\tinfo\tcoordinator\trecordingID=e "
         "recording done (finalChars=0 cancelledBeforeAudioStart=true)"),
        # Transcript text must not be mistaken for a new recording boundary.
        ("2026-07-29T00:04:00.011Z\tinfo\tcoordinator\trecordingID=e "
         "transcript timing seq=1 elapsedMs=10 eventText=\"recording start\""),
        "2026-07-29T00:05:00.000Z\tinfo\tcoordinator\trecordingID=f recording start",
        ("2026-07-29T00:05:00.001Z\tinfo\treliability\trecordingID=f "
         "reliability start schema=1"),
        "2026-07-29T00:06:00.000Z\tinfo\tcoordinator\trecordingID=g recording start",
        ("2026-07-29T00:06:00.001Z\tinfo\treliability\trecordingID=g "
         "reliability start schema=2"),
        ("2026-07-29T00:06:00.100Z\tinfo\treliability\trecordingID=g "
         "reliability outcome schema=2 outcome=delivery-verified latencyMs=99"),
    ]
    (logs / "audit.log").write_text("\n".join(lines) + "\n", encoding="utf-8")
    score = lambda errors, subs, ins, dels: {
        "wordErrors": errors, "substitutions": subs, "insertions": ins, "deletions": dels}
    rows = [
        {"arm": "speech-progressive-fast", "transcript": "private", "transcriptScore": score(0, 0, 0, 0)},
        {"arm": "speech-progressive-fast", "transcript": "private", "transcriptScore": score(3, 1, 1, 1)},
        {"arm": "speech-progressive-fast", "transcript": "", "transcriptScore": score(4, 0, 0, 4)},
        {"arm": "speech-progressive-fast", "transcript": "private"},
        {"arm": "speech-progressive-fast", "transcript": "private", "transcriptScore": score(0, 1, 0, 0)},
        {"arm": "other", "transcript": "private", "transcriptScore": score(0, 0, 0, 0)},
        {"arm": "other", "transcript": "private", "transcriptScore": score(0, 0, 0, 0)},
        {"arm": "other", "transcript": "private", "transcriptScore": score(0, 0, 0, 0)},
        {"arm": "other", "transcript": "private", "transcriptScore": score(0, 0, 0, 0)},
        {"arm": "other", "transcript": "private", "transcriptScore": score(0, 0, 0, 0)},
    ]
    for index, row in enumerate(rows):
        row["file"] = f"sample-{index % 5}.wav"
    complete = root / "complete-signed.jsonl"
    complete.write_text("\n".join(json.dumps(row) for row in rows) + "\n", encoding="utf-8")
    unequal_files = [dict(row) for row in rows]
    unequal_files[-1]["file"] = "different-sample.wav"
    assert not artifact_is_balanced(unequal_files)
    (root / "newer-partial-signed.jsonl").write_text(json.dumps(rows[0]) + "\n", encoding="utf-8")
    (root / "newer-unbalanced-signed.jsonl").write_text(
        "\n".join(json.dumps(row) for row in rows[:5]) + "\n",
        encoding="utf-8",
    )
    assert discover_best_signed_eval(root) == complete
    exact = {
        "setup-failed": "setup_failure", "cancelled-before-audio": "cancelled_before_audio",
        "no-input": "no_audio_input", "recognizer-failed": "recognizer_failure",
        "empty-transcript": "empty_transcript", "target-refused": "target_refusal",
        "backend-refused": "backend_refusal", "delivery-verified": "verified_delivery",
        "delivery-mismatch": "delivery_mismatch",
        "write-accepted-unverified": "accepted_unverified",
    }
    assert {name: OUTCOME_ALIASES[name] for name in exact} == exact
    report = build_report(logs, complete, None)
    operational = report["operational"]
    assert operational["recordingStarts"] == operational["classifiedRecordings"] == 7
    structured, legacy = operational["currentStructured"], operational["legacyInferred"]
    assert structured["recordingStarts"] == 3
    assert structured["buckets"]["verified_delivery"]["count"] == 1
    assert structured["buckets"]["incomplete_ambiguous"]["count"] == 2
    assert structured["timing"]["firstResult"]["p50Ms"] == 40
    unsupported = operational["unsupportedStructured"]
    assert unsupported["recordingStarts"] == 1
    assert unsupported["buckets"]["incomplete_ambiguous"]["count"] == 1
    assert legacy["recordingStarts"] == 3
    assert legacy["buckets"]["no_audio_input"]["count"] == 1
    assert legacy["buckets"]["accepted_unverified"]["count"] == 1
    assert legacy["buckets"]["cancelled_before_audio"]["count"] == 1
    assert legacy["timing"]["firstResult"]["p50Ms"] == 105
    accuracy = report["labeledCorpusAccuracy"]
    assert accuracy["rows"] == 3
    assert accuracy["selectedRows"] == 5
    assert accuracy["malformedRows"] == 2
    assert accuracy["selectedMalformedRows"] == 2
    assert accuracy["fileMalformedRows"] == 0
    assert accuracy["artifactBalanced"]
    assert sum(value["count"] for value in accuracy["buckets"].values()) == 3
    assert accuracy["mixedErrorRows"] == 1
    rendered = json.dumps(report) + format_human(report)
    assert "private" not in rendered
