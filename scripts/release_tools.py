#!/usr/bin/env python3
"""Version, signing, complete-bundle packaging and immutable GitHub releases."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SIGNING = ("ANDROID_KEYSTORE_BASE64", "ANDROID_STORE_PASSWORD", "ANDROID_KEY_PASSWORD", "ANDROID_KEY_ALIAS")

def version(root=ROOT):
    text = (root / "pubspec.yaml").read_text()
    match = re.search(r"^version: ([0-9]+\.[0-9]+\.[0-9]+)\+([1-9][0-9]*)\s*$", text, re.M)
    if not match:
        raise ValueError("pubspec.yaml needs an exact X.Y.Z+positive-build version.")
    return match.group(1), int(match.group(2))

def prop(value):
    # Java Properties is ISO-8859-1. Escape even passwords containing newlines.
    return "".join("\\u%04x" % unit for unit in
                   [int.from_bytes(value.encode("utf-16-be")[i:i+2], "big")
                    for i in range(0, len(value.encode("utf-16-be")), 2)])

def signing(root=ROOT, environ=None):
    env = os.environ if environ is None else environ
    values = [env.get(k, "") for k in SIGNING]
    if not any(values):
        return "debug"
    if not all(values):
        raise ValueError("Configure all four Android signing secrets or remove the partial configuration.")
    raw = base64.b64decode(values[0], validate=True)
    if not raw or len(raw) > 1024 * 1024:
        raise ValueError("Invalid Android signing keystore.")
    directory = root / "android"
    key = directory / "ci-release.jks"
    key.write_bytes(raw); key.chmod(0o600)
    properties = directory / "key.properties"
    properties.write_text("\n".join(f"{k}={prop(v)}" for k, v in zip(
        ("storeFile", "storePassword", "keyPassword", "keyAlias"),
        (str(key.resolve()), values[1], values[2], values[3]))) + "\n")
    properties.chmod(0o600)
    return "release"

def notices(root):
    names = ["LICENSE", "THIRD_PARTY_NOTICES.md", "assets/fonts/LICENSE.txt"]
    names += [p.relative_to(root).as_posix() for p in sorted((root / "third_party/licenses").glob("*.txt"))]
    for name in names:
        if not (root / name).is_file():
            raise ValueError(f"Missing distribution notice: {name}")
    return names

def desktop_runner_name(root, target):
    cmake = root / target / "CMakeLists.txt"
    names = re.findall(
        r'^[ \t]*set\([ \t]*BINARY_NAME[ \t]+"([A-Za-z0-9][A-Za-z0-9_.-]*)"[ \t]*\)[ \t]*(?:#.*)?$',
        cmake.read_text(), re.M)
    if len(names) != 1:
        raise ValueError(f"Expected one literal BINARY_NAME in {target}/CMakeLists.txt.")
    return names[0] + (".exe" if target == "windows" else "")

def package(target, mode="release", root=ROOT):
    release, _ = version(root)
    output = root / "dist"; output.mkdir(exist_ok=True)
    prefix = f"Spar_Vault_{release}"
    license_files = notices(root)
    if target == "linux":
        bundle = root / "build/linux/x64/release/bundle"
        runner = desktop_runner_name(root, target)
        if not (bundle / runner).is_file():
            raise ValueError(f"Linux runner missing: {runner}")
        dest = output / f"{prefix}_Linux_x64.tar.gz"
        with tarfile.open(dest, "w:gz") as archive:
            archive.add(bundle, arcname="Spar_Vault")
            for name in license_files:
                archive.add(root / name, arcname=f"Spar_Vault/notices/{name}")
    elif target == "macos":
        apps = list((root / "build/macos/Build/Products/Release").glob("*.app"))
        if len(apps) != 1:
            raise ValueError("Expected one complete macOS app.")
        stage = output / "macos-stage"
        if stage.exists(): shutil.rmtree(stage)
        stage.mkdir()
        shutil.copytree(apps[0], stage / apps[0].name, symlinks=True)
        for name in license_files:
            file = stage / "notices" / name; file.parent.mkdir(parents=True, exist_ok=True); shutil.copyfile(root / name, file)
        dest = output / f"{prefix}_macOS.zip"
        subprocess.run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(stage), str(dest)], check=True)
        shutil.rmtree(stage)
    else:
        dest = output / (f"{prefix}_Windows_x64.zip" if target == "windows" else f"{prefix}_Android{'_Test' if mode == 'debug' else ''}.zip")
        if target == "windows":
            bundle = root / "build/windows/x64/runner/Release"
            runner = desktop_runner_name(root, target)
            if not (bundle / runner).is_file(): raise ValueError(f"Windows runner missing: {runner}")
            files = [(p, "Spar_Vault/" + p.relative_to(bundle).as_posix()) for p in bundle.rglob("*") if p.is_file()]
        elif target == "android":
            apk = root / f"build/app/outputs/flutter-apk/app-{mode}.apk"
            if not apk.is_file(): raise ValueError("Android APK missing.")
            files = [(apk, dest.stem + ".apk")]
        else:
            raise ValueError("Unknown build target.")
        with zipfile.ZipFile(dest, "w", zipfile.ZIP_DEFLATED) as archive:
            for path, name in files: archive.write(path, name)
            for name in license_files: archive.write(root / name, "notices/" + name)
    return dest

def gh(*args, data=None):
    command = ["gh", *args]
    return subprocess.run(command, input=data, text=True, check=True, capture_output=True).stdout

def repository_only_update(repo, base, head):
    """Allow an existing release to survive changes outside application inputs."""
    if not re.fullmatch(r"[0-9a-f]{40}", base):
        return False
    comparison = json.loads(gh("api", f"repos/{repo}/compare/{base}...{head}"))
    if not isinstance(comparison, dict) or comparison.get("status") != "ahead":
        return False
    for field in ("base_commit", "merge_base_commit"):
        commit = comparison.get(field)
        if not isinstance(commit, dict) or commit.get("sha") != base:
            return False
    files = comparison.get("files")
    # GitHub comparison responses include at most 300 files. At that boundary
    # we cannot prove there are no omitted application changes.
    if not isinstance(files, list) or not files or len(files) >= 300:
        return False
    documents = {"README.md", "CHANGELOG.md", "CONTRIBUTING.md", "SECURITY.md", "AUTHORS.md"}
    def allowed(name):
        return isinstance(name, str) and (
            name in documents or name.startswith("docs/") and name.endswith(".md") or
            name.startswith(".github/") or name == "scripts/release_tools.py" or
            name.startswith("scripts/tests/") and name.endswith(".py"))
    return all(isinstance(file, dict) and allowed(file.get("filename")) and
               ("previous_filename" not in file or allowed(file["previous_filename"]))
               for file in files)

def publish(root=ROOT):
    if os.environ.get("GITHUB_REF") != "refs/heads/main":
        raise ValueError("Releases may be published only from main.")
    release, _ = version(root)
    repo, sha = os.environ["GITHUB_REPOSITORY"], os.environ["GITHUB_SHA"]
    if not re.fullmatch(r"[0-9a-f]{40}", sha): raise ValueError("Invalid tested commit.")
    output = root / "dist"
    files = sorted(p for p in output.iterdir() if p.is_file() and p.suffix in (".zip", ".gz"))
    for platform in ("Android", "Linux", "Windows", "macOS"):
        if sum(platform in p.name for p in files) != 1: raise ValueError(f"Expected one {platform} release artifact.")
    # Verify the Android archive really contains an installable APK.
    apk_archive = next(p for p in files if "Android" in p.name)
    with zipfile.ZipFile(apk_archive) as z:
        if sum(name.endswith(".apk") for name in z.namelist()) != 1: raise ValueError("Android APK missing from artifact.")
    tag = "v" + release
    refs = json.loads(gh("api", f"repos/{repo}/git/matching-refs/tags/{tag}"))
    exact = next((r for r in refs if r["ref"] == "refs/tags/" + tag), None)
    releases = json.loads(gh("api", "--paginate", "--slurp", f"repos/{repo}/releases?per_page=100"))
    existing = next((r for page in releases for r in page if r["tag_name"] == tag), None)
    if exact:
        if (exact["object"]["type"] == "commit" and exact["object"]["sha"] != sha and
                existing and not existing["draft"] and
                repository_only_update(repo, exact["object"]["sha"], sha)):
            print(f"{tag} is already published; repository-only changes leave its tag and assets unchanged.")
            return
        if exact["object"]["type"] != "commit" or exact["object"]["sha"] != sha:
            raise ValueError("Existing tag points at another commit. Bump pubspec.yaml; published tags are never moved.")
    else:
        gh("api", "--method", "POST", f"repos/{repo}/git/refs", "--input", "-", data=json.dumps({"ref": "refs/tags/" + tag, "sha": sha}))
    if existing and not existing["draft"]:
        print(f"{tag} is already published; leaving it unchanged."); return
    sums = output / "SHA256SUMS.txt"
    sums.write_text("".join(hashlib.sha256(p.read_bytes()).hexdigest() + "  " + p.name + "\n" for p in files))
    notes = output / "release-notes.txt"
    android_note = (
        "Android_Test uses debug signing and installs separately as Spar Vault Dev with its own vault data. "
        "Configure all four Android signing secrets for a production APK. "
        if apk_archive.name.endswith("_Android_Test.zip") else
        "Android is a release build signed with the configured release key. "
    )
    notes.write_text(
        "Builds of the tested main commit. Unzip the Android archive to obtain the APK.\n\n" + android_note +
        "Keep the same release key for upgrades. Back up your vault before switching signing keys.\n\n"
        "Windows is unsigned; macOS is ad-hoc signed and not notarized. macOS System lock requires a valid application identifier and Keychain signing entitlements. "
        "Linux requires GTK3, libfido2 and OpenSSL; System lock needs a PIN-configured FIDO2 hmac-secret key.\n")
    if not existing:
        gh("release", "create", tag, "--repo", repo, "--target", sha, "--verify-tag", "--draft", "--title", f"Spar Vault {release}", "--notes-file", str(notes))
    gh("release", "upload", tag, *map(str, files), str(sums), "--repo", repo, "--clobber")
    gh("release", "edit", tag, "--repo", repo, "--draft=false")

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("metadata", "signing", "package", "publish"))
    parser.add_argument("--target", choices=("android", "linux", "windows", "macos"))
    parser.add_argument("--mode", default="release", choices=("debug", "release"))
    args = parser.parse_args()
    if args.command == "metadata":
        name, build = version()
        data = f"version={name}\nbuild={build}\ntag=v{name}\n"
        if os.environ.get("GITHUB_OUTPUT"):
            with open(os.environ["GITHUB_OUTPUT"], "a") as file: file.write(data)
        print(data, end="")
    elif args.command == "signing":
        mode = signing()
        if os.environ.get("GITHUB_OUTPUT"):
            with open(os.environ["GITHUB_OUTPUT"], "a") as file: file.write(f"mode={mode}\n")
        print("Android build mode:", mode)
    elif args.command == "package": print(package(args.target, args.mode))
    else: publish()

if __name__ == "__main__": main()

