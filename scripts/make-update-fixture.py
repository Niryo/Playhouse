#!/usr/bin/env python3
"""Builds a local release feed for the update tests, shared by the bridge and UI suites.

From a test build of Playhouse it makes, under --root (outside the repository):

  Installed/Playhouse.app   a stable copy at --installed, the app the update replaces
                            (with --apps, a claimed app in the staged pool instead)
  feed/playhouse-release.json and feed/Playhouse-<release>.zip
                            a signed release at --release, served from --base-url
                            (scripts/serve-update-feed.py serving feed/ over HTTP)
  feed/api-latest.json      the release's asset list, shaped like GitHub's latest
                            release API, which the app reads when the feed link fails

Both copies keep the test build's bundle identifier and are signed ad hoc, which a
test build accepts in place of the release certificate. Each fixture gets its own
Ed25519 key; the public key is printed for PLAYHOUSE_E2E_UPDATE_PUBLIC_KEY.

--tamper makes a release the app must refuse or roll back:
  archive    bytes are added to the zip after it was signed (its size doesn't match)
  checksum   one byte of the zip is changed after it was signed (same size, its
             checksum doesn't match)
  signature  the manifest is signed with a key other than the printed one
  broken     the release's bridge daemon exits 1, so the installed app fails its
             health check and the installer puts the old version back
  installer  the release's command-line tool exits 1, so its installer can't run

--architecture and --minimum-system set what the release says it runs on, to make
one this Mac can't run.

The UI tests run sandboxed, and everything a sandboxed process writes is quarantined,
so an app it copies can't be launched and its tools can't run. For them, test-ui.sh
runs --stage-apps DIR first, outside the sandbox: it signs one release app per kind
(normal, broken, installer) and clones a pool of installed apps. A fixture made with
--apps DIR then claims one installed app from the pool and uses it where it is (even
a move from inside the sandbox quarantines it), and zips the staged release app, so
neither app is written from inside the sandbox.

Prints {"installedApp", "feed", "feedURL", "releaseAPIURL", "publicKey", "archive", "release"}
as JSON; "feed" is the feed folder.
"""

import argparse
import hashlib
import json
import os
import plistlib
import shutil
import subprocess
import sys
from pathlib import Path

MARKER = "Playhouse update tests own this release fixture (v1).\n"
RELEASE_TOOL = Path(__file__).resolve().parent / "release-tool.sh"


def run(*command, **kwargs):
    return subprocess.run([str(part) for part in command], check=True, capture_output=True, text=True, **kwargs)


def prepare_root(root):
    marker = root / ".playhouse-update-fixture"
    if root.exists():
        if not marker.is_file() or marker.read_text(encoding="utf-8") != MARKER:
            sys.exit(f"Refusing to replace {root}: it has no update fixture ownership marker.")
        shutil.rmtree(root)
    root.mkdir(parents=True)
    marker.write_text(MARKER, encoding="utf-8")


def stamp(app, version, build):
    info_path = app / "Contents" / "Info.plist"
    with info_path.open("rb") as handle:
        info = plistlib.load(handle)
    info["CFBundleShortVersionString"] = version
    info["CFBundleVersion"] = build
    info["PlayhouseReleaseChannel"] = "stable"
    with info_path.open("wb") as handle:
        plistlib.dump(info, handle)


def sign(app):
    macos = app / "Contents" / "MacOS"
    for helper in ("playhouse-cli", "playhouse-daemon"):
        run("codesign", "--force", "--sign", "-", macos / helper)
    run("codesign", "--force", "--sign", "-", app)
    run("codesign", "--verify", "--strict", "--deep", app)


def copy_app(source, destination, version, build):
    destination.parent.mkdir(parents=True, exist_ok=True)
    run("ditto", source, destination)
    stamp(destination, version, build)


def build_release(source, built, release, tamper):
    copy_app(source, built, release, "200")
    if tamper in ("broken", "installer"):
        name = "playhouse-daemon" if tamper == "broken" else "playhouse-cli"
        executable = built / "Contents" / "MacOS" / name
        executable.unlink()
        shutil.copyfile("/usr/bin/false", executable)
        executable.chmod(0o755)
    sign(built)


def stage_apps(source, directory, installed_version, release, count):
    """Signs the release apps and clones `count` installed apps under `directory`."""
    prepare_root(directory)
    template = directory / "installed-template" / "Playhouse.app"
    copy_app(source, template, installed_version, "100")
    sign(template)
    for slot in range(count):
        destination = directory / "installed" / f"{slot:03d}"
        destination.mkdir(parents=True)
        # An APFS clone: instant, and it shares the template's blocks.
        run("cp", "-Rc", template, destination / "Playhouse.app")
    for kind in ("normal", "broken", "installer"):
        build_release(source, directory / "release" / kind / "Playhouse.app", release, None if kind == "normal" else kind)
    print(json.dumps({"staged": str(directory), "installed": count}))


def claim_staged_installed(directory):
    pool = directory / "installed"
    for slot in sorted(pool.iterdir()) if pool.is_dir() else []:
        try:
            (slot / ".claimed").open("x").close()
        except FileExistsError:
            continue
        return slot / "Playhouse.app"
    sys.exit(f"No staged installed apps are left in {pool}; scripts/test-ui.sh stages them.")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-app", required=True, type=Path)
    parser.add_argument("--stage-apps", type=Path, help="sign release apps and clone installed apps here, then stop")
    parser.add_argument("--count", type=int, default=24, help="how many installed apps --stage-apps clones")
    parser.add_argument("--apps", type=Path, help="take the apps from a --stage-apps folder instead of copying them")
    parser.add_argument("--root", type=Path)
    parser.add_argument("--installed", default="0.1.0")
    parser.add_argument("--release", default="0.2.0")
    parser.add_argument("--notes", default="Faster boards and a new update button.")
    parser.add_argument("--tamper", choices=["archive", "checksum", "signature", "broken", "installer"])
    parser.add_argument("--architecture", default="arm64")
    parser.add_argument("--minimum-system", default="14.0")
    parser.add_argument("--base-url", help="where the feed folder is served, such as http://127.0.0.1:PORT/")
    options = parser.parse_args()
    if options.stage_apps:
        stage_apps(options.source_app, options.stage_apps.absolute(), options.installed, options.release, options.count)
        return
    if not options.root or not options.base_url:
        parser.error("--root and --base-url are required unless --stage-apps is given")

    root = options.root.absolute()
    if str(root).startswith(str(Path(__file__).resolve().parent.parent)):
        sys.exit("The update fixture must live outside the repository.")
    prepare_root(root)

    installed = root / "Installed" / "Playhouse.app"
    if options.apps:
        installed = claim_staged_installed(options.apps.absolute())
        kind = options.tamper if options.tamper in ("broken", "installer") else "normal"
        built = options.apps.absolute() / "release" / kind / "Playhouse.app"
    else:
        copy_app(options.source_app, installed, options.installed, "100")
        sign(installed)
        built = root / "build" / "Playhouse.app"
        build_release(options.source_app, built, options.release, options.tamper)

    feed = root / "feed"
    feed.mkdir()
    archive = feed / f"Playhouse-{options.release}.zip"
    run("ditto", "-c", "-k", "--keepParent", built, archive)
    data = archive.read_bytes()
    base_url = options.base_url.rstrip("/") + "/"
    info = {
        "version": options.release,
        "build": "200",
        "commit": "0" * 40,
        "publishedAt": "2026-11-18T00:00:00Z",
        "minimumSystemVersion": options.minimum_system,
        "architecture": options.architecture,
        "notes": options.notes,
        "asset": {
            "name": archive.name,
            "url": base_url + archive.name,
            "size": len(data),
            "sha256": hashlib.sha256(data).hexdigest(),
        },
    }
    info_path = root / "release-info.json"
    info_path.write_text(json.dumps(info, indent=2, sort_keys=True), encoding="utf-8")

    keys = json.loads(run(RELEASE_TOOL, "keygen").stdout)
    signing_key = keys["privateKey"]
    if options.tamper == "signature":
        signing_key = json.loads(run(RELEASE_TOOL, "keygen").stdout)["privateKey"]
    manifest = run(RELEASE_TOOL, "sign", info_path, env={**os.environ, "PLAYHOUSE_RELEASE_PRIVATE_KEY": signing_key}).stdout
    (feed / "playhouse-release.json").write_text(manifest, encoding="utf-8")

    if options.tamper == "archive":
        with archive.open("ab") as handle:
            handle.write(b"tampered")
    if options.tamper == "checksum":
        tampered = bytearray(data)
        tampered[len(tampered) // 2] ^= 0xFF
        archive.write_bytes(bytes(tampered))

    manifest_name = "playhouse-release.json"
    (feed / "api-latest.json").write_text(json.dumps({
        "tag_name": "v" + options.release,
        "assets": [{"name": name, "browser_download_url": base_url + name} for name in (manifest_name, archive.name)],
    }, indent=2), encoding="utf-8")

    if not options.apps:
        shutil.rmtree(root / "build")
    print(json.dumps({
        "installedApp": str(installed),
        "feed": str(feed),
        "feedURL": base_url + manifest_name,
        "releaseAPIURL": base_url + "api-latest.json",
        "publicKey": keys["publicKey"],
        "archive": str(archive),
        "release": options.release,
    }))


if __name__ == "__main__":
    main()
