#!/usr/bin/env bash
# One command for the whole spike:
#   1. renders the native macOS reference card from the app's real sources (macOS host only),
#   2. builds the Docker image (Swift 6.3.2, GTK 4.20, libadwaita 1.8, Xvfb),
#   3. in the container: builds both demos, takes the screenshots (with real
#      pointer hover, clicks and a right-click menu via xdotool), runs the
#      redraw/observation checks and the benchmarks,
#   4. composes the comparison images and summarizes the numbers.
#   5. "fork": the same card on a SwiftCrossUI fork (pinned revision +
#      patches/swiftcrossui-fork.patch, cloned into fork/): performance fixes
#      and an animation POC, benchmarked and captured the same way.
# Output goes to out/. Usage: ./run.sh [stage...]  (stages: native image build shots checks perf fork compose)
# PH_RUNS sets the startup runs per configuration (default 5). Needs Docker (e.g. `colima start --cpu 6 --memory 12`).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
STAGES="${*:-native image build shots checks perf fork compose}"
has() { [[ " $STAGES " == *" $1 "* ]]; }
IMAGE=playhouse-linux-ui
CACHE=ph-linux-ui-cache   # named volume: SwiftPM checkouts and build products
in_container() { docker run --rm -e PH_RUNS="${PH_RUNS:-5}" -v "$HERE":/spike -v "$CACHE":/cache "$IMAGE" "$@"; }

mkdir -p out
if has native; then
    if [[ "$(uname)" == Darwin ]]; then native/build.sh out; else echo "skipping native card (needs macOS)"; fi
fi
has image && docker build -t "$IMAGE" .
container_stages=()
for stage in build shots checks perf; do has $stage && container_stages+=("$stage"); done
if has fork; then
    FORK_REV=8b39220d81066d5479d3d102482aed2bb6d5cb6f
    if [[ ! -d fork/swift-cross-ui ]]; then
        git clone -q https://github.com/moreSwift/swift-cross-ui fork/swift-cross-ui
        git -C fork/swift-cross-ui checkout -q "$FORK_REV"
        git -C fork/swift-cross-ui apply "$HERE/patches/swiftcrossui-fork.patch"
    fi
    container_stages+=(forkbuild forkshots forkchecks forkperf forkanim)
fi
if ((${#container_stages[@]})); then in_container bash /spike/scripts/container-run.sh "${container_stages[@]}"; fi
if has compose; then
    in_container bash /spike/scripts/compose.sh
    python3 scripts/summarize.py out/perf/results.jsonl > out/perf/summary.md
    echo "Wrote out/side-by-side.png, out/<lib>-states.png and out/perf/summary.md"
fi
