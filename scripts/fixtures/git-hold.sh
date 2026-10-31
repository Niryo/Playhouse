#!/bin/sh
# Real Git with a parking brake for one repository. scripts/test-ui.sh stages this
# as an executable named `git`; a UI case puts its directory first on the app's PATH.
#
# While `<this dir>/hold` names a repository (its real path), every call made with
# `-C <that repository>` waits here, touching `<this dir>/hold.waiting` so the test
# knows one is parked. Everything else, and every call once the hold file is gone,
# runs the real Git unchanged. This lets a case hold the app's repository validation
# until a concurrent change lands, without relying on a blocked Git seeing FIFO
# end-of-file (which one run left hanging).
set -eu

here=$(cd "$(dirname "$0")" && pwd -P)
hold="$here/hold"

if [ -f "$hold" ] && [ "${1:-}" = "-C" ] && [ -d "${2:-}" ]; then
  # Both sides as real paths: callers may say /tmp/... or /private/tmp/...
  held=$(cd "$(cat "$hold")" 2>/dev/null && pwd -P || cat "$hold")
  target=$(cd "$2" && pwd -P)
  if [ "$target" = "$held" ]; then
    while [ -f "$hold" ]; do
      : > "$hold.waiting"
      sleep 0.02
    done
  fi
fi

# The real Git is the next `git` on PATH that isn't this wrapper.
IFS=:
for dir in $PATH; do
  [ -z "$dir" ] && continue
  candidate="$dir/git"
  [ -x "$candidate" ] || continue
  [ "$candidate" -ef "$0" ] && continue
  exec "$candidate" "$@"
done
exec /usr/bin/git "$@"
