#!/usr/bin/env bash
# The atom-tree spike's board benchmark (docs/atom-tree-performance.md): the native task item
# against the same card as an atom tree, typed (`tree`) and as plugin-style ops (`tree-dynamic`),
# in a Release build of this worktree's app. Scenarios: boards of 50, 500 and 2000 cards (open,
# scroll, memory), live updates (100 cards changing 10 times a second for 30 s, on boards of 100
# and 500 cards) and interaction
# (hover, press, context menu, drag preview). See
# Playhouse/App/Plugins/Renderer/TaskItemBenchmark.swift for what each number means. Every
# variant, scenario and run is a fresh app process; the summary gives the median and the worst run.
#
# Built with the PLAYHOUSE_ATOM_BENCHMARK condition in its own derived data (shared with
# scripts/benchmark-atom-tree.sh), never into a shipped app. scripts/trace-atom-spike.sh records
# an Instruments trace of one run.
#
# Usage: scripts/benchmark-atom-spike.sh [--benchmark task-item|transcript] [--runs N] [--out DIR]
#          [--skip-build | --build-only] [--app PATH] [--variants "native tree …"]
#          [--scenarios "board-50 live-100 …"]
# --build-only builds the benchmark app and prints its path; --app runs an already built copy
# (scripts/benchmark-atom-spike-tart.sh uses both to build on the host and measure in the Tart VM).
# A task-item scenario ending in -noclocks runs with no working card, so no card has a running clock.
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repository_root}/scripts/app-profile.sh"

benchmark=task-item
runs=5
# Seconds one app process may take before its run is recorded as unfinished.
run_timeout="${PLAYHOUSE_ATOM_BENCHMARK_RUN_TIMEOUT:-600}"
output_directory=""
skip_build=0
build_only=0
app_override=""
variants=""
scenarios=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --benchmark) benchmark="${2:?--benchmark needs task-item or transcript}"; shift 2 ;;
    --runs) runs="${2:?--runs needs a number}"; shift 2 ;;
    --out) output_directory="${2:?--out needs a directory}"; shift 2 ;;
    --skip-build) skip_build=1; shift ;;
    --build-only) build_only=1; shift ;;
    --app) app_override="${2:?--app needs a Playhouse.app path}"; skip_build=1; shift 2 ;;
    --variants) variants="${2:?--variants needs a list}"; shift 2 ;;
    --scenarios) scenarios="${2:?--scenarios needs a list}"; shift 2 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done
case "${benchmark}" in
  task-item)
    prefix=PLAYHOUSE_TASK_ITEM_BENCHMARK
    : "${variants:=native tree tree-dynamic}"
    : "${scenarios:=board-50 board-500 board-2000 live-100 live-500 interaction interaction-noclocks}" ;;
  transcript)
    prefix=PLAYHOUSE_TRANSCRIPT_TREE_BENCHMARK
    : "${variants:=native tree tree-dynamic tree-full tree-blocks}"
    : "${scenarios:=open-100 open-1000 open-5000 stream-100 stream-1000 stream-5000}" ;;
  *) printf 'Unknown benchmark: %s\n' "${benchmark}" >&2; exit 2 ;;
esac

architecture="$(uname -m)"
if [[ -n "${app_override}" ]]; then
  # A copied script tree (the Tart VM's) has no Git checkout to derive the app profile from.
  app_bundle="${app_override}"
else
  playhouse_load_app_profile "${repository_root}"
  derived_data_dir="${PLAYHOUSE_PROFILE_DERIVED_DATA}-AtomBenchmark"
  app_bundle="${derived_data_dir}/Build/Products/Release/Playhouse.app"
fi
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
if [[ "${build_only}" == 1 ]]; then
  printf '%s\n' "${app_bundle}"
  exit 0
fi
app_executable="${app_bundle}/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "${app_bundle}/Contents/Info.plist")"

if [[ -z "${output_directory}" ]]; then
  output_directory="$(mktemp -d "/tmp/playhouse-${benchmark}-benchmark.XXXXXX")"
fi
mkdir -p "${output_directory}"
if [[ -z "${app_override}" ]]; then
  playhouse_clear_inherited_bridge_overrides
fi

for scenario in ${scenarios}; do
  for ((run = 1; run <= runs; run++)); do
    # Variants alternate within a run, so a slow spell on the machine hits them alike.
    for variant in ${variants}; do
      result="${output_directory}/${scenario}-${variant}-run-${run}.json"
      rm -f "${result}"
      printf '%s, %s: run %d of %d…\n' "${scenario}" "${variant}" "${run}" "${runs}" >&2
      env -u PLAYHOUSE_DATA_DIRECTORY \
        PLAYHOUSE_MUTE_SOUNDS=1 \
        "${prefix}=${result}" \
        "${prefix}_VARIANT=${variant}" \
        "${prefix}_SCENARIO=${scenario%-noclocks}" \
        PLAYHOUSE_TASK_ITEM_BENCHMARK_NO_CLOCKS="$([[ "${scenario}" == *-noclocks ]] && echo 1 || echo 0)" \
        "${app_executable}" >/dev/null 2>&1 &
      app_pid=$!
      for ((waited = 0; waited < run_timeout; waited++)); do
        kill -0 "${app_pid}" 2>/dev/null || break
        sleep 1
      done
      if kill -0 "${app_pid}" 2>/dev/null; then
        kill "${app_pid}" 2>/dev/null || true
        wait "${app_pid}" 2>/dev/null || true
        # A run that cannot finish is a result too (the summary lists it); the matrix goes on.
        printf '%s, %s: run %d did not finish within %d seconds.\n' "${scenario}" "${variant}" "${run}" "${run_timeout}" >&2
        printf '%s\t%s\t%d\t%d\n' "${scenario}" "${variant}" "${run}" "${run_timeout}" >> "${output_directory}/timeouts.tsv"
        continue
      fi
      wait "${app_pid}" || true
      [[ -s "${result}" ]] || { printf '%s, %s: run %d wrote no results.\n' "${scenario}" "${variant}" "${run}" >&2; exit 1; }
    done
  done
done
pkill -f "${app_bundle}/Contents/MacOS/playhouse-daemon" 2>/dev/null || true

python3 "${repository_root}/scripts/summarize-atom-spike.py" "${benchmark}" "${output_directory}"
