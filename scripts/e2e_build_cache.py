"""Pruning for the content-matched E2E build cache.

prepare-e2e-build.py stores one full app build per (worktree, source fingerprint)
under `<cache_root>/<root_key>-<fingerprint>`. Every source edit produces a new
fingerprint, so without pruning the cache grows by a full build per edit.

A build is removed only when all of these hold:
- it is not the build the current caller is about to use;
- it has not been built or reused for `max_idle_seconds` (callers resolve the
  build path and then start using it within minutes, so an idle build is not
  between resolution and use);
- it is superseded: either another build of the same worktree was used more
  recently, or its source worktree no longer exists;
- no run is using it (its `.bridge-run.lock` is free) and no other prepare is
  working on its worktree (that worktree's `<root_key>.lock` is free).
"""
import fcntl
import os
from pathlib import Path
import plistlib
import shutil
import time

LAST_USED_MARKER = ".last-used"
SOURCE_WORKTREE_FILE = "source-worktree"
TRASH_PREFIX = ".trash-"
DEFAULT_MAX_IDLE_SECONDS = 2 * 60 * 60
# Callers start using a resolved build within minutes; never prune sooner.
MINIMUM_MAX_IDLE_SECONDS = 10 * 60


def mark_used(cache_path: Path) -> None:
    """Record that cache_path was just built or reused."""
    marker = cache_path / LAST_USED_MARKER
    marker.touch(exist_ok=True)
    os.utime(marker)


def last_used(cache_path: Path) -> float:
    try:
        return (cache_path / LAST_USED_MARKER).stat().st_mtime
    except FileNotFoundError:
        return cache_path.stat().st_mtime


def record_source_worktree(cache_path: Path, worktree: Path) -> None:
    """Record the build's worktree before building, so failed builds stay attributable."""
    (cache_path / SOURCE_WORKTREE_FILE).write_text(str(worktree), encoding="utf-8")


def source_worktree(cache_path: Path):
    try:
        return (cache_path / SOURCE_WORKTREE_FILE).read_text(encoding="utf-8").strip() or None
    except OSError:
        pass
    info = cache_path / "DerivedData/Build/Products/Debug/Playhouse.app/Contents/Info.plist"
    try:
        return plistlib.loads(info.read_bytes()).get("PlayhouseSourceWorktree")
    except (OSError, plistlib.InvalidFileException):
        return None


def _lock_is_free(path: Path, keep=None) -> bool:
    """Probe an advisory lock. With `keep`, hold it on success by appending the descriptor."""
    if not path.exists():
        return True
    descriptor = os.open(path, os.O_RDWR)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(descriptor)
        return False
    if keep is None:
        os.close(descriptor)
    else:
        keep.append(descriptor)
    return True


def _size_bytes(path: Path) -> int:
    """Allocated size like `du`: count blocks, and each hard-linked inode once."""
    total, seen = 0, set()
    for directory, _, files in os.walk(path):
        for name in files:
            try:
                info = os.lstat(os.path.join(directory, name))
            except OSError:
                continue
            if (info.st_dev, info.st_ino) in seen:
                continue
            seen.add((info.st_dev, info.st_ino))
            total += info.st_blocks * 512
    return total


def _remove(path: Path) -> None:
    # Rename first so a half-deleted build can never look like a cache entry.
    trash = path.with_name(f"{TRASH_PREFIX}{path.name}")
    os.replace(path, trash)
    shutil.rmtree(trash, ignore_errors=True)


def prune(cache_root: Path, current: Path, now=None, max_idle_seconds=DEFAULT_MAX_IDLE_SECONDS):
    """Remove superseded idle builds; return the removed paths and bytes freed.

    The caller must hold `current`'s worktree lock (`<root_key>.lock`).
    """
    now = time.time() if now is None else now
    current = current.resolve()
    current_key = current.name.split("-", 1)[0]
    removed, freed = [], 0

    groups = {}
    for entry in cache_root.iterdir():
        if not entry.is_dir() or entry.is_symlink():
            continue
        if entry.name.startswith(TRASH_PREFIX):
            # Left behind by an interrupted removal; never in use.
            shutil.rmtree(entry, ignore_errors=True)
            continue
        if "-" not in entry.name:
            continue
        groups.setdefault(entry.name.split("-", 1)[0], []).append(entry)

    for key, builds in groups.items():
        held = []
        try:
            # The current worktree's lock is already held by the caller; other
            # worktrees are skipped while their own prepare is running.
            if key != current_key and not _lock_is_free(cache_root / f"{key}.lock", keep=held):
                continue
            builds.sort(key=last_used, reverse=True)
            newest = builds[0]
            # The key is derived from the worktree path, so every build in a group
            # shares one worktree; any member that records it attributes the rest
            # (including failed builds that never produced an Info.plist).
            worktree = next((w for w in map(source_worktree, builds) if w), None)
            worktree_gone = worktree is not None and not Path(worktree).is_dir()
            for build in builds:
                if build.resolve() == current:
                    continue
                if now - last_used(build) < max_idle_seconds:
                    continue
                if build == newest and not worktree_gone:
                    continue
                # Hold the run lock through removal so a queued run cannot start
                # on this build while it is being measured and deleted.
                if not _lock_is_free(build / "DerivedData/.bridge-run.lock", keep=held):
                    continue
                size = _size_bytes(build)
                _remove(build)
                removed.append(build)
                freed += size
        finally:
            for descriptor in held:
                os.close(descriptor)
    return removed, freed
