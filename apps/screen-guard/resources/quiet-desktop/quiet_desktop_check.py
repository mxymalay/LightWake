#!/usr/bin/python3
"""Read-only preflight before using tools that can wake the physical desktop.

Exit 0: ready; 2: defer desktop access; 1: detection failed or is inconclusive.
This takes a snapshot, not a lock: recheck immediately before desktop access.

CGSSessionScreenIsLocked is an undocumented macOS convention. On this Mac,
an unlocked, logged-in console session omits the key; ScreenGuard also uses
that convention. Absence means unlocked ONLY for a valid logged-in console.
Revalidate this assumption after macOS upgrades. No user identifiers or raw
session data are returned, and no desktop, power, or authentication state is
changed. Merely running this checker does not intercept other tools.
"""
import ctypes
import json
import os
from pathlib import Path
import plistlib
import stat
import sys


MAX_SESSION_BYTES = 1024 * 1024


class DetectionError(Exception):
    """A fixed, non-sensitive machine-readable failure reason."""


def _boolean(value):
    return value if type(value) is bool else None


def parse_session_plist(payload):
    """Reduce a serialized CF dictionary to the three relevant booleans."""
    if not isinstance(payload, bytes) or not 0 < len(payload) <= MAX_SESSION_BYTES:
        raise DetectionError("session_data_invalid")
    try:
        session = plistlib.loads(payload)
    except Exception:
        raise DetectionError("session_data_invalid") from None
    if not isinstance(session, dict):
        raise DetectionError("session_data_invalid")
    on_console = _boolean(session.get("kCGSSessionOnConsoleKey"))
    login_done = _boolean(session.get("kCGSessionLoginDoneKey"))
    lock_key = "CGSSessionScreenIsLocked"
    locked = _boolean(session.get(lock_key))
    if lock_key not in session and on_console is True and login_done is True:
        locked = False
    return {"on_console": on_console, "login_done": login_done, "locked": locked}


def read_lightwake_active(path):
    """Read ScreenGuard's mode token, without returning the token itself."""
    try:
        with path.open("rb") as stream:
            if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
                raise DetectionError("lightwake_state_unavailable")
            raw = stream.read(4097)
    except FileNotFoundError:
        return False
    except (OSError, ValueError):
        raise DetectionError("lightwake_state_unavailable") from None
    if len(raw) > 4096:
        raise DetectionError("lightwake_state_unavailable")
    try:
        token = raw.decode("utf-8").strip()
    except UnicodeError:
        raise DetectionError("lightwake_state_unavailable") from None
    if not token:
        raise DetectionError("lightwake_state_unavailable")
    # ScreenGuard trims whitespace and newlines before comparing its mode.
    return token != "off"


def evaluate(displays_asleep, session, lightwake_active):
    """Pure policy: every online display and the current session must be safe."""
    valid_displays = (isinstance(displays_asleep, list) and
                      all(type(value) is bool for value in displays_asleep))
    displays = list(displays_asleep) if valid_displays else []
    session = session if isinstance(session, dict) else {}
    on_console = _boolean(session.get("on_console"))
    login_done = _boolean(session.get("login_done"))
    locked = _boolean(session.get("locked"))
    lightwake = _boolean(lightwake_active)
    result = {"allowed": False, "reason": "state_unknown",
              "displays_asleep": displays, "locked": locked,
              "on_console": on_console, "lightwake_active": lightwake}
    if not valid_displays or not displays:
        result["reason"] = "display_state_unknown"
        return result, 1
    blockers = ((any(displays), "display_asleep"),
                (lightwake is True, "lightwake_active"),
                (locked is True, "session_locked"),
                (on_console is False, "not_on_console"),
                (login_done is False, "login_incomplete"))
    for blocked, reason in blockers:
        if blocked:
            result["reason"] = reason
            return result, 2
    if any(value is None for value in (on_console, login_done, locked, lightwake)):
        return result, 1
    result.update(allowed=True, reason="ready")
    return result, 0


class NativeDesktopReader:
    """Only read-only CoreGraphics and CoreFoundation APIs are bound."""
    def __init__(self):
        self.cg = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
        self.cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
        pointer = ctypes.c_void_p
        uint = ctypes.c_uint32
        self.cg.CGGetOnlineDisplayList.argtypes = [uint, ctypes.POINTER(uint), ctypes.POINTER(uint)]
        self.cg.CGGetOnlineDisplayList.restype = ctypes.c_int32
        self.cg.CGDisplayIsAsleep.argtypes = [uint]
        self.cg.CGDisplayIsAsleep.restype = uint
        self.cg.CGSessionCopyCurrentDictionary.argtypes = []
        self.cg.CGSessionCopyCurrentDictionary.restype = pointer
        self.cf.CFGetTypeID.argtypes = [pointer]
        self.cf.CFGetTypeID.restype = ctypes.c_ulong
        self.cf.CFDictionaryGetTypeID.argtypes = []
        self.cf.CFDictionaryGetTypeID.restype = ctypes.c_ulong
        self.cf.CFPropertyListCreateData.argtypes = [pointer, pointer, ctypes.c_long,
                                                   ctypes.c_ulong, ctypes.POINTER(pointer)]
        self.cf.CFPropertyListCreateData.restype = pointer
        self.cf.CFDataGetLength.argtypes = [pointer]
        self.cf.CFDataGetLength.restype = ctypes.c_long
        self.cf.CFDataGetBytePtr.argtypes = [pointer]
        self.cf.CFDataGetBytePtr.restype = pointer
        self.cf.CFRelease.argtypes = [pointer]
        self.cf.CFRelease.restype = None

    def displays_asleep(self):
        capacity = 64
        ids = (ctypes.c_uint32 * capacity)()
        count = ctypes.c_uint32()
        status = self.cg.CGGetOnlineDisplayList(capacity, ids, ctypes.byref(count))
        # A full buffer cannot prove that the list was not truncated.
        if status != 0 or not 0 < count.value < capacity:
            raise DetectionError("display_state_unavailable")
        states = [self.cg.CGDisplayIsAsleep(ids[index]) for index in range(count.value)]
        if any(value not in (0, 1) for value in states):
            raise DetectionError("display_state_unavailable")
        return [bool(value) for value in states]

    def session(self):
        session = self.cg.CGSessionCopyCurrentDictionary()
        data = None
        error = ctypes.c_void_p()
        try:
            if not session or self.cf.CFGetTypeID(session) != self.cf.CFDictionaryGetTypeID():
                raise DetectionError("session_state_unavailable")
            # 200 = kCFPropertyListBinaryFormat_v1_0. Never print the raw plist.
            data = self.cf.CFPropertyListCreateData(None, session, 200, 0, ctypes.byref(error))
            if not data:
                raise DetectionError("session_state_unavailable")
            length = self.cf.CFDataGetLength(data)
            address = self.cf.CFDataGetBytePtr(data)
            if not address or not 0 < length <= MAX_SESSION_BYTES:
                raise DetectionError("session_data_invalid")
            return parse_session_plist(ctypes.string_at(address, length))
        finally:
            if data:
                self.cf.CFRelease(data)
            if error.value:
                self.cf.CFRelease(error)
            if session:
                self.cf.CFRelease(session)


def main():
    displays, session, lightwake = [], {}, None
    failure = None
    try:
        native = NativeDesktopReader()
        displays = native.displays_asleep()
        session = native.session()
    except DetectionError as error:
        failure = str(error)
    except Exception:
        failure = "native_api_unavailable"
    try:
        lightwake = read_lightwake_active(Path.home() / "Library/Application Support/ScreenGuard/mode")
    except DetectionError as error:
        failure = failure or str(error)
    except Exception:
        failure = failure or "lightwake_state_unavailable"
    result, code = evaluate(displays, session, lightwake)
    if failure:
        result.update(allowed=False, reason=failure)
        code = 1
    print(json.dumps(result, separators=(",", ":")))
    return code


if __name__ == "__main__":
    sys.exit(main())
