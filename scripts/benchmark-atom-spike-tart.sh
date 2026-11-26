#!/usr/bin/env bash
# Runs the atom-tree spike's benchmarks (scripts/benchmark-atom-spike.sh) inside the shared Tart
# VM instead of on the host. The host builds the Release benchmark app once; the VM runs every
# variant of every scenario, so native and tree are measured under the same conditions. A VM has
# no real GPU and adds its own overhead, so its numbers compare variants with each other; they
# are not the app's absolute speed on this Mac.
#
# Holds the host-wide VM lock (the one scripts/test-ui-tart.sh takes) for the whole run, and
# reuses the VM if it is already running with the artifact share, otherwise starts it.
#
# Usage: scripts/benchmark-atom-spike-tart.sh [--skip-build] [benchmark-atom-spike.sh options…]
# PLAYHOUSE_ATOM_BENCHMARK_RUN_TIMEOUT (seconds, default 600) is passed on to the guest.
# Results, the summary and the guest's machine description land in
# /tmp/playhouse-ui-tart-artifacts/atom-benchmark-<run id>/.
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
vm_name="${PLAYHOUSE_UI_TART_VM:-playhouse-ui}"
artifact_root="${PLAYHOUSE_UI_TART_ARTIFACTS:-/tmp/playhouse-ui-tart-artifacts}"

skip_build=0
benchmark_args=()
for argument in "$@"; do
  case "${argument}" in
    --skip-build) skip_build=1 ;;
    --app|--out|--build-only) printf '%s is chosen by this script.\n' "${argument}" >&2; exit 2 ;;
    *) benchmark_args+=("${argument}") ;;
  esac
done

if [[ "${PLAYHOUSE_ATOM_BENCHMARK_VM_LOCKED:-0}" != "1" ]]; then
  build_args=(--build-only)
  (( skip_build == 1 )) && build_args+=(--skip-build)
  app_bundle="$("${repository_root}/scripts/benchmark-atom-spike.sh" "${build_args[@]}" | tail -1)"
  exec env PLAYHOUSE_ATOM_BENCHMARK_VM_LOCKED=1 PLAYHOUSE_ATOM_BENCHMARK_APP="${app_bundle}" \
    python3 "${repository_root}/scripts/with-file-lock.py" "/tmp/playhouse-ui-tart-${vm_name//\//_}.lock" \
    bash "${BASH_SOURCE[0]}" ${benchmark_args[@]+"${benchmark_args[@]}"}
fi
app_bundle="${PLAYHOUSE_ATOM_BENCHMARK_APP:?}"

run_id="atom-benchmark-$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -p "${artifact_root}"
chmod 700 "${artifact_root}"
run_directory="${artifact_root}/${run_id}"
mkdir -p "${run_directory}"
ditto "${app_bundle}" "${run_directory}/Playhouse.app"
mkdir -p "${run_directory}/scripts"
cp "${repository_root}/scripts/benchmark-atom-spike.sh" "${repository_root}/scripts/app-profile.sh" \
  "${repository_root}/scripts/summarize-atom-spike.py" "${run_directory}/scripts/"

guest_sees_run() {
  tart exec "${vm_name}" /bin/test -d "/Volumes/My Shared Files/artifacts/${run_id}" >/dev/null 2>&1
}
if ! guest_sees_run; then
  tart stop "${vm_name}" >/dev/null 2>&1 || true
  printf 'Starting Tart VM %s…\n' "${vm_name}" >&2
  python3 - "${run_directory}/tart-run.log" "${vm_name}" "${artifact_root}" <<'PY' &
import os, subprocess, sys
log_path, vm_name, artifact_root = sys.argv[1:]
os.setsid()
with open(log_path, "ab", buffering=0) as log_file:
    subprocess.Popen(["tart", "run", "--no-graphics", "--no-audio", f"--dir=artifacts:{artifact_root}", vm_name],
                     stdin=subprocess.DEVNULL, stdout=log_file, stderr=subprocess.STDOUT,
                     start_new_session=True, close_fds=True).wait()
PY
  for _ in $(seq 1 180); do
    guest_sees_run && break
    sleep 2
  done
  guest_sees_run || { printf 'The Tart VM did not come up with the artifact share.\n' >&2; exit 1; }
fi

tart exec -i "${vm_name}" /bin/bash -s -- "${run_id}" "${PLAYHOUSE_ATOM_BENCHMARK_RUN_TIMEOUT:-600}" ${benchmark_args[@]+"${benchmark_args[@]}"} <<'GUEST_SCRIPT'
set -euo pipefail
run_id="$1"; export PLAYHOUSE_ATOM_BENCHMARK_RUN_TIMEOUT="$2"; shift 2
share="/Volumes/My Shared Files/artifacts/${run_id}"
local_root="${HOME}/PlayhouseAtomBenchmark"
pkill -f "${local_root}/Playhouse.app/" 2>/dev/null || true
rm -rf "${local_root}"
mkdir -p "${local_root}"
ditto "${share}/Playhouse.app" "${local_root}/Playhouse.app"
ditto "${share}/scripts" "${local_root}/scripts"
{
  printf 'Model: %s\n' "$(sysctl -n hw.model)"
  printf 'CPU: %s, %s cores\n' "$(sysctl -n machdep.cpu.brand_string)" "$(sysctl -n hw.ncpu)"
  printf 'Memory: %s GB\n' "$(( $(sysctl -n hw.memsize) / 1073741824 ))"
  printf 'macOS: %s (%s)\n' "$(sw_vers -productVersion)" "$(sw_vers -buildVersion)"
} > "${share}/machine.txt"
cat "${share}/machine.txt"
"${local_root}/scripts/benchmark-atom-spike.sh" --app "${local_root}/Playhouse.app" --out "${share}/results" "$@" \
  2>&1 | tee "${share}/benchmark.log"
GUEST_SCRIPT
rm -rf "${run_directory}/Playhouse.app"
printf 'Tart benchmark results: %s\n' "${run_directory}"
