"""Policy tests: no native calls or changes to the real desktop."""
import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "resources/quiet-desktop"))


SPEC = importlib.util.find_spec("quiet_desktop_check")
if SPEC is not None:
    import quiet_desktop_check as check
else:
    check = None


class QuietDesktopTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(check, "The read-only desktop checker is not implemented")

    def evaluate(self, displays=None, **overrides):
        fields = {"on_console": True, "login_done": True, "locked": False}
        lightwake = overrides.pop("lightwake_active", False)
        fields.update(overrides)
        return check.evaluate([False] if displays is None else displays,
                              fields, lightwake)

    def test_normal_desktop_allows_with_exact_public_fields(self):
        result, code = self.evaluate()
        self.assertEqual(code, 0)
        self.assertEqual(result, {"allowed": True, "reason": "ready",
                                 "displays_asleep": [False], "locked": False,
                                 "on_console": True, "lightwake_active": False})

    def test_asleep_display_defers(self):
        result, code = self.evaluate([True])
        self.assertFalse(result["allowed"])
        self.assertEqual(code, 2)

    def test_one_awake_monitor_does_not_allow_waking_another(self):
        result, code = self.evaluate([False, True])
        self.assertFalse(result["allowed"])
        self.assertEqual(code, 2)

    def test_locked_session_defers(self):
        result, code = self.evaluate(locked=True)
        self.assertFalse(result["allowed"])
        self.assertEqual(code, 2)

    def test_inactive_or_unfinished_session_defers(self):
        for field in ("on_console", "login_done"):
            with self.subTest(field=field):
                result, code = self.evaluate(**{field: False})
                self.assertFalse(result["allowed"])
                self.assertEqual(code, 2)

    def test_unknown_session_and_lightwake_fail_closed(self):
        for field in ("on_console", "login_done", "locked", "lightwake_active"):
            with self.subTest(field=field):
                result, code = self.evaluate(**{field: None})
                self.assertFalse(result["allowed"])
                self.assertEqual(code, 1)

    def test_non_boolean_status_cannot_be_treated_as_truthy(self):
        for field in ("on_console", "login_done", "locked", "lightwake_active"):
            with self.subTest(field=field):
                result, code = self.evaluate(**{field: 1})
                self.assertFalse(result["allowed"])
                self.assertEqual(code, 1)

    def test_no_online_displays_fail_closed(self):
        result, code = self.evaluate([])
        self.assertFalse(result["allowed"])
        self.assertEqual(code, 1)

    def test_malformed_display_statuses_fail_closed_without_leaking_data(self):
        result, code = self.evaluate(["private-unexpected-value"])
        self.assertFalse(result["allowed"])
        self.assertEqual(code, 1)
        self.assertNotIn("private-unexpected-value", json.dumps(result))

    def test_lightwake_mode_defers_even_before_display_sleeps(self):
        result, code = self.evaluate(lightwake_active=True)
        self.assertFalse(result["allowed"])
        self.assertEqual(code, 2)

    def test_current_logged_in_session_with_absent_lock_key_is_unlocked(self):
        parsed = check.parse_session_plist(plistlib.dumps({
            "kCGSSessionOnConsoleKey": True, "kCGSessionLoginDoneKey": True,
            "kCGSessionUserNameKey": "private-fixture"}))
        self.assertEqual(parsed, {"on_console": True, "login_done": True,
                                  "locked": False})
        self.assertNotIn("private-fixture", json.dumps(parsed))

    def test_explicit_lock_state_is_preserved(self):
        for locked in (True, False):
            with self.subTest(locked=locked):
                parsed = check.parse_session_plist(plistlib.dumps({
                    "kCGSSessionOnConsoleKey": True, "kCGSessionLoginDoneKey": True,
                    "CGSSessionScreenIsLocked": locked}, fmt=plistlib.FMT_BINARY))
                self.assertIs(parsed["locked"], locked)

    def test_missing_lock_is_unknown_outside_valid_logged_in_console(self):
        for value in (False, None, 1, "true"):
            fields = {"kCGSessionLoginDoneKey": True}
            if value is not None:
                fields["kCGSSessionOnConsoleKey"] = value
            with self.subTest(value=value):
                parsed = check.parse_session_plist(plistlib.dumps(fields))
                self.assertIsNone(parsed["locked"])

    def test_malformed_lock_value_never_means_unlocked(self):
        for value in (0, 1, "false", "true", [], {}):
            with self.subTest(value=value):
                parsed = check.parse_session_plist(plistlib.dumps({
                    "kCGSSessionOnConsoleKey": True, "kCGSessionLoginDoneKey": True,
                    "CGSSessionScreenIsLocked": value}))
                self.assertIsNone(parsed["locked"])

    def test_invalid_cf_plist_data_is_rejected(self):
        for payload in (b"", b"not-a-plist", plistlib.dumps([]), plistlib.dumps("x")):
            with self.subTest(payload_length=len(payload)):
                with self.assertRaises(check.DetectionError):
                    check.parse_session_plist(payload)

    def test_missing_mode_file_means_inactive(self):
        with tempfile.TemporaryDirectory() as directory:
            self.assertIs(check.read_lightwake_active(Path(directory) / "missing"), False)

    def test_exact_off_token_is_inactive(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "mode"
            for token in ("off", "off\n", " off \n"):
                path.write_text(token)
                self.assertIs(check.read_lightwake_active(path), False)

    def test_other_nonempty_tokens_are_active_and_never_returned(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "mode"
            for token in ("private-mode-token", "OFF", "off-other"):
                path.write_text(token)
                self.assertIs(check.read_lightwake_active(path), True)

    def test_empty_or_unreadable_mode_is_unknown(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "mode"
            for data in (b"", b" \n", b"\xff"):
                path.write_bytes(data)
                with self.assertRaises(check.DetectionError):
                    check.read_lightwake_active(path)
            with self.assertRaises(check.DetectionError):
                check.read_lightwake_active(Path(directory))


if __name__ == "__main__":
    unittest.main()
