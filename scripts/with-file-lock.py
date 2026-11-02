#!/usr/bin/env python3
"""Run a command under an advisory lock with queue/holder diagnostics."""
import datetime
import fcntl
import json
import math
import os
import signal
import sys
import time

# Lowered by the lock tests to exercise several report ticks quickly.
report_value = os.environ.get("PLAYHOUSE_LOCK_WAIT_REPORT_SECONDS", "20")
try:
    WAIT_REPORT_INTERVAL_SECONDS = float(report_value)
except ValueError:
    WAIT_REPORT_INTERVAL_SECONDS = 0.0
if not (WAIT_REPORT_INTERVAL_SECONDS > 0 and math.isfinite(WAIT_REPORT_INTERVAL_SECONDS)):
    raise SystemExit(
        f"PLAYHOUSE_LOCK_WAIT_REPORT_SECONDS must be a positive number, got {report_value!r}"
    )

if len(sys.argv) < 3:
    raise SystemExit("Usage: with-file-lock.py <lock-path> <command> [args...]")

lock_path, *command = sys.argv[1:]
descriptor = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
started = time.monotonic()
queued_at = datetime.datetime.now(datetime.timezone.utc).isoformat()
timeout_value = os.environ.get("PLAYHOUSE_UI_LOCK_TIMEOUT_SECONDS")
wait_timeout = float(timeout_value) if timeout_value else None


class LockWaitTimeout(Exception):
    pass


def read_holder():
    holder = os.pread(descriptor, 4096, 0).decode("utf-8", errors="replace")
    return holder or "unknown (older wrapper)"


def print_wait(waited):
    print(
        f"Lock waiting path={lock_path} queued_at={queued_at} "
        f"wait_seconds={waited:.3f} holder={read_holder()}; waiting for release.",
        file=sys.stderr, flush=True,
    )


def next_alarm(waited):
    # Re-armed per tick so a timeout that is not a multiple of the reporting
    # interval still fires at its deadline instead of on the following tick.
    interval = WAIT_REPORT_INTERVAL_SECONDS
    if wait_timeout is not None:
        interval = min(interval, wait_timeout - waited)
    return max(interval, 0.001)


def report_wait(_signal_number, _frame):
    # Raising escapes the blocking flock below; returning lets PEP 475 restart
    # it transparently, so the wait stays in the kernel and never polls.
    if acquired:
        return
    waited = time.monotonic() - started
    if wait_timeout is not None and waited >= wait_timeout:
        raise LockWaitTimeout
    print_wait(waited)
    signal.setitimer(signal.ITIMER_REAL, next_alarm(waited))


acquired = False
try:
    fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
    acquired = True
except BlockingIOError:
    # Report contention before blocking, then let the kernel hold the wait and
    # use a one-shot timer, re-armed per tick, to refresh diagnostics and to
    # enforce the timeout.
    print_wait(time.monotonic() - started)
    signal.signal(signal.SIGALRM, report_wait)
    try:
        signal.setitimer(signal.ITIMER_REAL, next_alarm(time.monotonic() - started))
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        # A tick landing between flock returning and this line can still report
        # a timeout for a lock that was just granted; the exit closes the
        # descriptor, so the cost is one spurious exit 124, never a stuck lock.
        acquired = True
    except LockWaitTimeout:
        signal.setitimer(signal.ITIMER_REAL, 0)
        print(
            f"Lock wait timed out path={lock_path} queued_at={queued_at} "
            f"wait_seconds={time.monotonic() - started:.3f} holder={read_holder()}",
            file=sys.stderr,
            flush=True,
        )
        os.close(descriptor)
        raise SystemExit(124)
    finally:
        # Disarm before restoring the default disposition so a tick that is
        # already pending cannot kill the process now that the lock is held.
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, signal.SIG_IGN)
    signal.signal(signal.SIGALRM, signal.SIG_DFL)

holder = {
    "pid": os.getpid(),
    "command": os.path.basename(command[0]),
    "cwd": os.getcwd(),
    "acquired_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
}
# Only the lock owner writes metadata; leftover metadata is not proof of a lock.
# Do not record arguments: they may contain prompts or credentials.
os.ftruncate(descriptor, 0)
os.write(descriptor, json.dumps(holder).encode())
print(
    f"Lock acquired path={lock_path} queued_at={queued_at} "
    f"wait_seconds={time.monotonic() - started:.3f} holder={json.dumps(holder)}",
    file=sys.stderr, flush=True,
)
os.set_inheritable(descriptor, True)
try:
    os.execvp(command[0], command)
except OSError as error:
    print(f"Could not start {command[0]!r}: {error}", file=sys.stderr)
    os.close(descriptor)
    sys.exit(127)
