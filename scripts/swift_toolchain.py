"""定位 Swift / C 工具链，并给出可以直接拼进 argv 的命令前缀。

平时走 `/usr/bin/xcrun` —— 它会跟随 `xcode-select` 的选择，是最正确的来源。

但 Xcode 跨大版本升级会让"许可证同意"失效（同意记录存在
`/Library/Preferences/com.apple.dt.Xcode.plist` 里，版本对不上当前 Xcode 就不认），
之后 `/usr/bin` 下的 `xcrun` / `swiftc` / `lipo` / `cc` 这几个 shim 一律报
`You have not agreed to the Xcode license agreements`。

Xcode 包里的真实工具链**不做**这个检查，所以 xcrun 失败时退回直调。两条路给出同一套
工具，构建产物没有区别。代价是直调必须自己交代 SDK —— 那正是 `*_command()` 存在的
理由：让"要不要给 SDK 参数"只在一个地方回答。

根治仍然是在终端里跑一次 `sudo xcodebuild -license accept`。
"""

from __future__ import annotations

import subprocess
from pathlib import Path

# xcode-select 没给出可用位置时的兜底
DEVELOPER_FALLBACK = Path("/Applications/Xcode.app/Contents/Developer")

# 同一件工具在完整 Xcode 和 Command Line Tools 里的相对位置不一样，两种都认
_SWIFTC = ["Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc", "usr/bin/swiftc"]
_CLANG = ["Toolchains/XcodeDefault.xctoolchain/usr/bin/clang", "usr/bin/clang"]
_SDK = ["Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk", "SDKs/MacOSX.sdk"]
_LIPO = ["Toolchains/XcodeDefault.xctoolchain/usr/bin/lipo", "usr/bin/lipo"]


def _xcrun(*arguments: str) -> Path | None:
    """问 xcrun 一个路径。它不可用（多半是许可证没同意）就返回 None。"""
    try:
        result = subprocess.run(["/usr/bin/xcrun", *arguments], capture_output=True, text=True)
    except OSError:
        return None
    if result.returncode != 0:
        return None
    found = result.stdout.strip()
    return Path(found) if found else None


def _developer_directories() -> list[Path]:
    """可能的 Developer 目录，按可信度排序。xcode-select 是独立工具，不受许可证影响。"""
    directories = []
    result = subprocess.run(["/usr/bin/xcode-select", "-print-path"], capture_output=True, text=True)
    if result.returncode == 0 and result.stdout.strip():
        directories.append(Path(result.stdout.strip()))
    directories.append(DEVELOPER_FALLBACK)
    return list(dict.fromkeys(directories))


def _direct(relatives: list[str]) -> Path:
    """在 Developer 目录里找第一个存在的相对路径。

    一个都不存在时返回首选位置 —— 让调用方拿到一个真实路径去报错，
    而不是在这里抛一个看不出所以然的异常。
    """
    directories = _developer_directories()
    for directory in directories:
        for relative in relatives:
            candidate = directory / relative
            if candidate.exists():
                return candidate
    return directories[0] / relatives[0]


def swiftc() -> Path:
    return _xcrun("--find", "swiftc") or _direct(_SWIFTC)


def clang() -> Path:
    return _xcrun("--find", "clang") or _direct(_CLANG)


def sdk_path() -> Path:
    return _xcrun("--sdk", "macosx", "--show-sdk-path") or _direct(_SDK)


def lipo() -> Path:
    return _xcrun("--find", "lipo") or _direct(_LIPO)


def swift_compile_command() -> list[str]:
    """Swift 编译命令前缀。缺了 `-sdk` 直调 swiftc 会说找不到标准库。"""
    return [str(swiftc()), "-sdk", str(sdk_path())]


def c_compile_command() -> list[str]:
    """C 编译命令前缀。缺了 `-isysroot` 直调 clang 会说 `ld: library 'System' not found`。"""
    return [str(clang()), "-isysroot", str(sdk_path())]
