#!/usr/bin/env python3
"""Build LightWake's screen-off and screen-on apps using the selected Xcode toolchain."""
from pathlib import Path
import platform
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]

if __name__ == "__main__":
    if sys.platform != "darwin" or platform.machine() != "arm64":
        raise SystemExit("LightWake currently builds on Apple-silicon macOS.")
    subprocess.run(
        [sys.executable, str(ROOT / "apps/screen-guard/build_local.py")],
        cwd=ROOT, check=True,
    )
    print("Both LightWake applications built and signed. See apps/screen-guard/build/.")
