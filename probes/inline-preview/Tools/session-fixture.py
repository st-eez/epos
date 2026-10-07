#!/usr/bin/env python3
"""Disposable raw tty. It never executes received bytes or writes their contents."""
import json
import os
from pathlib import Path
import re
import select
import signal
import sys
import termios
import time
import tty


def main():
    if len(sys.argv) != 3 or not re.fullmatch(r"EPOS-SESSION-[A-Z0-9-]{1,64}", sys.argv[2]):
        raise SystemExit("usage: session-fixture.py PRIVATE_STATE_DIR EPOS-SESSION-NONCE")
    directory = Path(sys.argv[1]).resolve(strict=True)
    if directory.stat().st_mode & 0o077:
        raise SystemExit("state directory must be private")
    state_file = directory / "terminal.json"
    stop_file = directory / "stop-fixture"
    received = bytearray()
    final = b"EPOS final token"
    alpha = b"EPOS draft alpha"
    beta = b"EPOS draft beta"
    started = time.monotonic()
    deadline = started + 900
    first_input = None
    last_input = None
    last_phase = None
    alive = True

    def stop(*_):
        nonlocal alive
        alive = False

    def save(running):
        value = {
            "pid": os.getpid(), "nonce": sys.argv[2], "running": running,
            "byteCount": len(received), "exactFinal": received == final,
            "containsFinal": final in received, "containsAlpha": alpha in received,
            "containsBeta": beta in received, "xCount": received.count(b"x"),
            "backspaceCount": received.count(b"\x7f") + received.count(b"\x08"),
            "leftCount": received.count(b"\x1b[D"),
            "elapsedMilliseconds": round((time.monotonic() - started) * 1000, 3),
            "firstInputMilliseconds": first_input, "lastInputMilliseconds": last_input,
            "nativePhraseMatches": bytes(received).lower().strip(b" \r\n\t.,!?") == final.lower(),
        }
        temporary = state_file.with_suffix(".tmp")
        temporary.write_text(json.dumps(value, sort_keys=True) + "\n")
        os.chmod(temporary, 0o600)
        temporary.replace(state_file)

    def event(kind):
        value = {"kind": kind, "milliseconds": round((time.monotonic() - started) * 1000, 3),
                 "byteCount": len(received)}
        with (directory / "terminal-events.jsonl").open("a") as log:
            log.write(json.dumps(value, sort_keys=True) + "\n")

    for signum in [signal.SIGTERM, signal.SIGINT, signal.SIGHUP]:
        signal.signal(signum, stop)
    descriptor = sys.stdin.fileno()
    if not os.isatty(descriptor):
        raise SystemExit("fixture requires a disposable terminal")
    original = termios.tcgetattr(descriptor)
    try:
        tty.setraw(descriptor)
        # The title supplies only a synthetic nonce. No shell/transcript output
        # is preserved by the evidence files or screenshots of this prompt.
        os.write(sys.stdout.fileno(), ("\x1b]0;" + sys.argv[2] + "\x07\r\n"
                                     + sys.argv[2] + "\r\nSynthetic input: ").encode())
        save(True)
        while alive and time.monotonic() < deadline and not stop_file.exists():
            phase_file = directory / "native-phase"
            phase = phase_file.read_text().strip() if phase_file.exists() else None
            if phase in ["listening", "paused", "finished"] and phase != last_phase:
                last_phase = phase
                event(phase)
            readable, _, _ = select.select([descriptor], [], [], 0.2)
            if readable:
                chunk = os.read(descriptor, 4096)
                if not chunk:
                    break
                received.extend(chunk)
                elapsed = round((time.monotonic() - started) * 1000, 3)
                if first_input is None:
                    first_input = elapsed
                last_input = elapsed
                event("input")
                if len(received) > 4096:
                    break
                # Render only our exact known payload, never arbitrary input.
                if received == final:
                    os.write(sys.stdout.fileno(), final)
            save(True)
    finally:
        termios.tcsetattr(descriptor, termios.TCSANOW, original)
        save(False)
        event("stopped")
        os.write(sys.stdout.fileno(), b"\r\nSynthetic fixture ended.\r\n")


if __name__ == "__main__":
    main()
