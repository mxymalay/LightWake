"""装机脚本的回归检查；全程只碰临时目录，不写真的 /Applications 或桌面。

做法：把 install.py 当模块加载，然后把它的 BUILD / ARCHIVE 两个全局量改指到临时
目录 —— 调用的还是生产函数本体，测的也是同一份代码。

两个不显然的坑，写在这里免得下次重踩：
  * 造"签名坏了"的现场要在**签完名之后**再改 Info.plist。codesign 把 plist 的哈希
    封进了签名，所以这一改就过不了自检；改 Mach-O 尾部反而不可靠。
  * 造文件用 shutil.copyfile 而不是 copy2 —— copy2 会调 chflags，沙箱里直接
    PermissionError: [Errno 1] Operation not permitted。
"""
import importlib.util
import os
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
INSTALL_PY = SCRIPTS / "install.py"


def make_app(folder: Path, name: str, version: str, build: str) -> Path:
    """造一个结构完整、ad-hoc 签名过的 .app。"""
    app = folder / name
    (app / "Contents/MacOS").mkdir(parents=True)
    executable = app / "Contents/MacOS/ScreenGuard"
    shutil.copyfile("/usr/bin/true", executable)
    executable.chmod(0o755)
    info = {
        "CFBundleExecutable": "ScreenGuard",
        "CFBundleIdentifier": "local.xy.lightwake-test",
        "CFBundleName": name,
        "CFBundleShortVersionString": version,
        "CFBundleVersion": build,
    }
    with (app / "Contents/Info.plist").open("wb") as stream:
        plistlib.dump(info, stream)
    subprocess.run(
        ["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", str(app)],
        check=True, capture_output=True,
    )
    return app


def installed_version(app: Path) -> str:
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    return f"{info['CFBundleShortVersionString']}/{info['CFBundleVersion']}"


class InstallTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location("lw_install", INSTALL_PY)
        self.install = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.install)

        self.root = Path(tempfile.mkdtemp(prefix="lw-install-test-"))
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        self.staging = self.root / "build"
        self.applications = self.root / "Applications"
        self.desktop = self.root / "Desktop"
        self.archive = self.root / "archive"
        for folder in (self.staging, self.applications, self.desktop, self.archive):
            folder.mkdir()
        self.install.BUILD = self.staging
        self.install.ARCHIVE = self.archive

        self.names = [name for _, name, _ in self.install.SHORTCUTS]
        self.labels = [label for label, _, _ in self.install.SHORTCUTS]

    # -------------------------------------------------------------- 辅助
    def seed_staging(self, version="2.5.4", build="12", skip=None, tamper=None):
        for name in self.names:
            if name == skip:
                continue
            make_app(self.staging, name, version, build)
            if name == tamper:
                plist_path = self.staging / name / "Contents/Info.plist"
                with plist_path.open("rb") as stream:
                    info = plistlib.load(stream)
                info["CFBundleVersion"] = "999"
                with plist_path.open("wb") as stream:
                    plistlib.dump(info, stream)

    def seed_installed(self, version="2.5.3", build="11"):
        for name in self.names:
            make_app(self.applications, name, version, build)

    def archived(self) -> list[Path]:
        folders = list(self.archive.iterdir())
        self.assertLessEqual(len(folders), 1, f"归档目录下不该有多个日期文件夹：{folders}")
        return list(folders[0].iterdir()) if folders else []

    # -------------------------------------------------------------- 场景
    def test_first_install_puts_the_app_in_place(self):
        self.seed_staging()
        installed = self.install.install_apps(self.applications)
        self.assertEqual(len(installed), len(self.names))
        for name in self.names:
            self.assertTrue((self.applications / name).is_dir(), name)
            self.assertEqual(installed_version(self.applications / name), "2.5.4/12")
        self.assertEqual(self.archived(), [], "没装过就不该有归档")

    def test_upgrade_archives_the_previous_version(self):
        self.seed_staging(version="2.5.4", build="12")
        self.seed_installed(version="2.5.3", build="11")

        self.install.install_apps(self.applications)

        for name in self.names:
            self.assertEqual(installed_version(self.applications / name), "2.5.4/12", name)
        archived = self.archived()
        self.assertEqual(len(archived), len(self.names), [p.name for p in archived])
        # 归档里那份必须还是旧版本，别把新的当旧的存了
        for entry in archived:
            self.assertEqual(installed_version(entry), "2.5.3/11", entry.name)

    def test_broken_signature_rolls_back_to_the_previous_version(self):
        self.seed_staging(tamper=self.names[-1])
        self.seed_installed(version="2.5.3", build="11")

        # 先确认这份坏产物确实过不了签名自检，否则这个场景测不出东西
        probe = subprocess.run(
            ["/usr/bin/codesign", "--verify", "--deep", "--strict", str(self.staging / self.names[-1])],
            capture_output=True, text=True,
        )
        self.assertNotEqual(probe.returncode, 0, "坏产物居然过了签名自检，场景失效")

        with self.assertRaises(SystemExit) as caught:
            self.install.install_apps(self.applications)

        message = str(caught.exception)
        self.assertIn(self.names[-1], message, "报错该点名出问题的 app")
        self.assertIn("退回原状", message)
        for name in self.names:
            self.assertTrue((self.applications / name).is_dir(), name)
            self.assertEqual(installed_version(self.applications / name), "2.5.3/11", name)
        self.assertEqual(self.archived(), [], "退回的那几份不该在归档里留重复")

    def test_broken_signature_leaves_nothing_when_installing_fresh(self):
        self.seed_staging(tamper=self.names[-1])

        with self.assertRaises(SystemExit):
            self.install.install_apps(self.applications)

        # 留个装坏的 app 在 /Applications 比没有更糟
        for name in self.names:
            self.assertFalse((self.applications / name).exists(), name)

    def test_incomplete_build_output_is_refused_before_touching_anything(self):
        self.seed_staging(skip=self.names[0])
        self.seed_installed(version="2.5.3", build="11")

        with self.assertRaises(SystemExit) as caught:
            self.install.install_apps(self.applications)

        message = str(caught.exception)
        self.assertIn(self.names[0], message, "该点名缺哪个产物")
        self.assertIn("xcodebuild -license accept", message, "该带上网关那条出路")
        for name in self.names:
            self.assertEqual(installed_version(self.applications / name), "2.5.3/11", name)
        self.assertEqual(self.archived(), [])

    def test_shortcut_is_idempotent_and_rebuildable(self):
        for name in self.names:
            make_app(self.applications, name, "2.5.4", "12")

        self.install.place_shortcuts(self.applications, self.desktop, force=False)
        first = {}
        for label, name in zip(self.labels, self.names):
            link = self.desktop / label
            self.assertTrue(link.exists(), label)
            resolved = self.install.alias_target(link)
            self.assertIsNotNone(resolved, label)
            self.assertEqual(os.path.realpath(resolved), os.path.realpath(self.applications / name))
            first[label] = os.stat(link).st_ino

        self.install.place_shortcuts(self.applications, self.desktop, force=False)
        for label in self.labels:
            self.assertEqual(os.stat(self.desktop / label).st_ino, first[label],
                             f"{label} 不该被重建（会打乱 Finder 记住的图标位置）")

        self.install.place_shortcuts(self.applications, self.desktop, force=True)
        rebuilt = sum(1 for label in self.labels
                      if os.stat(self.desktop / label).st_ino != first[label])
        self.assertEqual(rebuilt, len(self.labels), "强制重建时每个都该换掉")

    def test_shortcut_pointing_elsewhere_is_repaired(self):
        for name in self.names:
            make_app(self.applications, name, "2.5.4", "12")
        elsewhere = self.root / "别处"
        elsewhere.mkdir()
        make_app(elsewhere, self.names[0], "1.0", "1")

        # 一个"指错"的按钮，以及一个根本不是别名的普通文件
        self.install.make_alias(elsewhere / self.names[0], self.desktop / self.labels[0])
        plain = self.desktop / "一个普通文件"
        plain.write_text("这不是别名\n")

        self.assertIsNotNone(self.install.alias_target(self.desktop / self.labels[0]))
        self.assertIsNone(self.install.alias_target(plain),
                          "普通文件会被解析成它自己，那不算别名")

        self.install.place_shortcuts(self.applications, self.desktop, force=False)

        for label, name in zip(self.labels, self.names):
            resolved = self.install.alias_target(self.desktop / label)
            self.assertIsNotNone(resolved, label)
            self.assertEqual(os.path.realpath(resolved), os.path.realpath(self.applications / name), label)

    def test_legacy_apps_and_shortcuts_are_archived(self):
        """3.0 之前的四个 app 和四个桌面按钮要挪进归档，而不是留在原地误导。"""
        self.seed_installed(version="2.5.4", build="12")
        for name in self.install.RETIRED_APPS:
            make_app(self.applications, name, "2.5.4", "12")
        for label in self.install.RETIRED_SHORTCUTS:
            self.install.make_alias(self.applications / self.names[0], self.desktop / label)

        self.install.retire_legacy(self.applications / name for name in self.install.RETIRED_APPS)
        self.install.retire_legacy(self.desktop / label for label in self.install.RETIRED_SHORTCUTS)

        for name in self.install.RETIRED_APPS:
            self.assertFalse((self.applications / name).exists(), f"{name} 该被挪走")
        for label in self.install.RETIRED_SHORTCUTS:
            self.assertFalse((self.desktop / label).exists(), f"{label} 该被挪走")

        archived = {entry.name for entry in self.archived()}
        for name in self.install.RETIRED_APPS + self.install.RETIRED_SHORTCUTS:
            self.assertTrue(any(entry.startswith(name) for entry in archived),
                            f"{name} 该在归档里，实际只有 {sorted(archived)}")

    def test_retire_legacy_is_quiet_when_there_is_nothing_to_retire(self):
        self.install.retire_legacy(self.applications / name for name in self.install.RETIRED_APPS)
        self.assertEqual(self.archived(), [], "没东西可归档时不该建目录")


if __name__ == "__main__":
    unittest.main()
