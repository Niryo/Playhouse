#!/usr/bin/env python3
"""Exercise test-artifact pruning against real directories, and its runner wiring."""
from datetime import datetime, timedelta, timezone
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

root = Path(__file__).resolve().parent.parent
helper = root / "scripts/prune-test-artifacts.py"

# Both runners must prune, and a passing headless run must drop its own artifacts.
e2e_runner = (root / "scripts/test-e2e.sh").read_text()
assert "prune-test-artifacts.py" in e2e_runner and "--prefix playhouse-bridge." in e2e_runner
assert 'rm -rf -- "${test_output_dir}"' in e2e_runner and "PLAYHOUSE_E2E_KEEP_ARTIFACTS" in e2e_runner
tart_runner = (root / "scripts/test-ui-tart.sh").read_text()
assert '--root "$artifact_root" --age-from run-id --keep "$run_id"' in tart_runner
# Run-id aging parses this exact format; a changed format would silently stop pruning.
assert 'run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"' in tart_runner


def prune(directory, *arguments, retention="1"):
    environment = {**os.environ, "PLAYHOUSE_TEST_ARTIFACT_RETENTION_HOURS": retention}
    return subprocess.run(
        [sys.executable, str(helper), "--root", str(directory), *arguments],
        capture_output=True, text=True, timeout=30, env=environment,
    )


def make(path, age_hours=0):
    path.mkdir()
    (path / "artifact.log").write_text("artifact\n", encoding="utf-8")
    stamp = time.time() - age_hours * 3600
    os.utime(path, (stamp, stamp))
    return path


with tempfile.TemporaryDirectory(prefix="playhouse-prune-check-") as directory:
    base = Path(directory)

    # mtime mode: only stale, owned, prefixed, non-kept directories go.
    bridge = base / "bridge"
    bridge.mkdir()
    stale = make(bridge / "playhouse-bridge.stale1", age_hours=3)
    fresh = make(bridge / "playhouse-bridge.fresh1")
    current = make(bridge / "playhouse-bridge.current", age_hours=3)
    unrelated = make(bridge / "playhouse-bridge-workspaces", age_hours=3)
    sockets = make(bridge / "other-tool.stale", age_hours=3)
    target = make(base / "symlink-target", age_hours=3)
    link = bridge / "playhouse-bridge.link"
    link.symlink_to(target, target_is_directory=True)
    os.utime(link, (time.time() - 3 * 3600,) * 2, follow_symlinks=False)
    stale_file = bridge / "playhouse-bridge.file"
    stale_file.write_text("file\n", encoding="utf-8")
    os.utime(stale_file, (time.time() - 3 * 3600,) * 2)
    result = prune(bridge, "--prefix", "playhouse-bridge.", "--age-from", "mtime", "--keep", current.name)
    assert result.returncode == 0, result.stderr
    assert not stale.exists(), "A stale run directory was not pruned"
    assert fresh.is_dir() and current.is_dir(), "A fresh or current run directory was pruned"
    assert unrelated.is_dir() and sockets.is_dir(), "A directory outside the prefix was pruned"
    assert link.is_symlink() and (target / "artifact.log").is_file(), "A symlink or its target was pruned"
    assert stale_file.is_file(), "A plain file was pruned"
    assert "Pruned 1 test artifact directory" in result.stderr, result.stderr

    # run-id mode ages by the timestamp in the name; mtime is ignored.
    runs = base / "runs"
    runs.mkdir()
    now = datetime.now(timezone.utc)
    name = lambda moment, pid: f"{moment.strftime('%Y%m%dT%H%M%SZ')}-{pid}"
    old_run = make(runs / name(now - timedelta(hours=3), 101))
    new_run = make(runs / name(now - timedelta(minutes=5), 102), age_hours=3)
    kept_run = make(runs / name(now - timedelta(hours=3), 103))
    odd_name = make(runs / "not-a-run-id", age_hours=3)
    impossible_time = make(runs / "20261399T000000Z-105", age_hours=3)
    result = prune(runs, "--age-from", "run-id", "--keep", kept_run.name)
    assert result.returncode == 0, result.stderr
    assert not old_run.exists(), "A stale UI run was not pruned"
    assert new_run.is_dir() and kept_run.is_dir() and odd_name.is_dir(), "A fresh, current or unrecognised entry was pruned"
    assert impossible_time.is_dir(), "An entry with an invalid run-id time was pruned"

    # A missing root is nothing to do; a bad retention is refused before touching anything.
    assert prune(base / "missing", "--age-from", "mtime").returncode == 0
    doomed = make(runs / name(now - timedelta(hours=3), 104))
    for invalid in ["0", "-2", "soon"]:
        refused = prune(runs, "--age-from", "run-id", retention=invalid)
        assert refused.returncode != 0 and "PLAYHOUSE_TEST_ARTIFACT_RETENTION_HOURS" in refused.stderr, refused.stderr
    assert doomed.is_dir(), "An invalid retention still pruned"

print("Test artifact pruning check passed.")
