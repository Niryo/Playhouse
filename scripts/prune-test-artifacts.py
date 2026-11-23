#!/usr/bin/env python3
"""Delete test-run artifact directories older than the retention window.

Test runners keep a run's artifacts after it exits so a failure can be
inspected. This bounds how long they stay, so repeated runs do not fill /tmp.
Only direct child directories of the root that this user owns are removed;
symlinks, files, and the current run are never touched.
"""
import argparse
from datetime import datetime, timezone
import os
from pathlib import Path
import re
import shutil
import stat
import sys
import time

DEFAULT_RETENTION_HOURS = 48
RETENTION_VARIABLE = "PLAYHOUSE_TEST_ARTIFACT_RETENTION_HOURS"
# scripts/test-ui-tart.sh names each run `<UTC timestamp>-<pid>`.
RUN_ID = re.compile(r"(\d{8}T\d{6}Z)-\d+")


def retention_hours():
    value = os.environ.get(RETENTION_VARIABLE, "").strip()
    if not value:
        return DEFAULT_RETENTION_HOURS
    try:
        hours = float(value)
    except ValueError:
        hours = -1
    if not hours > 0:
        raise SystemExit(f"{RETENTION_VARIABLE} must be a positive number of hours, not {value!r}.")
    return hours


def started_at(entry, info, age_from):
    if age_from == "mtime":
        return info.st_mtime
    # Run IDs carry their start time; directory mtimes in the shared VM mount
    # are rewritten by the guest and do not reflect when the run happened.
    match = RUN_ID.fullmatch(entry.name)
    if match is None:
        return None
    try:
        moment = datetime.strptime(match.group(1), "%Y%m%dT%H%M%SZ")
    except ValueError:
        return None
    return moment.replace(tzinfo=timezone.utc).timestamp()


def directory_size(path):
    total = 0
    for directory, _, files in os.walk(path):
        for name in files:
            try:
                total += os.lstat(os.path.join(directory, name)).st_blocks * 512
            except OSError:
                pass
    return total


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--prefix", default="", help="Only consider directories whose name starts with this.")
    parser.add_argument("--age-from", choices=["mtime", "run-id"], required=True)
    parser.add_argument("--keep", action="append", default=[], help="A directory name never to remove.")
    arguments = parser.parse_args()
    hours = retention_hours()
    cutoff = time.time() - hours * 3600
    removed = 0
    freed = 0
    # Pruning is housekeeping: an unreadable root must not fail the test run.
    try:
        entries = list(os.scandir(arguments.root))
    except OSError:
        return
    for entry in entries:
        if not entry.name.startswith(arguments.prefix) or entry.name in arguments.keep:
            continue
        try:
            info = entry.stat(follow_symlinks=False)
        except OSError:
            continue
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
            continue
        start = started_at(entry, info, arguments.age_from)
        if start is None or start >= cutoff:
            continue
        size = directory_size(entry.path)
        shutil.rmtree(entry.path, ignore_errors=True)
        if not os.path.lexists(entry.path):
            removed += 1
            freed += size
    if removed:
        print(
            f"Pruned {removed} test artifact director{'y' if removed == 1 else 'ies'} "
            f"older than {hours:g}h from {arguments.root} ({freed / 1_000_000_000:.1f} GB).",
            file=sys.stderr,
        )


if __name__ == "__main__":
    main()
