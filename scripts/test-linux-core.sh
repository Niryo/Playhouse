#!/usr/bin/env bash
# Builds PlayhouseCore and PlayhouseUI and runs the core tests on Linux, in the Linux UI spike's
# image (Ubuntu 25.10, swift.org Swift 6.3.2; spikes/linux-ui/Dockerfile). The macOS app stays
# buildable only on macOS; this keeps the shared modules buildable on Linux
# (docs/linux-port-readiness.md).
#
# Usage: scripts/test-linux-core.sh
#   PLAYHOUSE_LINUX_IMAGE   image to use (default playhouse-linux-ui, built when missing)
#   PLAYHOUSE_LINUX_CACHE   Docker volume for SwiftPM's build directory (default: none, a fresh build)
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
image="${PLAYHOUSE_LINUX_IMAGE:-playhouse-linux-ui}"

if ! docker image inspect "${image}" >/dev/null 2>&1; then
  printf 'Building %s from spikes/linux-ui/Dockerfile\n' "${image}" >&2
  docker build -t "${image}" "${repository_root}/spikes/linux-ui"
fi

scratch=(--scratch-path /tmp/playhouse-build)
volume=()
if [[ -n "${PLAYHOUSE_LINUX_CACHE:-}" ]]; then
  volume=(-v "${PLAYHOUSE_LINUX_CACHE}:/build")
  scratch=(--scratch-path /build)
fi

docker run --rm \
  -v "${repository_root}/Playhouse:/src/Playhouse:ro" \
  -v "${repository_root}/Vendor:/src/Vendor:ro" \
  ${volume[@]+"${volume[@]}"} \
  -w /src/Playhouse \
  "${image}" \
  bash -euo pipefail -c "
    swift --version
    swift build ${scratch[*]} --target PlayhouseCore
    swift build ${scratch[*]} --target PlayhouseUI
    swift test ${scratch[*]}
  "
