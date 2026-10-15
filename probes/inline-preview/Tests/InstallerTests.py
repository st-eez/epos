"""Run the companion installer with disposable bundles and mocked native tools."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


PROBE = Path(__file__).resolve().parents[1]


class InstallerTests(unittest.TestCase):
    def run_install(self, mode, verify_only=False):
        with tempfile.TemporaryDirectory(prefix="epos-companion-install-check-") as directory:
            root = Path(directory)
            probe = root / "probe"
            binary = root / "bin"
            probe.mkdir()
            binary.mkdir()
            installed = root / "installed/EposProbe.app"
            (installed / "Contents/MacOS").mkdir(parents=True)
            (installed / "Contents/MacOS/EposProbe").write_text("original")
            shutil.copy2(PROBE / "Info.plist", probe / "Info.plist")
            shutil.copy2(PROBE / "Info.plist", installed / "Contents/Info.plist")
            if mode == "changed-metadata":
                (installed / "Contents/Info.plist").write_text("older metadata")
            legacy = probe / ".build/EposProbe.app"
            legacy.mkdir(parents=True)
            (legacy / "old-staging").touch()
            script = (PROBE / "install").read_text()
            script = script.replace("$HOME/Library/Input Methods", "$EPOS_INSTALL_CHECK_ROOT/installed")
            for tool in ["xcrun", "pkill", "ditto", "killall"]:
                script = script.replace(f"/usr/bin/{tool}", str(binary / tool))
            script = script.replace(
                "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
                str(binary / "lsregister"))
            # Keep refusal checks fast without changing their query/exit decisions.
            script = script.replace("poll_registration 10", "poll_registration 1")
            installer = probe / "install"
            installer.write_text(script)
            tools = {
                "xcrun": r'''#!/bin/bash
echo "xcrun $*" >> "$EPOS_INSTALL_CHECK_ROOT/calls"
if [[ "$1" == --sdk ]]; then echo /mock-sdk; exit 0; fi
if [[ "$1" == swiftc ]]; then
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == -o ]]; then printf 'new executable' > "$2"; exit 0; fi
    shift
  done
  exit 64
fi
command="$3"
case "$command" in
  current)
    if [[ "$EPOS_INSTALL_CHECK_MODE" == selection-unreadable ]]; then exit 1; fi
    if [[ -e "$EPOS_INSTALL_CHECK_ROOT/current" ]]; then cat "$EPOS_INSTALL_CHECK_ROOT/current"
    elif [[ "$EPOS_INSTALL_CHECK_MODE" == selected* ]]; then echo com.steez.inputmethod.EposProbe
    else echo com.apple.keylayout.ABC; fi
    exit 0 ;;
  layout) echo com.apple.keylayout.ABC; exit 0 ;;
  select)
    if [[ "$EPOS_INSTALL_CHECK_MODE" == selected-restore-fails ]]; then exit 1; fi
    echo "$4" > "$EPOS_INSTALL_CHECK_ROOT/current"; exit 0 ;;
  ready)
    if [[ "$EPOS_INSTALL_CHECK_MODE" == disabled || "$EPOS_INSTALL_CHECK_MODE" == interrupted-migration ]]; then exit 1; fi
    if [[ "$EPOS_INSTALL_CHECK_MODE" == unregistered && ! -e "$EPOS_INSTALL_CHECK_ROOT/registered" ]]; then exit 1; fi
    if [[ "$EPOS_INSTALL_CHECK_MODE" == cleanup-unregistered && -e "$EPOS_INSTALL_CHECK_ROOT/legacy-cleaned" && ! -e "$EPOS_INSTALL_CHECK_ROOT/registered" ]]; then exit 1; fi
    if [[ "$EPOS_INSTALL_CHECK_MODE" == readiness-lost && -e "$EPOS_INSTALL_CHECK_ROOT/replaced" ]]; then exit 1; fi
    exit 0 ;;
  registered)
    if [[ ( "$EPOS_INSTALL_CHECK_MODE" == unregistered || "$EPOS_INSTALL_CHECK_MODE" == interrupted-migration ) && ! -e "$EPOS_INSTALL_CHECK_ROOT/registered" ]]; then exit 1; fi
    if [[ "$EPOS_INSTALL_CHECK_MODE" == cleanup-unregistered && -e "$EPOS_INSTALL_CHECK_ROOT/legacy-cleaned" && ! -e "$EPOS_INSTALL_CHECK_ROOT/registered" ]]; then exit 1; fi
    exit 0 ;;
  find)
    if [[ "$EPOS_INSTALL_CHECK_MODE" == unregistered && ! -e "$EPOS_INSTALL_CHECK_ROOT/registered" ]]; then exit 1; fi
    exit 0 ;;
  register) touch "$EPOS_INSTALL_CHECK_ROOT/registered"; exit 0 ;;
  enable) exit 99 ;;
esac
exit 64
''',
                "codesign": r'''#!/bin/bash
echo "codesign $*" >> "$EPOS_INSTALL_CHECK_ROOT/calls"
if [[ "$EPOS_INSTALL_CHECK_MODE" == signing-failure && "$1" == --force ]]; then exit 42; fi
exit 0
''',
                "ditto": r'''#!/bin/bash
echo "ditto $*" >> "$EPOS_INSTALL_CHECK_ROOT/calls"
touch "$EPOS_INSTALL_CHECK_ROOT/replaced"
cp -R "$1" "$2"
''',
                "security": "#!/bin/bash\nexit 0\n",
                "pkill": r'''#!/bin/bash
echo "pkill $*" >> "$EPOS_INSTALL_CHECK_ROOT/calls"
if [[ "$EPOS_INSTALL_CHECK_MODE" == selected-user-changed ]]; then
  echo com.test.other-input-method > "$EPOS_INSTALL_CHECK_ROOT/current"
else
  echo com.apple.keylayout.ABC > "$EPOS_INSTALL_CHECK_ROOT/current"
fi
exit 0
''',
                "killall": '#!/bin/bash\necho "killall $*" >> "$EPOS_INSTALL_CHECK_ROOT/calls"\n',
                "lsregister": r'''#!/bin/bash
echo "lsregister $*" >> "$EPOS_INSTALL_CHECK_ROOT/calls"
if [[ "$1" == -u && "$2" == "$EPOS_INSTALL_CHECK_ROOT/probe/.build/EposProbe.app" ]]; then
  touch "$EPOS_INSTALL_CHECK_ROOT/legacy-cleaned"
fi
''',
            }
            for name, content in tools.items():
                path = binary / name
                path.write_text(content)
                path.chmod(0o755)
            env = dict(os.environ, PATH=str(binary) + ":" + os.environ["PATH"],
                       EPOS_INSTALL_CHECK_ROOT=str(root), EPOS_INSTALL_CHECK_MODE=mode)
            args = ["/bin/bash", str(installer)] + (["--verify-only"] if verify_only else [])
            result = subprocess.run(args, env=env, capture_output=True, text=True, timeout=15)
            calls = (root / "calls").read_text().splitlines()
            self.assertFalse(list((probe / ".build").glob("epos-companion-stage.*")))
            self.assertFalse(any(" enable " in call for call in calls))
            if not verify_only:
                self.assertFalse(legacy.exists())
                self.assertIn(f"lsregister -u {legacy}", calls)
                self.assertTrue(any("lsregister -u " in call and "epos-companion-stage." in call for call in calls))
                if result.returncode == 0:
                    cleanup = max(i for i, call in enumerate(calls) if "lsregister -u " in call)
                    readiness = max(i for i, call in enumerate(calls) if " ready " in call)
                    self.assertLess(cleanup, readiness, "readiness must be checked after staging cleanup")
            return result, calls, (installed / "Contents/MacOS/EposProbe").read_text(), legacy.exists()

    def test_same_metadata_upgrade_keeps_registration_and_skips_agent_restarts(self):
        result, calls, executable, _ = self.run_install("ready")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(executable, "new executable")
        self.assertFalse(any(" register " in call or call.startswith("lsregister -f") for call in calls))
        self.assertFalse(any(call.startswith("killall ") for call in calls))
        self.assertFalse(any(" select " in call for call in calls))

    def test_selected_companion_is_restored_after_replacement(self):
        result, calls, _, _ = self.run_install("selected")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("restored the selected Epos", result.stdout)
        selection = next(i for i, call in enumerate(calls) if " select " in call)
        readiness = max(i for i, call in enumerate(calls) if " ready " in call)
        self.assertGreater(selection, readiness)

    def test_new_source_chosen_during_install_is_preserved(self):
        result, calls, _, _ = self.run_install("selected-user-changed")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(" select " in call for call in calls))

    def test_selection_restoration_failure_is_reported(self):
        result, _, _, _ = self.run_install("selected-restore-fails")
        self.assertEqual(result.returncode, 2)
        self.assertIn("prior keyboard selection could not be restored", result.stderr)

    def test_unreadable_selection_stops_before_replacing_the_companion(self):
        result, calls, executable, _ = self.run_install("selection-unreadable")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(executable, "original")
        self.assertFalse(any(call.startswith("pkill ") for call in calls))

    def test_changed_metadata_registers_the_installed_path(self):
        result, calls, _, _ = self.run_install("changed-metadata")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(any(" register " in call and "/installed/EposProbe.app" in call for call in calls))
        self.assertIn("killall TextInputMenuAgent TextInputSwitcher", calls)

    def test_missing_registration_is_repaired_even_when_bundle_metadata_matches(self):
        result, calls, _, _ = self.run_install("unregistered")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(any(" register " in call for call in calls))

    def test_interrupted_migration_registers_keyboard_metadata_despite_same_id_palette(self):
        result, calls, _, _ = self.run_install("interrupted-migration")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertTrue(any(" register " in call for call in calls))
        self.assertIn("not enabled and selectable", result.stderr)

    def test_registration_lost_during_legacy_cleanup_is_repaired(self):
        result, calls, _, _ = self.run_install("cleanup-unregistered")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(any(" register " in call for call in calls))
        cleanup = next(i for i, call in enumerate(calls) if "lsregister -u " in call)
        first_readiness = next(i for i, call in enumerate(calls) if " ready " in call)
        self.assertLess(cleanup, first_readiness)

    def test_registered_disabled_source_is_reported_without_enabling(self):
        result, _, _, _ = self.run_install("disabled")
        self.assertEqual(result.returncode, 2)
        self.assertIn("not enabled and selectable", result.stderr)
        self.assertNotIn("registered live; keyboard source ready", result.stdout)

    def test_upgrade_cannot_claim_prior_readiness_was_preserved(self):
        result, calls, _, _ = self.run_install("readiness-lost")
        self.assertEqual(result.returncode, 2)
        self.assertIn("prior keyboard source readiness was not retained", result.stderr)
        self.assertFalse(any(call.startswith("killall ") for call in calls))

    def test_signing_failure_removes_and_unregisters_temporary_staging(self):
        result, _, executable, _ = self.run_install("signing-failure")
        self.assertEqual(result.returncode, 42)
        self.assertEqual(executable, "original")

    def test_verify_only_reads_native_state_without_bundle_or_registration_changes(self):
        result, calls, executable, legacy_exists = self.run_install("disabled", verify_only=True)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(executable, "original")
        self.assertTrue(legacy_exists)
        self.assertTrue(all(call.startswith("xcrun swift ") for call in calls))


if __name__ == "__main__":
    unittest.main()
