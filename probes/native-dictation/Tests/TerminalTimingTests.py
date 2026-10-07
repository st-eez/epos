import json
import os
from pathlib import Path
import pty
import subprocess
import tempfile
import time

fixture = Path(__file__).resolve().parents[2] / "inline-preview/Tools/session-fixture.py"


def wait_for(path, predicate):
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        if path.exists():
            state = json.loads(path.read_text())
            if predicate(state):
                return state
        time.sleep(0.02)
    raise AssertionError("synthetic terminal metadata did not settle")


with tempfile.TemporaryDirectory(prefix="epos-native-tty-check-") as temporary:
    directory = Path(temporary)
    master, slave = pty.openpty()
    process = subprocess.Popen(["/usr/bin/python3", "-I", str(fixture), str(directory), "EPOS-SESSION-NATIVE-CHECK"],
                               stdin=slave, stdout=slave, stderr=subprocess.PIPE)
    try:
        state_file = directory / "terminal.json"
        wait_for(state_file, lambda item: item["running"] and item["byteCount"] == 0)
        (directory / "native-phase").write_text("listening\n")
        time.sleep(0.3)
        os.write(master, b"Epos final token.")
        state = wait_for(state_file, lambda item: item["byteCount"] == 17)
        assert state["nativePhraseMatches"] and not state["exactFinal"]
        assert state["firstInputMilliseconds"] is not None and state["lastInputMilliseconds"] >= state["firstInputMilliseconds"]
        (directory / "native-phase").write_text("paused\n")
        time.sleep(0.3)
        (directory / "stop-fixture").touch()
        process.wait(timeout=3)
        assert process.returncode == 0
        state = json.loads(state_file.read_text())
        assert not state["running"]
        events = [json.loads(line) for line in (directory / "terminal-events.jsonl").read_text().splitlines()]
        assert [item["kind"] for item in events] == ["listening", "input", "paused", "stopped"]
        assert events[0]["byteCount"] == 0 and events[2]["byteCount"] == 17
        contents = (directory / "terminal-events.jsonl").read_text() + state_file.read_text()
        assert "Epos final token" not in contents
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=3)
        os.close(master)
        os.close(slave)

print("native terminal fixture: timing, phase markers, phrase equality and no payload retention passed")
