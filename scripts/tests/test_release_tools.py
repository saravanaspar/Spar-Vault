import importlib.util
import json
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

def publish_fixture(root, debug=False):
    (root / "pubspec.yaml").write_text("version: 0.2.5+8\n")
    output = root / "dist"
    output.mkdir()
    for platform in ["Linux_x64.tar.gz", "Windows_x64.zip", "macOS.zip"]:
        (output / f"Spar_Vault_0.2.5_{platform}").write_bytes(b"bundle")
    name = "Spar_Vault_0.2.5_Android" + ("_Test" if debug else "")
    with zipfile.ZipFile(output / (name + ".zip"), "w") as archive:
        archive.writestr(name + ".apk", b"apk")
    return {
        "GITHUB_REF": "refs/heads/main",
        "GITHUB_REPOSITORY": "example/vault",
        "GITHUB_SHA": "a" * 40,
    }

def existing_release_responses(files, status="ahead", draft=False, tag_sha="b" * 40):
    return [
        json.dumps([{"ref": "refs/tags/v0.2.5", "object": {"type": "commit", "sha": tag_sha}}]),
        json.dumps([[{"tag_name": "v0.2.5", "draft": draft}]]),
        json.dumps({"status": status, "base_commit": {"sha": tag_sha},
                    "merge_base_commit": {"sha": tag_sha}, "files": files}),
    ]

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

    def test_published_release_notes_match_android_build(self):
        for debug in [False, True]:
            with self.subTest(debug=debug), tempfile.TemporaryDirectory() as t:
                root = Path(t)
                environment = publish_fixture(root, debug)
                with patch.dict(os.environ, environment), patch.object(release, "gh", return_value="[]") as gh:
                    release.publish(root)
                create = next(call for call in gh.call_args_list if call.args[:2] == ("release", "create"))
                notes_file = Path(create.args[create.args.index("--notes-file") + 1])
                notes = notes_file.read_text()
                if debug:
                    self.assertIn("Android_Test", notes)
                    self.assertIn("Spar Vault Dev with its own vault data", notes)
                    self.assertIn("debug signing", notes)
                    self.assertIn("Configure all four Android signing secrets", notes)
                    self.assertNotIn("Android is a release build", notes)
                else:
                    self.assertIn("Android is a release build", notes)
                    self.assertIn("configured release key", notes)
                    self.assertNotIn("Android_Test", notes)
                    self.assertNotIn("debug signing", notes)
                self.assertEqual(create.args[2], "v0.2.5")
                self.assertIn("--draft", create.args)
                self.assertEqual(gh.call_args.args[:3], ("release", "edit", "v0.2.5"))
                self.assertIn("--draft=false", gh.call_args.args)

    def test_repository_update_leaves_published_tag_and_assets_unchanged(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            environment = publish_fixture(root)
            files = [{"filename": name} for name in [
                "README.md", "CHANGELOG.md", "CONTRIBUTING.md", "docs/ARCHITECTURE.md",
                ".github/workflows/build-release.yml", "scripts/release_tools.py",
                "scripts/tests/test_release_tools.py",
            ]]
            with patch.dict(os.environ, environment), patch.object(
                release, "gh", side_effect=existing_release_responses(files)
            ) as gh:
                release.publish(root)
            self.assertEqual(gh.call_count, 3)
            self.assertTrue(all(call.args[0] == "api" and "--method" not in call.args
                                for call in gh.call_args_list))
            self.assertEqual(gh.call_args.args[1],
                             "repos/example/vault/compare/" + "b" * 40 + "..." + "a" * 40)
            self.assertFalse((root / "dist/SHA256SUMS.txt").exists())

    def test_same_version_application_changes_and_renames_are_rejected(self):
        paths = ["lib/main.dart", "pubspec.yaml", "pubspec.lock",
                 "packages/vault_core/lib/src/codec.dart", "android/app/build.gradle.kts",
                 "linux/runner/system_lock.cc", "windows/runner/system_lock.cpp",
                 "macos/Runner/MainFlutterWindow.swift", "ios/Runner/AppDelegate.swift",
                 "web/spar_offline.js", "browser/host.py", "assets/branding/icon.png",
                 "LICENSE", "THIRD_PARTY_NOTICES.md", "third_party/licenses/Flutter.txt",
                 "scripts/prepare_web.py", "unclassified.txt"]
        cases = [[{"filename": "README.md"}, {"filename": name}] for name in paths]
        cases.append([{"filename": "README.md", "previous_filename": "lib/main.dart"}])
        for files in cases:
            with self.subTest(files=files), tempfile.TemporaryDirectory() as t:
                root = Path(t)
                environment = publish_fixture(root)
                with patch.dict(os.environ, environment), patch.object(
                    release, "gh", side_effect=existing_release_responses(files)
                ) as gh:
                    with self.assertRaisesRegex(ValueError, "Bump pubspec.yaml"):
                        release.publish(root)
                self.assertTrue(all("--method" not in call.args and call.args[0] == "api"
                                    for call in gh.call_args_list))

    def test_unverifiable_repository_comparisons_are_rejected(self):
        cases = [
            ([], "ahead"),
            ([{}], "ahead"),
            ([{"filename": "README.md"}], "diverged"),
            ([{"filename": "README.md"}], "behind"),
            ([{"filename": f"docs/page-{i}.md"} for i in range(300)], "ahead"),
        ]
        for files, status in cases:
            with self.subTest(count=len(files), status=status), tempfile.TemporaryDirectory() as t:
                root = Path(t)
                environment = publish_fixture(root)
                with patch.dict(os.environ, environment), patch.object(
                    release, "gh", side_effect=existing_release_responses(files, status)
                ) as gh:
                    with self.assertRaisesRegex(ValueError, "Bump pubspec.yaml"):
                        release.publish(root)
                self.assertTrue(all(call.args[0] == "api" and "--method" not in call.args
                                    for call in gh.call_args_list))

    def test_draft_tag_cannot_be_retargeted_by_documentation_changes(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            environment = publish_fixture(root)
            with patch.dict(os.environ, environment), patch.object(
                release, "gh", side_effect=existing_release_responses(
                    [{"filename": "README.md"}], draft=True)
            ) as gh:
                with self.assertRaisesRegex(ValueError, "Bump pubspec.yaml"):
                    release.publish(root)
            self.assertEqual(gh.call_count, 2)

    def test_identical_published_commit_needs_no_comparison_or_upload(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            environment = publish_fixture(root)
            with patch.dict(os.environ, environment), patch.object(
                release, "gh", side_effect=existing_release_responses([], tag_sha="a" * 40)
            ) as gh:
                release.publish(root)
            self.assertEqual(gh.call_count, 2)
            self.assertTrue(all(call.args[0] == "api" and "--method" not in call.args
                                for call in gh.call_args_list))

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

