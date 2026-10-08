"""Fault injection for original-bundle restoration and single-use evidence."""
import hashlib
import importlib.machinery
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

source = Path(__file__).resolve().parents[1] / "session-experiment"
loader = importlib.machinery.SourceFileLoader("session_experiment", str(source))
spec = importlib.util.spec_from_loader(loader.name, loader)
runner = importlib.util.module_from_spec(spec)
loader.exec_module(runner)
real_pids_for = runner.pids_for
real_stop = runner.stop


class RequirementParserTests(unittest.TestCase):
    def test_reads_requirement_from_stdout_and_excludes_executable_diagnostic(self):
        self.assertEqual(runner.parse_requirement('designated => identifier "synthetic"\n',
                                                 "Executable=/different/bundle\n"), 'identifier "synthetic"')

    def test_reads_requirement_from_stderr(self):
        self.assertEqual(runner.parse_requirement("", 'Executable=/synthetic/bundle\ndesignated => identifier "synthetic"\n'),
                         'identifier "synthetic"')

    def test_rejects_missing_or_empty_requirement(self):
        for stdout, stderr in [("", "Executable=/synthetic/bundle\n"), ("designated =>   \n", "")]:
            with self.subTest(stdout=stdout):
                with self.assertRaisesRegex(RuntimeError, "exactly one"):
                    runner.parse_requirement(stdout, stderr)

    def test_rejects_multiple_requirements_even_when_identical(self):
        with self.assertRaisesRegex(RuntimeError, "exactly one"):
            runner.parse_requirement('designated => identifier "synthetic"\n',
                                     'designated => identifier "synthetic"\n')


class SessionRunnerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.directory = self.root / "prepared"
        self.directory.mkdir(mode=0o700)
        self.installed = self.root / "EposProbe.app"
        (self.installed / "Contents/MacOS").mkdir(parents=True)
        (self.installed / "Contents/MacOS/EposProbe").write_text("original bundle")
        staged = self.directory / "staged/EposProbe.app"
        (staged / "Contents/MacOS").mkdir(parents=True)
        (staged / "Contents/MacOS/EposProbe").write_text("temporary prototype")
        self.original_manifest = runner.manifest(self.installed)
        runner.save(self.directory / "original-manifest.json", self.original_manifest)
        runner.save(self.directory / "prepared.json", {"prototypeSHA256": hashlib.sha256(
            (staged / "Contents/MacOS/EposProbe").read_bytes()).hexdigest()})
        self.before = {"settingsHashes": {"synthetic": "hash"}, "mainBinarySHA256": "main",
                       "inputSources": {"enabled": True, "selected": True}, "eposRunning": True}
        self.after = dict(self.before, eposRunning=False)
        self.calls = []
        self.patches = [patch.object(runner, "INSTALLED", self.installed),
                        patch.object(runner, "BACKUP", self.root / "backup.app"),
                        patch.object(runner, "INCOMING", self.root / "incoming.app"),
                        patch.object(runner, "fingerprints", side_effect=lambda _: self.after if
                                     (self.directory / "before.json").exists() else self.before),
                        patch.object(runner, "pids_for", return_value=[123]),
                        patch.object(runner, "stop", side_effect=lambda bundle, **_: self.calls.append(("stop", bundle))),
                        patch.object(runner, "run", side_effect=self.fake_run),
                        patch.object(runner.time, "sleep", return_value=None),
                        patch.object(runner.signal, "signal", return_value=None)]
        for item in self.patches:
            item.start()
        (self.directory / "finish").touch()

    def tearDown(self):
        for item in reversed(self.patches):
            item.stop()
        self.temporary.cleanup()

    def fake_run(self, *arguments):
        self.calls.append(arguments)
        if arguments[0] == "/usr/bin/ditto":
            shutil.copytree(arguments[1], arguments[2])
        return b""

    def assert_original_restored(self):
        self.assertEqual(runner.manifest(self.installed), self.original_manifest)
        self.assertFalse((self.root / "backup.app").exists())
        report = json.loads((self.directory / "restoration.json").read_text())
        self.assertTrue(report["bundleRestored"])
        self.assertTrue(report["fingerprintsMatch"])
        self.assertTrue(report["companionRunning"])
        self.assertFalse(report["eposRunning"])
        self.assertTrue(report["eposWasRunning"])
        self.assertIn(("kosmos", "open", "-g", self.installed), self.calls)

    def test_interval_restores_exact_original_and_keeps_main_relaunch_separate(self):
        runner.execute(self.directory)
        self.assert_original_restored()
        self.assertEqual(self.calls.count(("kosmos", "open", "-g", self.installed)), 2)
        self.assertEqual((self.directory / "used/EposProbe.app/Contents/MacOS/EposProbe").read_text(), "temporary prototype")

    def test_failure_after_stopping_main_before_swap_records_and_reopens_original(self):
        def fail_stop(bundle, **_):
            if bundle == self.installed:
                raise RuntimeError("injected stop failure")
        with patch.object(runner, "stop", side_effect=fail_stop):
            with self.assertRaisesRegex(RuntimeError, "injected stop failure"):
                runner.execute(self.directory)
        self.assert_original_restored()

    def test_failure_between_renames_restores_original_and_retains_incoming(self):
        real_rename = Path.rename

        def fail_incoming(path, target):
            if path == self.root / "incoming.app" and target == self.installed:
                raise OSError("injected rename failure")
            return real_rename(path, target)

        with patch.object(Path, "rename", fail_incoming):
            with self.assertRaisesRegex(OSError, "injected rename failure"):
                runner.execute(self.directory)
        self.assert_original_restored()
        self.assertTrue((self.directory / "unused-incoming.app/Contents/MacOS/EposProbe").exists())

    def test_second_run_refuses_before_process_stop_or_fingerprint_replacement(self):
        runner.execute(self.directory)
        self.assert_original_restored()
        before = (self.directory / "before.json").read_bytes()
        calls = list(self.calls)
        with self.assertRaisesRegex(RuntimeError, "single use"):
            runner.execute(self.directory)
        self.assertEqual(self.calls, calls, "refused second run stopped or launched a process")
        self.assertEqual((self.directory / "before.json").read_bytes(), before)
        self.assertEqual(runner.manifest(self.installed), self.original_manifest)

    def test_process_exit_between_pgrep_and_ps_does_not_abort_restoration(self):
        def gone_process(arguments, **_):
            if arguments[0] == "/usr/bin/pgrep":
                return subprocess.CompletedProcess(arguments, 0, stdout=b"123\n", stderr=b"")
            return subprocess.CompletedProcess(arguments, 1, stdout=b"", stderr=b"")

        def stop_with_exit_race(bundle, **kwargs):
            with patch.object(runner, "pids_for", side_effect=real_pids_for), \
                    patch.object(runner.subprocess, "run", side_effect=gone_process):
                real_stop(bundle, **kwargs)

        with patch.object(runner, "stop", side_effect=stop_with_exit_race):
            runner.execute(self.directory)
        self.assert_original_restored()

    def test_exit_after_path_validation_does_not_abort_owned_stop(self):
        with patch.object(runner, "pids_for", side_effect=[[123], []]), \
                patch.object(runner.os, "kill", side_effect=ProcessLookupError):
            real_stop(self.installed)


if __name__ == "__main__":
    unittest.main()
