#!/usr/bin/env python3
"""Persistent, fixed-payload experiment client. Reads commands from its own tty."""
import argparse
import ctypes
import json
import os
from pathlib import Path
import re
import socket
import sys
import time


def rendering_fixture_nonce(directory, expected_nonce=None):
    """Require the raw fixture's live heartbeat and an untouched input stream."""
    try:
        with (directory / "terminal.json").open() as source:
            age = time.time() - os.fstat(source.fileno()).st_mtime
            payload = source.read(16385)
        if not 0 <= age <= 2 or len(payload) > 16384:
            raise ValueError("stale or oversized fixture metadata")
        state = json.loads(payload)
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError("fixture metadata unavailable") from error
    if not isinstance(state, dict) or state.get("running") is not True:
        raise ValueError("fixture is not running")
    if type(state.get("pid")) is not int or state["pid"] <= 0:
        raise ValueError("fixture process unavailable")
    if type(state.get("byteCount")) is not int or state["byteCount"] != 0:
        raise ValueError("fixture already received input")
    nonce = state.get("nonce")
    if not isinstance(nonce, str) or not re.fullmatch(r"EPOS-SESSION-[A-Z0-9-]{1,64}", nonce):
        raise ValueError("fixture nonce unavailable")
    if expected_nonce is not None and nonce != expected_nonce:
        raise ValueError("fixture nonce changed")
    return nonce


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
        "background-begin": "",
        "alpha": "session-mark EPOS draft alpha",
        "beta": "session-mark EPOS draft beta",
        "cancel": "session-cancel",
        "final": "session-final EPOS final token",
        "inspect": "session-inspect",
        "end": "session-end",
    }
    deadline = time.monotonic() + 360
    rendering_nonce = None
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as peer:
        peer.settimeout(5)
        peer.connect(path)
        pending = bytearray()
        print("ready: preflight snapshot target PID WINDOW begin background-begin alpha beta cancel final inspect end disconnect", flush=True)
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
            if command in ["begin", "background-begin"]:
                if args.pid is None or args.window is None:
                    print("refused begin requires target PID WINDOW", flush=True)
                    continue
                suffix = ""
                verb = "session-begin"
                if command == "background-begin":
                    try:
                        nonce = rendering_fixture_nonce(args.directory)
                    except ValueError as error:
                        print(f"refused background fixture: {error}", flush=True)
                        continue
                    suffix = f" {nonce}"
                    verb = "session-begin-background"
                commands[command] = f"{verb} com.mitchellh.ghostty {args.pid} {args.window} controlled-empty-fixture{suffix}"
            if rendering_nonce is not None and command in ["alpha", "beta", "cancel", "final"]:
                try:
                    rendering_fixture_nonce(args.directory, expected_nonce=rendering_nonce)
                except ValueError as error:
                    print(f"refused background fixture: {error}", flush=True)
                    continue
            peer.sendall((commands[command] + "\n").encode())
            while b"\n" not in pending:
                chunk = peer.recv(4096)
                if not chunk or len(pending) + len(chunk) > 4096:
                    raise SystemExit("unavailable or oversized reply")
                pending.extend(chunk)
            raw, _, rest = pending.partition(b"\n")
            pending = bytearray(rest)
            reply = raw.decode("ascii")
            if command == "background-begin" and reply.startswith("ok session begun"):
                rendering_nonce = nonce
            if command == "end" and reply == "ok session ended":
                rendering_nonce = None
            # Session replies carry ranges/state/counts only. Reject arbitrary
            # legacy status output rather than persisting a transcript.
            if not re.fullmatch(r"(?:ok|err) session [A-Za-z0-9=, ._-]+", reply):
                raise SystemExit("non-metadata reply refused")
            with (args.directory / "protocol.jsonl").open("a") as log:
                log.write(json.dumps({"command": command, "reply": reply, "monotonic": time.monotonic()}) + "\n")
            print(reply, flush=True)


if __name__ == "__main__":
    main()
