"""Regression tests for service suspension; never operate the real desktop."""
import importlib.util
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest

MODULE = Path(__file__).resolve().parents[1] / "resources/quiet-desktop/quiet_service_guard.py"
import sys
sys.path.insert(0, str(MODULE.parent))


class GuardTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(MODULE.exists(), "service-level guard is missing")
        spec = importlib.util.spec_from_file_location("quiet_service_guard", MODULE)
        self.guard = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.guard)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.worker = self.root / "quiet-guard-test-worker"
        source = self.root / "worker.c"
        source.write_text('#include <unistd.h>\nint main(void) { for (;;) { write(1,"x",1); usleep(20000); } }\n')
        subprocess.run(["/usr/bin/cc", str(source), "-o", str(self.worker)], check=True,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.child = subprocess.Popen([str(self.worker)], stdout=subprocess.PIPE)
        self.addCleanup(self.close_child)
        self.assertEqual(self.child.stdout.read(1), b"x")
        self.table = self.guard.DarwinProcesses(str(self.worker))
        self.state = self.root / "owned.json"
        self.events = []
        self.allowed = True
        self.controller = self.make_controller()

    def close_child(self):
        self.child.kill()
        self.child.wait(timeout=5)
        self.child.stdout.close()

    def make_controller(self):
        return self.guard.ServiceGuard(self.table, self.state, self.events.append,
                                       ready_check=lambda: self.allowed)

    def step(self, allowed, now=0):
        self.allowed = allowed
        self.controller.step({"allowed": allowed, "reason": "ready" if allowed else "display_asleep"}, now, enabled=True)

    def wait_status(self, stopped):
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            proc = self.table.inspect(self.child.pid)
            if proc and (proc["status"] == 4) == stopped:
                return proc
            time.sleep(0.01)
        self.fail("worker did not enter expected stopped/running state")

    def test_dark_stops_real_process_and_only_stable_ready_resumes(self):
        self.step(False)
        self.wait_status(True)
        os.set_blocking(self.child.stdout.fileno(), False)
        self.child.stdout.read()
        time.sleep(0.1)
        self.assertIsNone(self.child.stdout.read(), "suspended worker still ran")
        self.step(True, 1)
        self.wait_status(True)
        self.step(True, 3.1)
        self.wait_status(False)
        time.sleep(0.05)
        self.assertTrue(self.child.stdout.read(), "resumed worker made no progress")
        self.assertFalse(self.controller.owned)

    def test_restart_recovers_owned_suspension(self):
        self.step(False)
        self.wait_status(True)
        self.controller = self.make_controller()
        self.step(True, 10)
        self.step(True, 12.1)
        self.wait_status(False)

    def test_does_not_resume_a_process_stopped_by_someone_else(self):
        os.kill(self.child.pid, signal.SIGSTOP)
        self.wait_status(True)
        self.step(False)
        self.assertFalse(self.controller.owned)
        self.step(True, 1)
        self.step(True, 4)
        self.wait_status(True)

    def test_rechecks_desktop_before_resume(self):
        self.step(False)
        self.wait_status(True)
        self.controller.step({"allowed": True}, 1)
        self.controller.step({"allowed": True}, 4)
        self.wait_status(True)
        self.assertTrue(self.controller.owned)

    def test_unknown_state_stops_service(self):
        self.controller.step({"reason": "probe_failed"}, 0, enabled=True)
        self.wait_status(True)

    def test_reused_pid_record_cannot_resume_process(self):
        self.step(False)
        self.wait_status(True)
        for record in self.controller.owned.values():
            record["start_sec"] -= 1
        self.step(True, 1)
        self.step(True, 4)
        self.wait_status(True)

    def test_signalling_rejects_stale_process_identity(self):
        proc = self.table.inspect(self.child.pid)
        proc["start_usec"] += 1
        self.assertFalse(self.table.signal(proc, signal.SIGSTOP))
        self.wait_status(False)

    def test_only_exact_executable_is_selected(self):
        self.assertIsNone(self.table.inspect(os.getpid()))
        self.assertEqual([p["pid"] for p in self.table.snapshot()], [self.child.pid])

    def test_state_is_private_and_repeat_checks_do_not_rewrite_it(self):
        self.step(False)
        self.wait_status(True)
        stamp = self.state.stat().st_mtime_ns
        self.step(False, 1)
        self.assertEqual(self.state.stat().st_mtime_ns, stamp)
        self.assertEqual(self.state.stat().st_mode & 0o777, 0o600)

    def test_failed_journal_write_does_not_leave_unrecoverable_suspend_intent(self):
        blocked_parent = self.root / "not-a-directory"
        blocked_parent.write_text("occupied")
        self.controller.state_path = blocked_parent / "owned.json"
        with self.assertRaises(OSError):
            self.step(False)
        self.wait_status(False)
        self.assertFalse(self.controller.owned)
        self.controller.state_path = self.state
        self.step(False, 1)
        self.wait_status(True)
        recovered = self.make_controller()
        self.assertTrue(recovered.owned)

    def test_reused_pid_with_another_executable_does_not_block_rollback(self):
        stale = self.table.inspect(self.child.pid)
        stale["pid"] = os.getpid()
        self.controller.owned[str(os.getpid())] = stale
        self.step(True, 1)
        self.step(True, 4)
        self.assertFalse(self.controller.owned)

    def test_foreign_pid_in_old_journal_does_not_block_other_service_suspension(self):
        stale = self.table.inspect(self.child.pid)
        stale["pid"] = 1
        self.controller.owned["1"] = stale
        self.step(False)
        self.wait_status(True)
        self.assertNotIn("1", self.controller.owned)

    def test_disabled_guard_does_not_suspend_a_dark_desktop_service(self):
        self.controller.step({"allowed": False, "reason": "display_asleep"})
        self.wait_status(False)
        self.assertFalse(self.controller.owned)

    def test_opt_out_waits_for_safe_desktop_then_releases_ownership(self):
        self.step(False)
        self.wait_status(True)
        self.controller.step({"allowed": False}, 1, enabled=False)
        self.wait_status(True)
        self.allowed = True
        self.controller.step({"allowed": True}, 2, enabled=False)
        self.controller.step({"allowed": True}, 5, enabled=False)
        self.wait_status(False)
        self.assertFalse(self.controller.owned)


if __name__ == "__main__":
    unittest.main()
