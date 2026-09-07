"""Consent and opt-out regression tests; never control the real service."""
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1] / "resources/quiet-desktop"
sys.path.insert(0, str(SOURCE))
import quiet_service_guard as guard


class ConsentTests(unittest.TestCase):
    def test_fresh_checkout_defaults_off(self):
        with tempfile.TemporaryDirectory() as temporary:
            self.assertFalse(guard.protection_enabled(Path(temporary) / "preferences.json"))

    def test_old_consent_cannot_enable_withdrawn_protection(self):
        with tempfile.TemporaryDirectory() as temporary:
            settings = Path(temporary) / "preferences.json"
            for content in ["{}", '{"enabled":true}', '{"enabled":1,"consentVersion":1}',
                            '{"enabled":"true","consentVersion":1}',
                            '{"enabled":true,"consentVersion":0}', "invalid",
                            '{"enabled":false,"consentVersion":1}']:
                settings.write_text(content)
                self.assertFalse(guard.protection_enabled(settings), content)
            settings.write_text('{"enabled":true,"consentVersion":1}')
            self.assertFalse(guard.protection_enabled(settings))

    def test_old_enabled_startup_is_inert_and_does_not_create_runtime_state(self):
        with tempfile.TemporaryDirectory(prefix="lightwake-other-user-") as temporary:
            destination = Path(temporary) / "Application Support/ScreenGuard/QuietDesktop"
            destination.mkdir(parents=True)
            for name in ["quiet_service_guard.py", "quiet_desktop_check.py"]:
                shutil.copy2(SOURCE / name, destination / name)
            (destination / "preferences.json").write_text('{"enabled":true,"consentVersion":1}')
            code = ('import sys; sys.path.insert(0, sys.argv[1]); import quiet_service_guard as g; '
                    'sys.argv=["quiet_service_guard.py","run"]; '
                    'g.DarwinProcesses=lambda *a: (_ for _ in ()).throw(AssertionError("disabled startup discovered processes")); '
                    'sys.exit(g.main())')
            result = subprocess.run([sys.executable, "-c", code, str(destination)],
                                    capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse((destination / "runtime").exists())


if __name__ == "__main__":
    unittest.main()
