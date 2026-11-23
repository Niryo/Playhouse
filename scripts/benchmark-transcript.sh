#!/usr/bin/env bash
# Measures the transcript's reply rendering in a Release build of this worktree's app: opening
# a 200-turn conversation, laying all of it out, scrolling it top to bottom, and streaming a long
# reply at 10, 100 and 200 turns. See Playhouse/App/TranscriptBenchmark.swift for what each number
# means. Each run is a fresh app process; the summary is the median of the runs.
#
# The benchmark is compiled only into this script's build (the PLAYHOUSE_TRANSCRIPT_BENCHMARK
# compilation condition), in its own derived data, never into a shipped app.
#
# Usage: scripts/benchmark-transcript.sh [--runs N] [--out DIR] [--skip-build]
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repository_root}/scripts/app-profile.sh"
playhouse_load_app_profile "${repository_root}"

runs=3
output_directory=""
skip_build=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --runs) runs="${2:?--runs needs a number}"; shift 2 ;;
    --out) output_directory="${2:?--out needs a directory}"; shift 2 ;;
    --skip-build) skip_build=1; shift ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

architecture="$(uname -m)"
derived_data_dir="${PLAYHOUSE_PROFILE_DERIVED_DATA}-TranscriptBenchmark"
app_bundle="${derived_data_dir}/Build/Products/Release/Playhouse.app"
if [[ "${skip_build}" == 0 ]]; then
  xcodebuild build -quiet \
    -project "${repository_root}/Playhouse.xcodeproj" \
    -scheme Playhouse \
    -configuration Release \
    -destination "platform=macOS,arch=${architecture}" \
    -derivedDataPath "${derived_data_dir}" \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGN_IDENTITY=- \
    ARCHS="${architecture}" \
    ONLY_ACTIVE_ARCH=YES \
    PLAYHOUSE_APP_BUNDLE_IDENTIFIER="${PLAYHOUSE_PROFILE_BUNDLE_ID}" \
    SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) PLAYHOUSE_TRANSCRIPT_BENCHMARK'
fi
app_executable="${app_bundle}/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "${app_bundle}/Contents/Info.plist")"

if [[ -z "${output_directory}" ]]; then
  output_directory="$(mktemp -d /tmp/playhouse-transcript-benchmark.XXXXXX)"
fi
mkdir -p "${output_directory}"
playhouse_clear_inherited_bridge_overrides

for ((run = 1; run <= runs; run++)); do
  result="${output_directory}/run-${run}.json"
  rm -f "${result}"
  printf 'Run %d of %d…\n' "${run}" "${runs}" >&2
  # The app opens its own profile's data directory; it refuses any other.
  env -u PLAYHOUSE_DATA_DIRECTORY \
    PLAYHOUSE_MUTE_SOUNDS=1 \
    PLAYHOUSE_TRANSCRIPT_BENCHMARK="${result}" \
    "${app_executable}" >/dev/null 2>&1 &
  app_pid=$!
  for ((waited = 0; waited < 600; waited++)); do
    kill -0 "${app_pid}" 2>/dev/null || break
    sleep 1
  done
  if kill -0 "${app_pid}" 2>/dev/null; then
    kill "${app_pid}" 2>/dev/null || true
    printf 'Run %d did not finish within 10 minutes.\n' "${run}" >&2
    exit 1
  fi
  wait "${app_pid}" || true
  [[ -s "${result}" ]] || { printf 'Run %d wrote no results.\n' "${run}" >&2; exit 1; }
done
pkill -f "${app_bundle}/Contents/MacOS/playhouse-daemon" 2>/dev/null || true

python3 - "${output_directory}" "${runs}" <<'PY'
import json, statistics, sys
directory, runs = sys.argv[1], int(sys.argv[2])
results = [json.load(open(f"{directory}/run-{run}.json")) for run in range(1, runs + 1)]

def flatten(value, prefix=""):
    if isinstance(value, dict):
        for key, inner in value.items():
            yield from flatten(inner, f"{prefix}.{key}" if prefix else key)
    elif isinstance(value, (int, float)):
        yield prefix, float(value)

columns = {}
for result in results:
    for key, value in flatten(result):
        columns.setdefault(key, []).append(value)
summary = {key: statistics.median(values) for key, values in columns.items()}
json.dump({"runs": results, "median": summary}, open(f"{directory}/summary.json", "w"), indent=2, sort_keys=True)

rows = [
    ("Open: first screen (ms)", "openFirstScreenMs"),
    ("Open: first screen, main-thread CPU (ms)", "openFirstScreenCPUms"),
    ("Lay out all 200 turns (ms)", "fullLayoutMs"),
    ("Lay out all 200 turns, main-thread CPU (ms)", "fullLayoutCPUms"),
    ("Footprint after full layout (MB)", "afterFullLayoutFootprintMB"),
    ("Peak footprint (MB)", "peakFootprintMB"),
    ("Scroll: main-thread busy (ms)", "scroll.mainThreadBusyMs"),
    ("Scroll: main-thread CPU (ms)", "scroll.mainThreadCPUms"),
    ("Scroll: frame work median (ms)", "scroll.frameWork.median"),
    ("Scroll: frame work p95 (ms)", "scroll.frameWork.p95"),
    ("Scroll: hitches over 16.7 ms (count)", "scroll.hitchCount"),
    ("Scroll: hitches over 33.3 ms (count)", "scroll.severeHitchCount"),
    ("Scroll: time over budget (ms)", "scroll.hitchTimeMs"),
    ("Scroll: longest frame (ms)", "scroll.longestFrameMs"),
]
for turns in ("10", "100", "200"):
    rows.append((f"Streaming at {turns} turns: median per update (ms)", f"streaming.{turns}.median"))
    rows.append((f"Streaming at {turns} turns: p95 per update (ms)", f"streaming.{turns}.p95"))
    rows.append((f"Streaming at {turns} turns: main-thread CPU per update (ms)", f"streaming.{turns}-cpuPerUpdateMs"))
print(f"Results in {directory} (median of {runs} runs)")
print("| Metric | Value |")
print("| --- | ---: |")
for label, key in rows:
    if key in summary:
        print(f"| {label} | {summary[key]:.1f} |")
PY
