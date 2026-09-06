#!/usr/bin/env python3
"""Run LightWake guard tests without calling pmset displaysleepnow."""
from pathlib import Path
import argparse
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--visual", action="store_true", help="also briefly show native animation test panels")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("These tests use macOS AppKit and IOKit.")
    output = ROOT / ".build/tests"
    output.mkdir(parents=True, exist_ok=True)
    sg = ROOT / "apps/screen-guard"
    suites = [
        ("guard-state", sg, ["GuardState.swift", "GuardStateTests.swift"], ["-D", "GUARD_STATE_TESTS"], []),
        ("control-store", sg, ["ControlStore.swift", "ControlStoreTests.swift"], ["-D", "CONTROL_STORE_TESTS"], []),
        ("guard-integration", sg, ["GuardState.swift", "ControlStore.swift", "ScreenGuard.swift", "IntegrationTests.swift"], [], [str(output)]),
    ]
    if args.visual:
        suites.append(("notice-animation", sg, ["GuardState.swift", "ControlStore.swift", "ScreenGuard.swift", "NoticeAnimationTests.swift"], [], [str(output)]))
    with tempfile.TemporaryDirectory(prefix="executables-", dir=output) as temporary:
        for name, directory, sources, flags, arguments in suites:
            executable = Path(temporary) / name
            print(f"Running {name}...", flush=True)
            subprocess.run(["xcrun", "swiftc", "-parse-as-library", *flags,
                            *(str(directory / source) for source in sources), "-o", str(executable)], check=True)
            subprocess.run([str(executable), *arguments], check=True)
    print("All selected test suites passed.")


if __name__ == "__main__":
    main()
