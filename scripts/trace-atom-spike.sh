#!/usr/bin/env bash
# Records an Instruments trace of one atom-tree spike benchmark run (docs/atom-tree-performance.md).
# Launches the Release benchmark app the way scripts/benchmark-atom-spike.sh does and attaches
# `xctrace record` to it (Playhouse doesn't run when xctrace launches it itself).
#
# Usage: scripts/trace-atom-spike.sh --benchmark task-item|transcript --variant V --scenario S
#          --template "Time Profiler"|SwiftUI|"Animation Hitches"|Allocations --out FILE.trace [--seconds N]
# Build the app first with scripts/benchmark-atom-spike.sh.
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repository_root}/scripts/app-profile.sh"
playhouse_load_app_profile "${repository_root}"

benchmark=task-item
variant=native
scenario=board-500
template="Time Profiler"
output=""
seconds=40
while [[ $# -gt 0 ]]; do
  case "$1" in
    --benchmark) benchmark="${2:?}"; shift 2 ;;
    --variant) variant="${2:?}"; shift 2 ;;
    --scenario) scenario="${2:?}"; shift 2 ;;
    --template) template="${2:?}"; shift 2 ;;
    --out) output="${2:?}"; shift 2 ;;
    --seconds) seconds="${2:?}"; shift 2 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done
[[ -n "${output}" ]] || { printf 'Pass --out FILE.trace\n' >&2; exit 2; }

case "${benchmark}" in
  task-item) app_bundle="${PLAYHOUSE_PROFILE_DERIVED_DATA}-AtomBenchmark/Build/Products/Release/Playhouse.app"; prefix=PLAYHOUSE_TASK_ITEM_BENCHMARK ;;
  transcript) app_bundle="${PLAYHOUSE_PROFILE_DERIVED_DATA}-AtomBenchmark/Build/Products/Release/Playhouse.app"; prefix=PLAYHOUSE_TRANSCRIPT_TREE_BENCHMARK ;;
  *) printf 'Unknown benchmark: %s\n' "${benchmark}" >&2; exit 2 ;;
esac
app_executable="${app_bundle}/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "${app_bundle}/Contents/Info.plist")"
playhouse_clear_inherited_bridge_overrides

result="${output%.trace}.json"
rm -rf "${output}" "${result}"
mkdir -p "$(dirname "${output}")"
env -u PLAYHOUSE_DATA_DIRECTORY \
  PLAYHOUSE_MUTE_SOUNDS=1 \
  "${prefix}=${result}" \
  "${prefix}_VARIANT=${variant}" \
  "${prefix}_SCENARIO=${scenario}" \
  "${app_executable}" >/dev/null 2>&1 &
app_pid=$!
# The benchmark waits two seconds after launch before it starts.
sleep 1
xcrun xctrace record --template "${template}" --attach "${app_pid}" --time-limit "${seconds}s" --output "${output}" >/dev/null 2>&1 || true
for ((waited = 0; waited < 300; waited++)); do
  kill -0 "${app_pid}" 2>/dev/null || break
  sleep 1
done
kill "${app_pid}" 2>/dev/null || true
pkill -f "${app_bundle}/Contents/MacOS/playhouse-daemon" 2>/dev/null || true
[[ -d "${output}" ]] || { printf 'No trace was saved.\n' >&2; exit 1; }
printf '%s\n' "${output}"
