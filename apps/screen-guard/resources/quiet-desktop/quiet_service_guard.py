#!/usr/bin/python3
"""Pause the signed Computer Use service while the physical desktop is deferred.

This is a local mitigation, not a patch to Codex. A stopped process cannot issue
new wake assertions. Existing assertions, a new process before discovery, and a
display transition between snapshots are not eliminated by polling. No screen
capture, input, authentication, launch of the service, or power assertion is used.
"""
import argparse
import ctypes
import fcntl
import json
import logging
from logging.handlers import RotatingFileHandler
import os
from pathlib import Path
import signal
import sys
import tempfile
import time

from quiet_desktop_check import NativeDesktopReader, evaluate, read_lightwake_active

ROOT = Path(__file__).resolve().parent
RUNTIME = ROOT / "runtime"
PREFERENCES = ROOT / "preferences.json"
TARGET = str(Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))) /
             "computer-use/Codex Computer Use.app/Contents/MacOS/SkyComputerUseService")
INTERVAL = 0.25
READY_SECONDS = 2.0


def protection_enabled(path=PREFERENCES):
    """No implicit consent: missing, old or malformed preferences mean off."""
    try:
        if path.stat().st_size > 4096:
            return False
        value = json.loads(path.read_text())
        return (isinstance(value, dict) and value.get("enabled") is True
                and type(value.get("consentVersion")) is int and value["consentVersion"] == 1)
    except (OSError, ValueError, TypeError):
        return False


class BsdInfo(ctypes.Structure):
    # macOS SDK sys/proc_info.h: struct proc_bsdinfo, PROC_PIDTBSDINFO = 3.
    _fields_ = [(name, ctypes.c_uint32) for name in (
        "flags", "status", "xstatus", "pid", "ppid", "uid", "gid", "ruid",
        "rgid", "svuid", "svgid", "reserved")] + [
        ("comm", ctypes.c_char * 16), ("name", ctypes.c_char * 32)] + [
        (name, ctypes.c_uint32) for name in (
            "nfiles", "pgid", "pjobc", "tdev", "tpgid")] + [
        ("nice", ctypes.c_int32), ("start_sec", ctypes.c_uint64),
        ("start_usec", ctypes.c_uint64)]


def identity(proc):
    return tuple(proc[key] for key in ("pid", "start_sec", "start_usec", "path"))


class DarwinProcesses:
    def __init__(self, target):
        self.target = os.path.realpath(target)
        self.lib = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        self.lib.proc_listpids.argtypes = [ctypes.c_uint32, ctypes.c_uint32,
                                          ctypes.c_void_p, ctypes.c_int]
        self.lib.proc_listpids.restype = ctypes.c_int
        self.lib.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        self.lib.proc_pidpath.restype = ctypes.c_int
        self.lib.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64,
                                         ctypes.c_void_p, ctypes.c_int]
        self.lib.proc_pidinfo.restype = ctypes.c_int

    def inspect(self, pid, only_target=True):
        path = ctypes.create_string_buffer(4096)
        if self.lib.proc_pidpath(pid, path, len(path)) <= 0:
            return None
        executable = os.fsdecode(path.value)
        if only_target and executable != self.target:
            return None
        info = BsdInfo()
        if self.lib.proc_pidinfo(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info)) != ctypes.sizeof(info):
            return None
        if info.pid != pid or info.status == 5 or (only_target and info.uid != os.getuid()):
            return None
        return {"pid": pid, "start_sec": info.start_sec, "start_usec": info.start_usec,
                "path": executable, "status": info.status, "uid": info.uid}

    def snapshot(self):
        capacity = 4096
        while capacity <= 65536:
            pids = (ctypes.c_int * capacity)()
            size = self.lib.proc_listpids(1, 0, pids, ctypes.sizeof(pids))
            if size <= 0:
                raise RuntimeError("process_list_unavailable")
            if size < ctypes.sizeof(pids):
                return [proc for pid in pids[:size // ctypes.sizeof(ctypes.c_int)]
                        if pid > 0 for proc in [self.inspect(pid)] if proc]
            capacity *= 2
        raise RuntimeError("process_list_truncated")

    def signal(self, expected, sig):
        current = self.inspect(expected["pid"])
        if current is None or identity(current) != identity(expected):
            return False
        # Revalidate executable, owner and creation time immediately before kill.
        try:
            os.kill(current["pid"], sig)
            return True
        except ProcessLookupError:
            return False


def atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temporary = tempfile.mkstemp(prefix=path.name + ".", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(value, stream, separators=(",", ":"))
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


class DesktopProbe:
    def __init__(self):
        self.native = None

    def __call__(self):
        try:
            if self.native is None:
                self.native = NativeDesktopReader()
            status, _ = evaluate(self.native.displays_asleep(), self.native.session(),
                                 read_lightwake_active(Path.home() / "Library/Application Support/ScreenGuard/mode"))
            return status
        except Exception:
            return {"allowed": False, "reason": "state_unavailable"}


class ServiceGuard:
    def __init__(self, processes, state_path, emit, ready_check):
        self.processes, self.state_path = processes, state_path
        self.emit, self.ready_check = emit, ready_check
        self.ready_since = None
        try:
            data = json.loads(state_path.read_text())
            self.owned = {str(p["pid"]): p for p in data["owned"]}
            for p in self.owned.values():
                if (p["path"] != processes.target or type(p["pid"]) is not int
                        or p["pid"] <= 0 or any(type(p[k]) is not int
                                               for k in ("start_sec", "start_usec"))):
                    raise ValueError("invalid suspension ownership")
        except FileNotFoundError:
            self.owned = {}

    def save(self):
        atomic_json(self.state_path, {"version": 1, "owned": list(self.owned.values())})

    def step(self, status, now=None, enabled=False):
        now = time.monotonic() if now is None else now
        ready = status.get("allowed") is True
        if not ready:
            self.ready_since = None
        elif self.ready_since is None:
            self.ready_since = now
        snapshot = self.processes.snapshot()
        # Dead/replaced PIDs are never signalled using a stale ownership record.
        for key, recorded in list(self.owned.items()):
            current = self.processes.inspect(recorded["pid"], only_target=False)
            if current and (identity(current) != identity(recorded) or current["uid"] != os.getuid()):
                del self.owned[key]
                self.save()
            elif current is None:
                try:
                    os.kill(recorded["pid"], 0)
                except (ProcessLookupError, PermissionError):
                    del self.owned[key]
                    self.save()
        for proc in snapshot:
            key = str(proc["pid"])
            if not ready:
                if enabled is not True:
                    continue
                if proc["status"] == 4:
                    continue  # Never claim a suspension performed by somebody else.
                if key not in self.owned:
                    self.owned[key] = proc.copy()
                    try:
                        self.save()  # Persist intent BEFORE stopping, to survive a crash.
                    except Exception:
                        del self.owned[key]
                        raise
                if self.processes.signal(proc, signal.SIGSTOP):
                    self.emit({"event": "suspended", "pid": proc["pid"],
                               "reason": status.get("reason", "state_unknown")})
            elif (key in self.owned and identity(proc) == identity(self.owned[key])
                  and now - self.ready_since >= READY_SECONDS):
                if not self.ready_check():
                    self.ready_since = None
                    break
                if self.processes.signal(proc, signal.SIGCONT):
                    del self.owned[key]
                    self.save()
                    self.emit({"event": "resumed", "pid": proc["pid"], "reason": "desktop_ready"})
        return snapshot


def make_logger():
    logger = logging.getLogger("quiet-service-guard")
    logger.setLevel(logging.INFO)
    handler = RotatingFileHandler(RUNTIME / "events.jsonl", maxBytes=1048576, backupCount=2)
    handler.setFormatter(logging.Formatter("%(message)s"))
    logger.addHandler(handler)
    def emit(event):
        logger.info(json.dumps({"time": time.strftime("%Y-%m-%dT%H:%M:%S%z"), **event}, separators=(",", ":")))
    return emit


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("run", "status", "release"), nargs="?", default="run")
    command = parser.parse_args().command
    # A fresh installation does nothing before the user's explicit consent.
    # An old ownership journal still needs safe cleanup after opting out.
    if command == "run" and not protection_enabled() and not (RUNTIME / "owned.json").exists():
        print("protection_disabled")
        return 0
    os.umask(0o077)
    RUNTIME.mkdir(parents=True, exist_ok=True, mode=0o700)
    table, probe = DarwinProcesses(TARGET), DesktopProbe()
    if command == "status":
        state = RUNTIME / "status.json"
        print(json.dumps({"enabled": protection_enabled(), "desktop": probe(), "services": table.snapshot(),
                          "last_observation": json.loads(state.read_text()) if state.exists() else None}))
        return 0
    lock = (RUNTIME / "daemon.lock").open("a+")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print("guard_already_running", file=sys.stderr)
        return 1
    emit = make_logger()
    guard = ServiceGuard(table, RUNTIME / "owned.json", emit,
                         ready_check=lambda: probe().get("allowed") is True)
    if command == "release":
        for _ in range(10):
            status = probe()
            if status.get("allowed") is not True:
                print("DESKTOP_DEFERRED: ownership retained; resume only after normal manual wake/unlock.")
                return 2
            guard.step(status)
            time.sleep(INTERVAL)
        print(json.dumps({"remaining_owned": len(guard.owned)}))
        return 0 if not guard.owned else 1
    running = True
    def stop(signum, frame):
        nonlocal running
        running = False
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    emit({"event": "started", "pid": os.getpid(), "interval_seconds": INTERVAL})
    last_state, last_report, last_error = None, 0.0, None
    try:
        while running:
            enabled = protection_enabled()
            if not enabled and not guard.owned:
                emit({"event": "disabled", "owned_pids": []})
                break
            status = probe()
            now = time.monotonic()
            try:
                processes = guard.step(status, now, enabled=enabled)
                last_error = None
                summary = (enabled, status.get("reason"), tuple(p["pid"] for p in processes), tuple(guard.owned))
                if summary != last_state or now - last_report >= 10:
                    atomic_json(RUNTIME / "status.json", {"time": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
                        "daemon_pid": os.getpid(), "enabled": enabled, "desktop": status,
                        "service_pids": [p["pid"] for p in processes], "owned_pids": list(guard.owned)})
                    last_report = now
                if summary != last_state:
                    emit({"event": "state", "enabled": enabled, "reason": status.get("reason"),
                          "service_pids": [p["pid"] for p in processes], "owned_pids": list(guard.owned)})
                    last_state = summary
            except Exception as error:
                # Retain ownership and retry; never resume on an inconclusive read.
                category = type(error).__name__
                if category != last_error:
                    emit({"event": "error", "category": category})
                    last_error = category
            time.sleep(INTERVAL)
    finally:
        # Do not run queued UI requests by resuming on shutdown. A replacement
        # daemon recovers the journal; deliberate removal uses `release`.
        emit({"event": "stopped", "owned_pids": list(guard.owned)})
    return 0


if __name__ == "__main__":
    sys.exit(main())
