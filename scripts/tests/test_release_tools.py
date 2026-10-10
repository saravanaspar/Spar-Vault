import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile

SCRIPTS = Path(__file__).resolve().parents[1]
def load(name):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / (name + ".py"))
    mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod); return mod
release = load("release_tools")

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
            (p / "pubspec.yaml").write_text("version: 0.2.4+7\n")
            for name in ["LICENSE", "THIRD_PARTY_NOTICES.md", "assets/fonts/LICENSE.txt"]:
                f = p / name; f.parent.mkdir(parents=True, exist_ok=True); f.write_text("notice")
            bundle = p / "build/windows/x64/runner/Release"
            for name in ["spar_vault.exe", "flutter_windows.dll", "data/icudtl.dat", "data/flutter_assets/a"]:
                f = bundle / name; f.parent.mkdir(parents=True, exist_ok=True); f.write_text("build")
            archive = release.package("windows", root=p)
            with zipfile.ZipFile(archive) as z:
                self.assertIn("Spar_Vault/flutter_windows.dll", z.namelist())
                self.assertIn("Spar_Vault/data/flutter_assets/a", z.namelist())
                self.assertIn("notices/assets/fonts/LICENSE.txt", z.namelist())

