#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
lock_path="${repository_root}/.e2e.lock"

if (($# == 0)); then
  printf 'Usage: %s -- <command> [args...]\n' "$0" >&2
  exit 2
fi

if [[ "$1" == "--" ]]; then
  shift
fi

if (($# == 0)); then
  printf 'Usage: %s -- <command> [args...]\n' "$0" >&2
  exit 2
fi

python3 - "$lock_path" "$@" <<'PY'
import fcntl
import os
import sys
import time

lock_path, *command = sys.argv[1:]
lock_fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)

while True:
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        break
    except BlockingIOError:
        print(
            "Another app/E2E verification session is active; waiting 20 seconds before retrying.",
            file=sys.stderr,
            flush=True,
        )
        time.sleep(20)

# Keep the descriptor open through exec. The OS releases the lock when the
# command exits, including when it is interrupted or terminated.
os.set_inheritable(lock_fd, True)
try:
    os.execvp(command[0], command)
except OSError as error:
    print(f"Could not start {command[0]!r}: {error}", file=sys.stderr)
    os.close(lock_fd)
    sys.exit(127)
PY
