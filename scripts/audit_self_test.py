"""Bounded deterministic checks for audit parsing and reporting."""

from __future__ import annotations

import json
from pathlib import Path

from audit_accuracy import accuracy_report
from audit_artifact import artifact_is_balanced, discover_best_signed_eval
from audit_common import OUTCOME_ALIASES
from audit_report import build_report, format_human
from corpus_reader_self_test import corpus_rows


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
        # An unacknowledged IME commit is ambiguous, not an accepted write.
        "2026-07-29T00:07:00.000Z\tinfo\tcoordinator\trecordingID=h recording start",
        ("2026-07-29T00:07:00.100Z\tinfo\treliability\trecordingID=h "
         "reliability outcome schema=1 outcome=ime-commit-unacknowledged "
         "writeAttempted=true writeAccepted=false imeCommit=true imeCommitAck=false "
         "latencyMs=120"),
        # A genuinely accepted keystroke write whose readback was unavailable
        # must keep bucketing as accepted, unchanged by the outcome above.
        "2026-07-29T00:08:00.000Z\tinfo\tcoordinator\trecordingID=i recording start",
        ("2026-07-29T00:08:00.100Z\tinfo\treliability\trecordingID=i "
         "reliability outcome schema=1 outcome=write-accepted-unverified "
         "writeAttempted=true writeAccepted=true latencyMs=130"),
    ]
    lines.extend([
        ("2026-07-29T00:00:00.080Z\tinfo\ttiming\trecordingID=a recording timing "
         "schema=1 stage=target-authorization attempt=1 durationMs=10 elapsedMs=80 outcome=completed"),
        ("2026-07-29T00:00:00.090Z\tinfo\ttiming\trecordingID=a recording timing "
         "schema=1 stage=target-authorization attempt=2 durationMs=30 elapsedMs=90 outcome=completed"),
        ("2026-07-29T00:00:00.100Z\tinfo\ttiming\trecordingID=a recording timing "
         "schema=1 stage=target-authorization attempt=3 durationMs=100 elapsedMs=100 outcome=refused"),
        ("2026-07-29T00:00:00.120Z\tinfo\ttiming\trecordingID=a recording timing "
         "schema=1 stage=first-display-publication attempt=1 durationMs=-1 elapsedMs=120 outcome=unavailable"),
        ("2026-07-29T00:00:00.121Z\tinfo\ttiming\trecordingID=a recording timing "
         "schema=1 stage=delivery-readback attempt=1 durationMs=nan elapsedMs=121 outcome=completed"),
        ("2026-07-29T00:00:00.122Z\tinfo\ttiming\trecordingID=a recording timing "
         "schema=1 stage=keystroke-write attempt=1 durationMs=3 elapsedMs=122 outcome=completed"),
        ("2026-07-29T00:00:00.123Z\tinfo\ttiming\trecordingID=a recording timing "
         "schema=1 stage=keystroke-write attempt=1 durationMs=4 elapsedMs=123 outcome=completed"),
        ("2026-07-29T00:00:00.124Z\tinfo\ttiming\trecordingID=a recording timing "
         "schema=1 stage=ime-commit attempt=1 durationMs=-1 elapsedMs=124 outcome=completed"),
        ("2026-07-29T00:01:00.125Z\tinfo\ttiming\trecordingID=b recording timing "
         "schema=2 stage=target-authorization attempt=1 durationMs=20 elapsedMs=125 outcome=completed"),
        ("2026-07-29T00:00:00.126Z\tinfo\tcoordinator\trecordingID=a transcript timing "
         'eventText="recording timing schema=1 stage=ime-commit attempt=1 '
         'durationMs=999 elapsedMs=999 outcome=completed"'),
    ])
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
    for row in rows[:3]:
        row["productionOutputTranscriptScore"] = row["transcriptScore"]
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
        "ime-commit-unacknowledged": "incomplete_ambiguous",
        "microphone-denied": "permission_failure",
        "accessibility-untrusted": "permission_failure",
    }
    assert {name: OUTCOME_ALIASES[name] for name in exact} == exact
    ledger_rows = corpus_rows(confirmed=[
        (f"sample-{index}.wav", f"{index + 1:064x}", "private") for index in range(5)
    ])
    corpus = root / "evaluation-corpus-v2.jsonl"
    write_corpus(corpus, ledger_rows)
    report = build_report(logs, complete, None, corpus)
    operational = report["operational"]
    stages = operational["stageTiming"]
    assert stages["recordingsWithTiming"] == 1
    assert stages["invalidEvents"] == 5
    authorization = stages["stages"]["target-authorization"]["outcomes"]
    assert authorization["completed"]["count"] == 2
    assert authorization["completed"]["timing"] == {"count": 2, "p50Ms": 20.0, "p95Ms": 29.0}
    assert authorization["refused"]["timing"]["p50Ms"] == 100
    unavailable = stages["stages"]["first-display-publication"]["outcomes"]["unavailable"]
    assert unavailable == {"count": 1, "durationlessCount": 1, "timing": None}
    assert stages["stages"]["ime-commit"]["observations"] == 0
    assert stages["stages"]["keystroke-write"]["observations"] == 0
    assert operational["recordingStarts"] == operational["classifiedRecordings"] == 9
    structured, legacy = operational["currentStructured"], operational["legacyInferred"]
    assert structured["recordingStarts"] == 5
    assert structured["buckets"]["verified_delivery"]["count"] == 1
    assert structured["buckets"]["accepted_unverified"]["count"] == 1
    assert structured["buckets"]["incomplete_ambiguous"]["count"] == 3
    assert structured["incompleteCount"] == 3
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
    assert accuracy["scoreSource"] == "productionOutputTranscriptScore"
    assert accuracy["referenceProvenance"] == "authoritative_join_mismatch"
    assert not accuracy["verifiedAccuracy"]
    assert sum(value["count"] for value in accuracy["buckets"].values()) == 3
    assert accuracy["mixedErrorRows"] == 1
    rendered = json.dumps(report) + format_human(report)
    assert "private" not in rendered
    assert "historical evidence only" in rendered

    confirmed_rows = []
    for index, row in enumerate(rows):
        confirmed_rows.append(dict(
            row,
            audioSHA256=f"{index % 5 + 1:064x}",
            humanIntendedTranscript="private",
            referenceVerificationStatus="human_confirmed",
        ))
    confirmed = root / "confirmed-signed.jsonl"
    confirmed.write_text(
        "\n".join(json.dumps(row) for row in confirmed_rows) + "\n",
        encoding="utf-8",
    )
    confirmed_accuracy = accuracy_report(
        confirmed, "speech-progressive-fast", corpus
    )
    assert confirmed_accuracy["referenceProvenance"] == "authoritative_join_mismatch"
    assert not confirmed_accuracy["verifiedAccuracy"]

    valid_rows = [row for row in confirmed_rows if row["arm"] == "other"]
    valid = root / "valid-signed.jsonl"
    valid.write_text(
        "\n".join(json.dumps(row) for row in valid_rows) + "\n",
        encoding="utf-8",
    )
    valid_accuracy = accuracy_report(valid, "other", corpus)
    assert valid_accuracy["referenceProvenance"] == "authoritative_human_confirmed"
    assert valid_accuracy["verifiedAccuracy"]

    self_declared = [dict(row) for row in valid_rows]
    self_declared[0]["audioSHA256"] = "0" * 64
    untrusted = root / "self-declared-signed.jsonl"
    untrusted.write_text(
        "\n".join(json.dumps(row) for row in self_declared) + "\n",
        encoding="utf-8",
    )
    untrusted_accuracy = accuracy_report(untrusted, "other", corpus)
    assert not untrusted_accuracy["verifiedAccuracy"]

    missing_accuracy = accuracy_report(valid, "other", root / "missing.jsonl")
    assert missing_accuracy["referenceProvenance"] == "authoritative_corpus_unavailable"
    assert "unavailable" in missing_accuracy["corpusReason"]

    hand_edited = root / "hand-edited-corpus.jsonl"
    for label, edited_rows in (
        ("every row marked human-confirmed",
         [dict(row, verificationStatus="human_confirmed") for row in ledger_rows]),
        ("legacyOrdinal stripped",
         [{key: value for key, value in row.items() if key != "legacyOrdinal"}
          for row in ledger_rows]),
    ):
        write_corpus(hand_edited, edited_rows)
        edited_accuracy = accuracy_report(valid, "other", hand_edited)
        assert edited_accuracy["referenceProvenance"] == (
            "authoritative_corpus_unavailable"
        ), label
        assert not edited_accuracy["verifiedAccuracy"], label
        assert "strict validation" in edited_accuracy["corpusReason"], label

    malformed_corpus = root / "malformed-corpus.jsonl"
    malformed_corpus.write_text(
        "".join(json.dumps(row) + "\n" for row in ledger_rows) + "{oops}\n",
        encoding="utf-8",
    )
    malformed_accuracy = accuracy_report(valid, "other", malformed_corpus)
    assert not malformed_accuracy["verifiedAccuracy"]
    assert "not valid UTF-8 JSON" in malformed_accuracy["corpusReason"]


def write_corpus(path: Path, rows: list[dict[str, object]]) -> None:
    path.write_text(
        "".join(json.dumps(row) + "\n" for row in rows),
        encoding="utf-8",
    )
