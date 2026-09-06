#!/usr/bin/env python3
"""Build both LightWake components using the selected Xcode toolchain."""
from pathlib import Path
import platform
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]

if __name__ == "__main__":
    if sys.platform != "darwin" or platform.machine() != "arm64":
        raise SystemExit("LightWake currently builds on Apple-silicon macOS.")
    for component in ("screen-guard", "system-widget"):
        subprocess.run(
            [sys.executable, str(ROOT / "apps" / component / "build_local.py")],
            cwd=ROOT, check=True,
        )
    print("All three applications built and signed. See apps/*/build/.")
