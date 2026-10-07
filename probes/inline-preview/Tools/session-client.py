#!/usr/bin/env python3
"""Persistent, fixed-payload experiment client. Reads commands from its own tty."""
import argparse
import ctypes
import json
from pathlib import Path
import re
import socket
import sys
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("directory", type=Path)
    parser.add_argument("--pid", type=int)
    parser.add_argument("--window", type=int)
    args = parser.parse_args()
    if (args.pid is not None and args.pid <= 0) or (args.window is not None and args.window <= 0):
        parser.error("positive target pid/window required")
    libc = ctypes.CDLL(None)
    size = libc.confstr(65537, None, 0)  # _CS_DARWIN_USER_TEMP_DIR
    if size <= 0:
        raise SystemExit("per-user socket directory unavailable")
    buffer = ctypes.create_string_buffer(size)
    libc.confstr(65537, buffer, size)
    path = str(Path(buffer.value.decode()) / "epos-probe-im.sock")
    commands = {
        "preflight": "session-preflight",
        "snapshot": "session-snapshot com.mitchellh.ghostty",
        "begin": "",
        "alpha": "session-mark EPOS draft alpha",
        "beta": "session-mark EPOS draft beta",
        "cancel": "session-cancel",
        "final": "session-final EPOS final token",
        "inspect": "session-inspect",
        "end": "session-end",
    }
    deadline = time.monotonic() + 360
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as peer:
        peer.settimeout(5)
        peer.connect(path)
        pending = bytearray()
        print("ready: preflight snapshot target PID WINDOW begin alpha beta cancel final inspect end disconnect", flush=True)
        for line in sys.stdin:
            command = line.strip()
            if time.monotonic() >= deadline or command == "disconnect":
                break
            match = re.fullmatch(r"target ([1-9][0-9]{0,9}) ([1-9][0-9]{0,9})", command)
            if match:
                args.pid, args.window = map(int, match.groups())
                if args.pid > 2**31 - 1 or args.window > 2**32 - 1:
                    raise SystemExit("target identifiers out of range")
                print("target configured", flush=True)
                continue
            if command not in commands:
                print("refused unknown command", flush=True)
                continue
            if command == "begin":
                if args.pid is None or args.window is None:
                    print("refused begin requires target PID WINDOW", flush=True)
                    continue
                commands["begin"] = f"session-begin com.mitchellh.ghostty {args.pid} {args.window} controlled-empty-fixture"
            peer.sendall((commands[command] + "\n").encode())
            while b"\n" not in pending:
                chunk = peer.recv(4096)
                if not chunk or len(pending) + len(chunk) > 4096:
                    raise SystemExit("unavailable or oversized reply")
                pending.extend(chunk)
            raw, _, rest = pending.partition(b"\n")
            pending = bytearray(rest)
            reply = raw.decode("ascii")
            # Session replies carry ranges/state/counts only. Reject arbitrary
            # legacy status output rather than persisting a transcript.
            if not re.fullmatch(r"(?:ok|err) session [A-Za-z0-9=, ._-]+", reply):
                raise SystemExit("non-metadata reply refused")
            with (args.directory / "protocol.jsonl").open("a") as log:
                log.write(json.dumps({"command": command, "reply": reply, "monotonic": time.monotonic()}) + "\n")
            print(reply, flush=True)


if __name__ == "__main__":
    main()
