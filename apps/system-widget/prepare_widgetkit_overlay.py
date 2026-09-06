"""Prepare a local compiler interface for WidgetKit's existing native blur API.

This copies SDK declarations and linker stubs into build/compiler-overlays. It
does not modify the SDK, supply an ABI implementation, or embed a framework in
the app. Calls still link to the installed system WidgetKit. The API is private
and the caller must gate its use to macOS 26 or later.
"""

from pathlib import Path
import re
import shutil
import subprocess
import tempfile


EXPECTED_SYMBOLS = (
    "_$s7SwiftUI19WidgetConfigurationP0C3KitE24preferredBackgroundStyleyQrAD0cgH0OF",
    "_$s7SwiftUI19WidgetConfigurationP0C3KitE24preferredBackgroundStyleyQrAD0cgH0OFQOMQ",
    "_$s9WidgetKit0A15BackgroundStyleO4bluryA2CmFWC",
    "_$s9WidgetKit0A15BackgroundStyleOMa",
)

BLUR_DECLARATIONS = """
// Local compatibility declarations for existing system WidgetKit symbols.
// Keep this enum resilient: no guessed raw values, layout, or implementation.
@available(macOS 26.0, *)
public enum WidgetBackgroundStyle {
  case blur
}
@available(macOS 26.0, *)
extension SwiftUI.WidgetConfiguration {
  @_Concurrency.MainActor @preconcurrency public func preferredBackgroundStyle(_ style: WidgetKit.WidgetBackgroundStyle) -> some SwiftUI.WidgetConfiguration
}
"""


def prepare_widgetkit_overlay(base, sdk_path=None):
    """Return the local framework search directory, rebuilt from the active SDK."""
    if sdk_path is None:
        sdk_path = subprocess.check_output(
            ["xcrun", "--show-sdk-path"], text=True
        ).strip()
    source = Path(sdk_path) / "System/Library/Frameworks/WidgetKit.framework"
    exports = (source / "WidgetKit.tbd").read_text()
    missing = [symbol for symbol in EXPECTED_SYMBOLS if symbol not in exports]
    if missing:
        raise RuntimeError("Selected SDK lacks the verified WidgetKit blur symbols: " + ", ".join(missing))

    interface_path = Path("Modules/WidgetKit.swiftmodule")
    interface = (source / interface_path / "arm64e-apple-macos.swiftinterface").read_text()
    interface, replacements = re.subn(
        r"-target arm64e-apple-macos(\S+)",
        r"-target arm64-apple-macos\1",
        interface,
        count=1,
    )
    if replacements != 1:
        raise RuntimeError("Selected SDK has an unexpected WidgetKit interface target")
    if "public enum WidgetBackgroundStyle" in interface or "func preferredBackgroundStyle(" in interface:
        raise RuntimeError("Selected SDK already declares the blur API; review the local compatibility overlay")

    search_path = Path(base).resolve() / "build/compiler-overlays"
    search_path.mkdir(parents=True, exist_ok=True)
    overlay = search_path / "WidgetKit.framework"
    with tempfile.TemporaryDirectory(prefix=".widgetkit-", dir=search_path) as temporary:
        staged = Path(temporary) / "WidgetKit.framework"
        shutil.copytree(source, staged, symlinks=True)
        (staged / interface_path / "arm64-apple-macos.swiftinterface").write_text(
            interface + BLUR_DECLARATIONS
        )
        if overlay.exists():
            shutil.rmtree(overlay)
        staged.rename(overlay)
    return search_path


if __name__ == "__main__":
    print(prepare_widgetkit_overlay(Path(__file__).resolve().parent))
