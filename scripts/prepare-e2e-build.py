#!/usr/bin/env python3
"""Build or reuse the content-matched app bundle used by CLI/XPC verification."""
import argparse
import fcntl
import hashlib
import json
import os
import plistlib
from pathlib import Path
import subprocess
import stat
import sys
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("--root", required=True, type=Path)
parser.add_argument("--profile-bundle-id", required=True)
parser.add_argument("--architecture", required=True)
arguments = parser.parse_args()
root = arguments.root.resolve()


def toolchain_fingerprint():
    commands = [
        ["xcode-select", "-p"],
        ["xcodebuild", "-version"],
        ["xcrun", "--sdk", "macosx", "--show-sdk-version"],
        ["xcrun", "--sdk", "macosx", "--show-sdk-build-version"],
    ]
    return "\n".join(
        subprocess.run(command, check=True, capture_output=True, text=True).stdout.strip()
        for command in commands
    )


def source_fingerprint():
    paths = subprocess.run(
        ["git", "-C", str(root), "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        check=True,
        capture_output=True,
    ).stdout.split(b"\0")
    digest = hashlib.sha256()
    digest.update(arguments.architecture.encode())
    digest.update(arguments.profile_bundle_id.encode())
    digest.update(toolchain_fingerprint().encode())
    for raw_path in sorted(path for path in paths if path):
        relative_path = Path(os.fsdecode(raw_path))
        if relative_path.as_posix() in {
            "AGENTS.md",
            "StationAI/BridgeTests/BridgeTestContracts.json",
            "scripts/check-button-feedback.py",
            "scripts/check-test-parity.py",
            "scripts/prepare-e2e-fixture.py",
            "scripts/seed-legacy-task-store.swift",
            "scripts/test-bridge.py",
            "workflow-improvements.md",
        }:
            continue
        path = root / os.fsdecode(raw_path)
        digest.update(raw_path)
        try:
            digest.update(str(stat.S_IMODE(path.lstat().st_mode)).encode())
            if path.is_symlink():
                digest.update(b"L" + os.fsencode(os.readlink(path)))
            elif path.is_file():
                digest.update(b"F" + path.read_bytes())
            else:
                digest.update(b"D")
        except FileNotFoundError:
            digest.update(b"MISSING")
    return digest.hexdigest()


fingerprint = source_fingerprint()
cache_root = Path(tempfile.gettempdir()) / "StationAI-E2E-BuildCache"
root_key = hashlib.sha256(os.fsencode(root)).hexdigest()[:16]
cache_path = cache_root / f"{root_key}-{fingerprint}"
derived_data = cache_path / "DerivedData"
app = derived_data / "Build/Products/Debug/StationAI.app"
cli = app / "Contents/MacOS/stationai-cli"
bundle_id = f"{arguments.profile_bundle_id}.e2e.{fingerprint[:16]}"
manifest = cache_path / "source-fingerprint"
cache_root.mkdir(parents=True, exist_ok=True)


def cache_bundle_is_valid():
    bridge = app / "Contents/XPCServices/StationAIBridge.xpc/Contents/Info.plist"
    try:
        app_info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        bridge_info = plistlib.loads(bridge.read_bytes())
    except (OSError, plistlib.InvalidFileException):
        return False
    return (
        app_info.get("CFBundleIdentifier") == bundle_id
        and app_info.get("StationAISourceWorktree") == str(root)
        and app_info.get("StationAIStoreCompatibilityVersion") == "2"
        and bridge_info.get("CFBundleIdentifier") == bundle_id + ".bridge"
        and bridge_info.get("StationAIApplicationBundleIdentifier") == bundle_id
        and bridge_info.get("StationAISourceWorktree") == str(root)
        and bridge_info.get("StationAIStoreCompatibilityVersion") == "2"
    )


with (cache_root / f"{root_key}.lock").open("a+") as lock_file:
    fcntl.flock(lock_file, fcntl.LOCK_EX)
    reusable = (
        manifest.is_file()
        and manifest.read_text(encoding="utf-8").strip() == fingerprint
        and cli.is_file()
        and os.access(cli, os.X_OK)
        and cache_bundle_is_valid()
    )
    if reusable:
        print(f"Reusing matching E2E build {fingerprint[:16]}.", file=os.sys.stderr)
    else:
        cache_path.mkdir(parents=True, exist_ok=True)
        subprocess.run(
            [
                "xcodebuild", "build-for-testing", "-quiet",
                "-project", str(root / "StationAI.xcodeproj"),
                "-scheme", "StationAI",
                "-configuration", "Debug",
                "-destination", f"platform=macOS,arch={arguments.architecture}",
                "-derivedDataPath", str(derived_data),
                "-only-testing:StationAIUITests/StationAIUITests",
                "CODE_SIGNING_ALLOWED=YES",
                "CODE_SIGN_IDENTITY=-",
                f"ARCHS={arguments.architecture}",
                "ONLY_ACTIVE_ARCH=YES",
                f"STATIONAI_APP_BUNDLE_IDENTIFIER={bundle_id}",
            ],
            cwd=root,
            stdout=sys.stderr,
            check=True,
        )
        if source_fingerprint() != fingerprint:
            raise SystemExit("The source tree changed while the E2E app was building; refusing to cache a mixed build.")
        if not cli.is_file() or not os.access(cli, os.X_OK):
            raise SystemExit(f"The app build did not produce its bundled CLI at {cli}.")
        temporary_manifest = manifest.with_suffix(".tmp")
        temporary_manifest.write_text(fingerprint + "\n", encoding="utf-8")
        os.replace(temporary_manifest, manifest)

print(json.dumps({"derivedData": str(derived_data), "bundleID": bundle_id}))
