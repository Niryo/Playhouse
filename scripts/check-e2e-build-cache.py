#!/usr/bin/env python3
"""Exercise E2E build cache pruning on real directories and real advisory locks."""
import fcntl
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(root / "scripts"))
import e2e_build_cache  # noqa: E402

# prepare-e2e-build.py must record use and prune under its worktree lock.
prepare = (root / "scripts/prepare-e2e-build.py").read_text()
assert "e2e_build_cache.mark_used(cache_path)" in prepare
assert "e2e_build_cache.prune(" in prepare
assert prepare.index("e2e_build_cache.prune(") > prepare.index("fcntl.flock(lock_file, fcntl.LOCK_EX)")
# The worktree is recorded before xcodebuild so a failed build stays attributable.
assert prepare.index("e2e_build_cache.record_source_worktree(cache_path, root)") < prepare.index('"xcodebuild", "build-for-testing"')
assert "check-e2e-build-cache.py" in (root / "scripts/test-e2e.sh").read_text()

NOW = 1_000_000_000.0
HOUR = 3600.0


def make_build(cache_root, key, fingerprint, worktree, last_used, with_app=True, record=False):
    build = cache_root / f"{key}-{fingerprint}"
    derived = build / "DerivedData"
    derived.mkdir(parents=True)
    if record:
        e2e_build_cache.record_source_worktree(build, worktree)
    (derived / "payload.bin").write_bytes(b"x" * 4096)
    if with_app:
        info = derived / "Build/Products/Debug/Playhouse.app/Contents/Info.plist"
        info.parent.mkdir(parents=True)
        info.write_bytes(plistlib.dumps({"PlayhouseSourceWorktree": str(worktree)}))
    marker = build / e2e_build_cache.LAST_USED_MARKER
    marker.touch()
    os.utime(marker, (last_used, last_used))
    return build


def hold_lock(path):
    """Hold an exclusive flock on path from a real child process until released."""
    path.touch()
    child = subprocess.Popen(
        [sys.executable, "-c",
         "import fcntl, sys; f = open(sys.argv[1], 'a+'); fcntl.flock(f, fcntl.LOCK_EX); "
         "print('ready', flush=True); sys.stdin.read()", str(path)],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
    )
    assert child.stdout.readline().strip() == "ready"
    return child


def release(child):
    child.stdin.close()
    child.wait(timeout=5)


with tempfile.TemporaryDirectory(prefix="playhouse-build-cache-check-") as directory:
    base = Path(directory)
    cache_root = base / "cache"
    cache_root.mkdir()
    live_worktree = base / "live-worktree"
    live_worktree.mkdir()
    busy_worktree = base / "busy-worktree"
    busy_worktree.mkdir()
    gone_worktree = base / "gone-worktree"  # never created

    # Current worktree "aaaa": the build in use is old but must survive.
    current = make_build(cache_root, "aaaa", "f0", live_worktree, NOW - 10 * HOUR)
    superseded_idle = make_build(cache_root, "aaaa", "f1", live_worktree, NOW - 3 * HOUR)
    superseded_recent = make_build(cache_root, "aaaa", "f2", live_worktree, NOW - 0.5 * HOUR)
    superseded_failed = make_build(cache_root, "aaaa", "f3", live_worktree, NOW - 5 * HOUR, with_app=False)
    superseded_running = make_build(cache_root, "aaaa", "f4", live_worktree, NOW - 4 * HOUR)
    # Another live worktree: its newest idle build is kept for reuse.
    other_newest = make_build(cache_root, "bbbb", "f0", live_worktree, NOW - 6 * HOUR)
    other_older = make_build(cache_root, "bbbb", "f1", live_worktree, NOW - 7 * HOUR)
    # A deleted worktree: even its newest idle build goes.
    gone_newest = make_build(cache_root, "cccc", "f0", gone_worktree, NOW - 3 * HOUR)
    # Deleted worktrees whose newest build failed (no Info.plist): attributed by
    # the recorded source-worktree file, or by a sibling build of the same key.
    failed_recorded = make_build(cache_root, "ffff", "f0", gone_worktree, NOW - 3 * HOUR, with_app=False, record=True)
    failed_unrecorded = make_build(cache_root, "gggg", "f1", gone_worktree, NOW - 3 * HOUR, with_app=False)
    sibling_with_app = make_build(cache_root, "gggg", "f0", gone_worktree, NOW - 4 * HOUR)
    # A failed build of a live worktree that is still its newest is kept.
    live_failed = make_build(cache_root, "hhhh", "f0", live_worktree, NOW - 3 * HOUR, with_app=False, record=True)
    # A worktree whose prepare is running: its whole group is left alone.
    busy_older = make_build(cache_root, "dddd", "f0", busy_worktree, NOW - 9 * HOUR)
    make_build(cache_root, "dddd", "f1", busy_worktree, NOW - 8 * HOUR)
    # An interrupted earlier removal.
    trash = cache_root / f"{e2e_build_cache.TRASH_PREFIX}eeee-f0"
    (trash / "DerivedData").mkdir(parents=True)
    # Lock files sit beside the builds and must be ignored as entries.
    for key in ("aaaa", "bbbb", "cccc"):
        (cache_root / f"{key}.lock").touch()

    run_lock = hold_lock(superseded_running / "DerivedData/.bridge-run.lock")
    prepare_lock = hold_lock(cache_root / "dddd.lock")
    # Like prepare-e2e-build.py, prune while this process holds the current
    # worktree's lock through its own open file; prune must not skip that group.
    own_lock = (cache_root / "aaaa.lock").open("a+")
    fcntl.flock(own_lock, fcntl.LOCK_EX)
    try:
        removed, freed = e2e_build_cache.prune(cache_root, current, now=NOW, max_idle_seconds=2 * HOUR)
    finally:
        release(run_lock)
        release(prepare_lock)

    expected_removed = {
        superseded_idle, superseded_failed, other_older, gone_newest,
        failed_recorded, failed_unrecorded, sibling_with_app,
    }
    assert set(removed) == expected_removed, sorted(p.name for p in removed)
    assert freed >= len(expected_removed) * 4096, freed
    for path in expected_removed:
        assert not path.exists(), path
    for path in (current, superseded_recent, superseded_running, other_newest, busy_older, live_failed):
        assert path.is_dir(), f"{path} should have been kept"
    assert not trash.exists()
    assert all((cache_root / f"{key}.lock").exists() for key in ("aaaa", "bbbb", "cccc", "dddd"))
    assert not any(entry.name.startswith(e2e_build_cache.TRASH_PREFIX) for entry in cache_root.iterdir())

    # Once the run and the other prepare end, their superseded builds go next time.
    removed, _ = e2e_build_cache.prune(cache_root, current, now=NOW, max_idle_seconds=2 * HOUR)
    assert set(removed) == {superseded_running, busy_older}, sorted(p.name for p in removed)
    own_lock.close()

    # mark_used refreshes the idle clock so a just-used build is protected.
    e2e_build_cache.mark_used(other_newest)
    assert e2e_build_cache.last_used(other_newest) > NOW

print("E2E build cache pruning checks passed.")
