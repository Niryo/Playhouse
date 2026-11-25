#!/usr/bin/env bash
# Measures the atom-tree renderer in a Release build of this worktree's app: opening a board of
# 300 card-like atom trees, streaming updates into 10 of them, updating all of them, scrolling a
# lazy 500-card list, and the same streaming on a board built with native typed props. See
# Playhouse/App/Plugins/Renderer/AtomTreeBenchmark.swift for what each number means. Each run is
# a fresh app process; the summary is the median of the runs.
#
# The benchmark is compiled only into this script's build (the PLAYHOUSE_ATOM_BENCHMARK
# compilation condition), in its own derived data, never into a shipped app.
#
# Usage: scripts/benchmark-atom-tree.sh [--runs N] [--out DIR] [--skip-build]
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repository_root}/scripts/app-profile.sh"
playhouse_load_app_profile "${repository_root}"

runs=5
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
derived_data_dir="${PLAYHOUSE_PROFILE_DERIVED_DATA}-AtomBenchmark"
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
    SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) PLAYHOUSE_ATOM_BENCHMARK'
fi
app_executable="${app_bundle}/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "${app_bundle}/Contents/Info.plist")"

if [[ -z "${output_directory}" ]]; then
  output_directory="$(mktemp -d /tmp/playhouse-atom-benchmark.XXXXXX)"
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
    PLAYHOUSE_ATOM_BENCHMARK="${result}" \
    "${app_executable}" >/dev/null 2>&1 &
  app_pid=$!
  for ((waited = 0; waited < 300; waited++)); do
    kill -0 "${app_pid}" 2>/dev/null || break
    sleep 1
  done
  if kill -0 "${app_pid}" 2>/dev/null; then
    kill "${app_pid}" 2>/dev/null || true
    printf 'Run %d did not finish within 5 minutes.\n' "${run}" >&2
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
errors = [result["error"] for result in results if "error" in result]
if errors:
    sys.exit("Benchmark failed: " + "; ".join(errors))

def flatten(value, prefix=""):
    if isinstance(value, dict):
        for key, inner in value.items():
            yield from flatten(inner, f"{prefix}.{key}" if prefix else key)
    elif isinstance(value, (int, float)) and not isinstance(value, bool):
        yield prefix, float(value)

columns = {}
for result in results:
    for key, value in flatten(result):
        columns.setdefault(key, []).append(value)
summary = {key: statistics.median(values) for key, values in columns.items()}
json.dump({"runs": results, "median": summary}, open(f"{directory}/summary.json", "w"), indent=2, sort_keys=True)

rows = [
    ("Open 300 cards: total (ms)", "open.totalMs"),
    ("Open 300 cards: applying the ops (ms)", "open.applyMs"),
    ("Open 300 cards: main-thread CPU (ms)", "open.cpuMs"),
    ("Open 300 cards: prop decodes", "open.decodes"),
    ("Open 300 cards: atom body evaluations", "open.bodies"),
]
for phase, label in (("streaming", "Streaming (10 cards change)"), ("allCards", "All 300 meters change"), ("typed", "Typed streaming (10 cards change)")):
    rows += [
        (f"{label}: busy per update, median (ms)", f"{phase}.busyPerUpdate.median"),
        (f"{label}: busy per update, p95 (ms)", f"{phase}.busyPerUpdate.p95"),
        (f"{label}: apply + render per update, median (ms)", f"{phase}.syncPerUpdate.median"),
        (f"{label}: applying the ops per update, median (ms)", f"{phase}.applyPerUpdate.median"),
        (f"{label}: main-thread CPU per update (ms)", f"{phase}.cpuPerUpdateMs"),
        (f"{label}: total CPU for 60 updates (ms)", f"{phase}.cpuTotal"),
        (f"{label}: prop decodes per update", f"{phase}.decodesPerUpdate"),
        (f"{label}: atom body evaluations per update", f"{phase}.bodiesPerUpdate"),
    ]
    if f"{phase}.cpuPerUpdateMs" in summary:
        summary[f"{phase}.cpuTotal"] = summary[f"{phase}.cpuPerUpdateMs"] * summary[f"{phase}.updates"]
rows += [
    ("Scroll 500 lazy cards down and up: frame work, median (ms)", "scroll.frameWork.median"),
    ("Scroll 500 lazy cards down and up: frame work, p95 (ms)", "scroll.frameWork.p95"),
    ("Scroll 500 lazy cards down and up: main-thread CPU (ms)", "scroll.cpuMs"),
    ("Scroll 500 lazy cards down and up: prop decodes", "scroll.decodes"),
    ("Scroll 500 lazy cards down and up: atom body evaluations", "scroll.bodies"),
]
print(f"Results in {directory} (median of {runs} runs)")
print("| Metric | Value |")
print("| --- | ---: |")
for label, key in rows:
    if key and key in summary:
        print(f"| {label} | {summary[key]:.2f} |")
if "typed.decodesPerUpdate" in summary and max(columns.get("typed.decodesPerUpdate", [0])) != 0:
    sys.exit("The typed board decoded props; it must decode none.")
PY
