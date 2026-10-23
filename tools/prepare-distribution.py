#!/usr/bin/env python3
"""Prepare a Homebrew payload only from a notarized release ZIP."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def run(*args):
    result = subprocess.run(args, text=True, capture_output=True)
    if result.returncode:
        raise ValueError(f"{args[0]} failed: {(result.stderr or result.stdout).strip()}")
    return result.stdout + result.stderr


def checked_archive(archive, version, destination):
    with zipfile.ZipFile(archive) as zipped:
        for item in zipped.infolist():
            parts = Path(item.filename).parts
            if not parts or parts[0] != "Aervane.app" or ".." in parts or "\\" in item.filename:
                raise ValueError(f"Unexpected archive entry: {item.filename}")
        if zipped.testzip():
            raise ValueError("ZIP integrity check failed")
    run("/usr/bin/ditto", "-x", "-k", str(archive), str(destination))
    app = destination / "Aervane.app"
    with (app / "Contents/Info.plist").open("rb") as file:
        info = plistlib.load(file)
    if info.get("CFBundleIdentifier") != "dev.kirniy.aervane" or info.get("CFBundleShortVersionString") != version:
        raise ValueError("App identity/version does not match VERSION")
    if info.get("LSMinimumSystemVersion") != "13.0":
        raise ValueError("Update distribution metadata for the changed minimum macOS")
    team = None
    for code in [app, app / "Contents/Library/LaunchDaemons/AervaneHelper"]:
        run("/usr/bin/codesign", "--verify", "--all-architectures", "--deep", "--strict", str(code))
        signature = run("/usr/bin/codesign", "--display", "--verbose=4", str(code))
        found = re.search(r"^TeamIdentifier=([A-Z0-9]{10})$", signature, re.MULTILINE)
        if "Authority=Developer ID Application:" not in signature or not found:
            raise ValueError("Public releases need Developer ID Application signing; development/ad hoc signing is not accepted")
        if team and team != found[1]:
            raise ValueError("App and helper have different signing teams")
        team = found[1]
    for executable in [app / "Contents/MacOS/Aervane", app / "Contents/Library/LaunchDaemons/AervaneHelper"]:
        if set(run("/usr/bin/lipo", "-archs", str(executable)).split()) != {"arm64", "x86_64"}:
            raise ValueError("Public distributions require both arm64 and x86_64 in the app and helper")
        for architecture in ("arm64", "x86_64"):
            build = run("xcrun", "vtool", "-arch", architecture, "-show-build", str(executable))
            minimum = re.search(r"^\s*minos\s+(\d+)\.(\d+)(?:\.(\d+))?\s*$", build, re.MULTILINE)
            if not minimum or "platform MACOS" not in build or tuple(int(v or 0) for v in minimum.groups()) > (13, 0, 0):
                raise ValueError(f"{executable.name} {architecture} cannot run on the declared macOS 13 minimum")
    run("/usr/sbin/spctl", "--assess", "--type", "execute", "--verbose=2", str(app))
    run("xcrun", "stapler", "validate", str(app))
    return team


def prepare(archive, output):
    version = (ROOT / "VERSION").read_text().strip()
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ValueError("VERSION must be major.minor.patch")
    if output.exists():
        raise ValueError(f"Output already exists: {output}. Choose a new --output directory.")
    with tempfile.TemporaryDirectory(prefix="aervane-distribution-") as temp:
        team = checked_archive(archive, version, Path(temp))
    filename = f"Aervane-{version}-macos-universal.zip"
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    manifest = {
        "version": version,
        "bundleID": "dev.kirniy.aervane",
        "arch": ["arm64", "x86_64"],
        "minimumMacOS": 13,
        "teamID": team,
        "notarized": True,
        "sha256": digest,
        "url": f"https://github.com/kirniy/aervane/releases/download/v{version}/{filename}",
    }
    output.mkdir(parents=True)
    shutil.copy2(archive, output / filename)
    (output / "release.json").write_text(json.dumps(manifest, indent=2) + "\n")
    (output / "SHA256SUMS.txt").write_text(f"{digest}  {filename}\n")
    template = (ROOT / "Casks/aervane.rb.in").read_text()
    (output / "aervane.rb").write_text(template.replace("@VERSION@", version).replace("@SHA256@", digest))
    print(f"Prepared {output}\nVersion {version}; signing team {team}; SHA-256 {digest}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, default=ROOT / "dist/Aervane.app.zip")
    parser.add_argument("--output", type=Path, default=ROOT / "dist/distribution")
    args = parser.parse_args()
    try:
        prepare(args.archive.resolve(), args.output.resolve())
    except (ValueError, OSError, zipfile.BadZipFile) as error:
        parser.exit(1, f"Distribution not prepared: {error}\n")
