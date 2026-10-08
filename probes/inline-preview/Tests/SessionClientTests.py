#!/usr/bin/env python3
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import time
import unittest


client_path = Path(__file__).resolve().parents[1] / "Tools" / "session-client.py"
spec = importlib.util.spec_from_file_location("session_client", client_path)
client = importlib.util.module_from_spec(spec)
spec.loader.exec_module(client)


class SessionClientTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.state = {"pid": 42, "running": True, "byteCount": 0, "nonce": "EPOS-SESSION-TEST-A"}

    def save(self):
        (self.directory / "terminal.json").write_text(json.dumps(self.state))

    def test_empty_live_fixture(self):
        self.save()
        self.assertEqual(client.rendering_fixture_nonce(self.directory), self.state["nonce"])

    def test_contaminated_stopped_or_invalid_fixture(self):
        for key, value in [("byteCount", 2), ("byteCount", False), ("running", False),
                           ("pid", 0), ("nonce", "private text")]:
            with self.subTest(key=key, value=value):
                valid = self.state.copy()
                self.state[key] = value
                self.save()
                with self.assertRaises(ValueError):
                    client.rendering_fixture_nonce(self.directory)
                self.state = valid

    def test_missing_stale_or_changed_fixture(self):
        with self.assertRaises(ValueError):
            client.rendering_fixture_nonce(self.directory)
        self.save()
        with self.assertRaises(ValueError):
            client.rendering_fixture_nonce(self.directory, expected_nonce="EPOS-SESSION-TEST-B")
        stale = time.time() - 5
        os.utime(self.directory / "terminal.json", (stale, stale))
        with self.assertRaises(ValueError):
            client.rendering_fixture_nonce(self.directory)


if __name__ == "__main__":
    unittest.main()
