import importlib.util
import os
from pathlib import Path
import re
import tempfile
import tarfile
import unittest
from unittest.mock import patch
import zipfile

SCRIPTS = Path(__file__).resolve().parents[1]
def load(name):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / (name + ".py"))
    mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod); return mod
release = load("release_tools")

def desktop_fixture(root, target, binary_name=None):
    (root / "pubspec.yaml").write_text("version: 0.2.4+7\n")
    for name in ["LICENSE", "THIRD_PARTY_NOTICES.md", "assets/fonts/LICENSE.txt"]:
        file = root / name
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text("notice")
    # Copy the project's real configuration so a branding/build-name mismatch
    # cannot be hidden by a fixture that repeats the packaging assumption.
    source = (SCRIPTS.parent / target / "CMakeLists.txt").read_text()
    configured = re.search(r'^set\(BINARY_NAME "([^"]+)"\)', source, re.M).group(1)
    if binary_name is not None:
        source = source.replace(f'set(BINARY_NAME "{configured}")',
                                f'set(BINARY_NAME "{binary_name}")')
        configured = binary_name
    cmake = root / target / "CMakeLists.txt"
    cmake.parent.mkdir(parents=True, exist_ok=True)
    cmake.write_text(source)
    path = "build/linux/x64/release/bundle" if target == "linux" else "build/windows/x64/runner/Release"
    bundle = root / path
    bundle.mkdir(parents=True)
    return bundle, configured + (".exe" if target == "windows" else "")

class ReleaseTests(unittest.TestCase):
    def test_version_rejects_shell_content(self):
        with tempfile.TemporaryDirectory() as t:
            p = Path(t)
            for invalid in ["version: 0.2.4+0", "version: 0.2.4+7; rm x", "version: $(echo bad)"]:
                (p / "pubspec.yaml").write_text(invalid)
                with self.assertRaises(ValueError): release.version(p)
            (p / "pubspec.yaml").write_text("version: 0.2.4+7\n")
            self.assertEqual(release.version(p), ("0.2.4", 7))

    def test_partial_signing_fails_without_writing(self):
        with tempfile.TemporaryDirectory() as t:
            with self.assertRaises(ValueError): release.signing(Path(t), {"ANDROID_KEY_ALIAS": "test"})
            self.assertEqual(list(Path(t).iterdir()), [])
            self.assertEqual(release.signing(Path(t), {}), "debug")

    def test_untrusted_branch_cannot_publish(self):
        with patch.dict(os.environ, {"GITHUB_REF": "refs/pull/42/merge"}):
            with self.assertRaises(ValueError): release.publish()

    def test_packaging_includes_runtime_assets_and_notices(self):
        with tempfile.TemporaryDirectory() as t:
            p = Path(t)
            bundle, runner = desktop_fixture(p, "windows")
            for name in [runner, "flutter_windows.dll", "data/icudtl.dat", "data/flutter_assets/a"]:
                f = bundle / name; f.parent.mkdir(parents=True, exist_ok=True); f.write_text("build")
            archive = release.package("windows", root=p)
            with zipfile.ZipFile(archive) as z:
                self.assertEqual(z.read("Spar_Vault/" + runner), b"build")
                self.assertIn("Spar_Vault/flutter_windows.dll", z.namelist())
                self.assertIn("Spar_Vault/data/flutter_assets/a", z.namelist())
                self.assertIn("notices/assets/fonts/LICENSE.txt", z.namelist())

    def test_linux_packaging_preserves_runner_mode_assets_and_notices(self):
        with tempfile.TemporaryDirectory() as t:
            p = Path(t)
            bundle, runner = desktop_fixture(p, "linux")
            for name in [runner, "lib/libflutter_linux_gtk.so", "data/icudtl.dat", "data/flutter_assets/a"]:
                file = bundle / name
                file.parent.mkdir(parents=True, exist_ok=True)
                file.write_text("build")
            (bundle / runner).chmod(0o755)
            archive = release.package("linux", root=p)
            with tarfile.open(archive, "r:gz") as z:
                self.assertEqual(z.extractfile("Spar_Vault/" + runner).read(), b"build")
                self.assertEqual(z.getmember("Spar_Vault/" + runner).mode & 0o777, 0o755)
                self.assertIn("Spar_Vault/lib/libflutter_linux_gtk.so", z.getnames())
                self.assertIn("Spar_Vault/data/flutter_assets/a", z.getnames())
                self.assertIn("Spar_Vault/notices/assets/fonts/LICENSE.txt", z.getnames())

    def test_desktop_packaging_uses_configured_runner_name(self):
        for target in ["linux", "windows"]:
            with self.subTest(target=target), tempfile.TemporaryDirectory() as t:
                p = Path(t)
                bundle, runner = desktop_fixture(p, target, "renamed_vault")
                (bundle / runner).write_text("build")
                archive = release.package(target, root=p)
                if target == "linux":
                    with tarfile.open(archive, "r:gz") as z:
                        self.assertIn("Spar_Vault/" + runner, z.getnames())
                else:
                    with zipfile.ZipFile(archive) as z:
                        self.assertIn("Spar_Vault/" + runner, z.namelist())

    def test_desktop_packaging_rejects_bundle_without_configured_runner(self):
        for target in ["linux", "windows"]:
            with self.subTest(target=target), tempfile.TemporaryDirectory() as t:
                p = Path(t)
                bundle, _ = desktop_fixture(p, target)
                (bundle / "unrelated_runner").write_text("build")
                with self.assertRaisesRegex(ValueError, "runner missing"):
                    release.package(target, root=p)

