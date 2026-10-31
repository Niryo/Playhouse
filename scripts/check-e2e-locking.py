#!/usr/bin/env python3
"""Exercise real advisory-lock ownership, contention, and process cleanup."""
import fcntl
import json
from pathlib import Path
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
assert "with-e2e-lock.sh" in (root / "scripts/test-ui-tart.sh").read_text()
assert "with-e2e-lock.sh" not in (root / "scripts/playhouse.sh").read_text()
assert "with-e2e-lock.sh" not in (root / "scripts/test-codex-integration.sh").read_text()

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
    failed = subprocess.run(
        [sys.executable, str(helper), str(lock), str(Path(directory) / "missing-command")],
        capture_output=True, text=True, timeout=5,
    )
    assert failed.returncode == 127
    with lock.open("r+") as probe:
        fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)

print("E2E locking checks passed: ownership, contention, independent locks, release, exec failure.")
