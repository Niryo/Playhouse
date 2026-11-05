#!/usr/bin/env python3
"""Exercise real advisory-lock ownership, contention, and process cleanup."""
import fcntl
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time

root = Path(__file__).resolve().parent.parent
helper = root / "scripts/with-file-lock.py"
# Catch accidental restoration of global serialization in the headless entrypoint.
runner = (root / "scripts/test-e2e.sh").read_text()
assert "with-e2e-lock.sh" not in runner
assert ".bridge-run.lock" in runner
tart_runner = (root / "scripts/test-ui-tart.sh").read_text()
assert "with-e2e-lock.sh" in tart_runner
assert "with-e2e-lock.sh" not in (root / "scripts/playhouse.sh").read_text()
assert "with-e2e-lock.sh" not in (root / "scripts/test-codex-integration.sh").read_text()
# A kept-alive VM must stay checkout-agnostic, so nothing bound into it or
# recorded about it may derive from the host checkout path or the login session.
# The guest's SourceSnapshot path is deliberately fixed and shared: test-ui.sh
# keys reusable DerivedData off it, and it is identical for every checkout.
assert "session_marker" not in tart_runner
assert 'PLAYHOUSE_UI_TART_ARTIFACTS:-/tmp/playhouse-ui-tart-artifacts' in tart_runner
assert 'source_snapshot_root="${HOME}/PlayhouseUITestRuns/SourceSnapshot"' in tart_runner
# The VM may only be bound to the checkout-agnostic artifact share.
mounts = re.findall(r'--dir[= ]"?([^:"\s]+):', tart_runner)
assert mounts == ["artifacts"], f"Unexpected Tart directory shares: {mounts}"
assert '[[ ! -O "$artifact_root" ]]' in tart_runner and 'chmod 700 "$artifact_root"' in tart_runner
# A reused VM must prove it shares this run's artifact root before it is trusted.
assert '/bin/test -d "/Volumes/My Shared Files/artifacts/${run_id}"' in tart_runner

with tempfile.TemporaryDirectory(prefix="playhouse-lock-check-") as directory:
    lock = Path(directory) / "session.lock"
    # Real child holds the lock until its stdin closes; no app or test doubles.
    child = subprocess.Popen(
        [sys.executable, str(helper), str(lock), sys.executable, "-c",
         "import sys; print('ready', flush=True); sys.stdin.read()"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )
    try:
        assert child.stdout.readline().strip() == "ready"
        metadata = json.loads(lock.read_text())
        assert metadata["pid"] == child.pid
        with lock.open("r+") as probe:
            try:
                fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                pass
            else:
                raise AssertionError("Exec child did not retain the lock")
        independent = subprocess.run(
            [sys.executable, str(helper), str(Path(directory) / "other.lock"),
             sys.executable, "-c", "pass"], capture_output=True, text=True, timeout=5,
        )
        assert independent.returncode == 0
        assert "wait_seconds=" in independent.stderr
        waiter = subprocess.Popen(
            [sys.executable, str(helper), str(lock), sys.executable, "-c", "pass"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        try:
            waiting = waiter.stderr.readline()
            assert "Lock waiting" in waiting and str(child.pid) in waiting
            released_at = time.monotonic()
            child.communicate("", timeout=5)
            _, acquired = waiter.communicate(timeout=3)
            handoff_seconds = time.monotonic() - released_at
            assert handoff_seconds < 3, f"Lock handoff took {handoff_seconds:.3f}s"
            print(f"Lock release-to-completion: {handoff_seconds:.3f}s")
            assert waiter.returncode == 0 and "Lock acquired" in acquired
        finally:
            if waiter.poll() is None:
                waiter.kill()
                waiter.wait()
    finally:
        if child.poll() is None:
            child.kill()
            child.wait()
    with lock.open("r+") as probe:
        fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)

    # A hard-killed holder must still release: the kernel drops the flock with
    # the holder's descriptor table, so no cooperative cleanup is involved.
    killed = subprocess.Popen(
        [sys.executable, str(helper), str(lock), sys.executable, "-c",
         "import sys; print('ready', flush=True); sys.stdin.read()"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )
    assert killed.stdout.readline().strip() == "ready"
    successor = subprocess.Popen(
        [sys.executable, str(helper), str(lock), sys.executable, "-c", "pass"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )
    try:
        assert "Lock waiting" in successor.stderr.readline()
        killed.kill()
        killed.wait(timeout=5)
        _, after_kill = successor.communicate(timeout=5)
        assert successor.returncode == 0, "Waiter did not inherit a killed holder's lock"
        assert "Lock acquired" in after_kill
    finally:
        for process in (killed, successor):
            if process.poll() is None:
                process.kill()
                process.wait()

    # A waiter that exceeds its timeout exits 124 and leaves the holder alone.
    # The timeout is deliberately not a multiple of the reporting interval: the
    # deadline must be honoured on its own tick, not on the one after it.
    holder = subprocess.Popen(
        [sys.executable, str(helper), str(lock), sys.executable, "-c",
         "import sys; print('ready', flush=True); sys.stdin.read()"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )
    try:
        assert holder.stdout.readline().strip() == "ready"
        timeout_started = time.monotonic()
        timed_out = subprocess.run(
            [sys.executable, str(helper), str(lock), sys.executable, "-c", "pass"],
            capture_output=True, text=True, timeout=30,
            env={
                **os.environ,
                "PLAYHOUSE_UI_LOCK_TIMEOUT_SECONDS": "1.2",
                "PLAYHOUSE_LOCK_WAIT_REPORT_SECONDS": "0.5",
            },
        )
        timeout_elapsed = time.monotonic() - timeout_started
        assert timed_out.returncode == 124, timed_out.stderr
        assert "Lock wait timed out" in timed_out.stderr
        assert "Lock acquired" not in timed_out.stderr
        # Assert on the waiter's own measurement rather than wall clock, which
        # would also carry interpreter startup and flake under load. Re-arming
        # against the deadline gives ~1.2s here; ticking past it gives ~1.5s.
        reported_wait = float(
            re.search(r"Lock wait timed out .*?wait_seconds=([0-9.]+)", timed_out.stderr).group(1)
        )
        assert reported_wait < 1.35, (
            f"Timeout overshot its deadline by waiting {reported_wait:.3f}s; "
            "the interval timer is not re-armed against the deadline."
        )
        assert timeout_elapsed < 5, f"Waiter took {timeout_elapsed:.3f}s to exit"
        # Several reports before the deadline prove the periodic tick re-arms.
        assert timed_out.stderr.count("Lock waiting") >= 3, timed_out.stderr
        assert holder.poll() is None, "Timed-out waiter disturbed the lock holder"
        with lock.open("r+") as probe:
            try:
                fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                pass
            else:
                raise AssertionError("Holder lost the lock to a timed-out waiter")
    finally:
        if holder.poll() is None:
            holder.kill()
            holder.wait()

    for bad_interval in ("0", "-1", "soon", "inf"):
        rejected = subprocess.run(
            [sys.executable, str(helper), str(lock), sys.executable, "-c", "pass"],
            capture_output=True, text=True, timeout=5,
            env={**os.environ, "PLAYHOUSE_LOCK_WAIT_REPORT_SECONDS": bad_interval},
        )
        assert rejected.returncode != 0 and "Traceback" not in rejected.stderr, rejected.stderr
        assert "must be a positive number" in rejected.stderr

    failed = subprocess.run(
        [sys.executable, str(helper), str(lock), str(Path(directory) / "missing-command")],
        capture_output=True, text=True, timeout=5,
    )
    assert failed.returncode == 127
    with lock.open("r+") as probe:
        fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)

print(
    "E2E locking checks passed: ownership, contention, independent locks, release, "
    "killed-holder handoff, wait timeout, exec failure, checkout-agnostic VM wiring."
)
