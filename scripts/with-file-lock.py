#!/usr/bin/env python3
"""Run a command under an advisory lock with queue/holder diagnostics."""
import datetime
import fcntl
import json
import os
import sys
import time

if len(sys.argv) < 3:
    raise SystemExit("Usage: with-file-lock.py <lock-path> <command> [args...]")

lock_path, *command = sys.argv[1:]
descriptor = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
started = time.monotonic()
queued_at = datetime.datetime.now(datetime.timezone.utc).isoformat()
next_wait_report = started
timeout_value = os.environ.get("STATIONAI_UI_LOCK_TIMEOUT_SECONDS")
wait_timeout = float(timeout_value) if timeout_value else None
while True:
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        break
    except BlockingIOError:
        now = time.monotonic()
        if wait_timeout is not None and now - started >= wait_timeout:
            holder = os.pread(descriptor, 4096, 0).decode("utf-8", errors="replace")
            print(
                f"Lock wait timed out path={lock_path} queued_at={queued_at} "
                f"wait_seconds={now - started:.3f} holder={holder or 'unknown (older wrapper)'}",
                file=sys.stderr,
                flush=True,
            )
            os.close(descriptor)
            raise SystemExit(124)
        if now >= next_wait_report:
            holder = os.pread(descriptor, 4096, 0).decode("utf-8", errors="replace")
            print(
                f"Lock waiting path={lock_path} queued_at={queued_at} "
                f"wait_seconds={now - started:.3f} "
                f"holder={holder or 'unknown (older wrapper)'}; retrying every 0.1 seconds.",
                file=sys.stderr, flush=True,
            )
            next_wait_report = now + 20
        time.sleep(0.1)

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
