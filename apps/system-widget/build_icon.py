"""Package the approved PNG into the standard macOS icon sizes."""
from pathlib import Path
import subprocess

assets = Path(__file__).resolve().parent / "assets"
source = assets / "SystemStatus-source.png"
iconset = assets / "SystemStatus.iconset"
iconset.mkdir(exist_ok=True)
for size in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        pixels = size * scale
        suffix = "@2x" if scale == 2 else ""
        target = iconset / f"icon_{size}x{size}{suffix}.png"
        subprocess.run(
            ["sips", "-z", str(pixels), str(pixels), str(source), "--out", str(target)],
            check=True, stdout=subprocess.DEVNULL,
        )
subprocess.run(
    ["iconutil", "-c", "icns", str(iconset), "-o", str(assets / "SystemStatus.icns")],
    check=True,
)
print("Packaged:", assets / "SystemStatus.icns")
