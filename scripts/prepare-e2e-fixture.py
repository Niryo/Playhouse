#!/usr/bin/env python3

import shutil
import subprocess
from pathlib import Path


FIXTURE_ROOT = Path("/tmp/stationai-bridge-workspaces")
OWNER_MARKER = ".stationai-bridge-fixture"
OWNER_CONTENTS = "StationAI bridge tests own this deterministic fixture (v1).\n"


def run_git(repository: Path, *arguments: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(repository), *arguments],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode:
        raise RuntimeError(
            f"git {' '.join(arguments)} failed in {repository}: "
            f"{result.stderr.strip()}"
        )
    return result.stdout


def create_repository(repository: Path, files: dict[str, str]) -> None:
    repository.mkdir(parents=True, exist_ok=True)
    for name, contents in files.items():
        (repository / name).write_text(contents, encoding="utf-8")
    run_git(repository, "init", "--initial-branch=main")
    run_git(repository, "config", "user.name", "StationAI Bridge Test")
    run_git(repository, "config", "user.email", "stationai-bridge-test@example.invalid")
    run_git(repository, "add", ".")
    run_git(repository, "commit", "-m", "Create clean StationAI bridge test fixture")
    status = run_git(repository, "status", "--porcelain")
    if status:
        raise RuntimeError(f"Fixture repository {repository} is not clean after commit: {status}")


def prepare() -> None:
    if FIXTURE_ROOT.exists():
        marker = FIXTURE_ROOT / OWNER_MARKER
        if not marker.is_file() or marker.read_text(encoding="utf-8") != OWNER_CONTENTS:
            raise RuntimeError(
                f"Refusing to remove {FIXTURE_ROOT}: its StationAI bridge test ownership marker is missing or invalid."
            )
        shutil.rmtree(FIXTURE_ROOT)

    suggested_parent = FIXTURE_ROOT / "suggested-parent"
    primary = suggested_parent / "primary"
    nested = primary / "nested"
    secondary = suggested_parent / "group" / "secondary"
    external = FIXTURE_ROOT / "outside-parent" / "linked-outside"
    custom = suggested_parent / "custom-folder"
    unavailable = suggested_parent / "unavailable-folder"
    alternate_parent = suggested_parent / "alternate-parent"
    alternate = alternate_parent / "alternate"

    suggested_parent.mkdir(parents=True)
    (FIXTURE_ROOT / OWNER_MARKER).write_text(OWNER_CONTENTS, encoding="utf-8")

    create_repository(
        primary,
        {
            ".gitignore": "nested/\n",
            "stationai-primary.txt": "Primary baseline.\n",
        },
    )
    create_repository(nested, {"nested-note.txt": "Nested baseline.\n"})
    create_repository(secondary, {"stationai-secondary.txt": "Secondary baseline.\n"})
    create_repository(external, {"external-note.txt": "Outside baseline.\n"})
    create_repository(alternate, {"alternate-note.txt": "Alternate baseline.\n"})
    custom.mkdir(parents=True)
    (custom / "stationai-custom.txt").write_text("Custom folder baseline.\n", encoding="utf-8")
    unavailable.mkdir(parents=True)
    (unavailable / "availability-note.txt").write_text("Temporarily unavailable folder baseline.\n", encoding="utf-8")
    (suggested_parent / "linked-outside").symlink_to(external, target_is_directory=True)

    print(f"Prepared clean Git workspace fixture at {FIXTURE_ROOT}")


if __name__ == "__main__":
    prepare()
