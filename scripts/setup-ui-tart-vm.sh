#!/usr/bin/env bash
set -euo pipefail

script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
repository_root="$(cd "$(dirname "$script_path")/.." && pwd)"
vm_name="${PLAYHOUSE_UI_TART_VM:-playhouse-ui}"
image="${PLAYHOUSE_UI_TART_IMAGE:-ghcr.io/cirruslabs/macos-tahoe-xcode:26.5}"
tart_home="${TART_HOME:-${HOME}/.tart}"
minimum_free_kib=$((110 * 1024 * 1024))
# The OpenCode 2 release the scripted real-binary suite (scripts/test-opencode-scripted.sh) runs
# in the guest, installed with OpenCode's official v2 installer.
opencode_version="${PLAYHOUSE_UI_TART_OPENCODE_VERSION:-2.4.0}"

usage() {
	cat <<'USAGE'
Usage: scripts/setup-ui-tart-vm.sh [--slim]

Creates the shared Tart UI test VM when it does not exist, slims it, applies its
CPU, memory, and display settings, and installs the pinned OpenCode 2 release in
the guest (~/.opencode/bin/opencode) when it is missing or another version.

  --slim   Also slim an existing VM. A freshly cloned VM is always slimmed.

Slimming removes guest components the macOS UI suite does not use (simulator
runtimes, Flutter, the Android SDK, Kiro CLI, and system/user caches), which
shrinks the VM's host disk image by about 50 GB.
USAGE
}

slim=0
original_args=("$@")
while (($# > 0)); do
	case "$1" in
		--slim) slim=1 ;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			printf 'Unknown argument: %s\n' "$1" >&2
			usage >&2
			exit 2
			;;
	esac
	shift
done

if ! command -v tart >/dev/null 2>&1; then
	printf 'Tart is required but was not found in PATH.\n' >&2
	exit 1
fi

# The VM is shared host-wide; hold the same lock as scripts/test-ui-tart.sh so
# setup never clones, reconfigures, or slims a VM while a UI run is using it.
if [[ "${PLAYHOUSE_UI_TART_VM_LOCKED:-0}" != "1" ]]; then
	exec python3 "${repository_root}/scripts/with-file-lock.py" \
		"/tmp/playhouse-ui-tart-${vm_name//\//_}.lock" \
		env PLAYHOUSE_UI_TART_VM_LOCKED=1 bash "${script_path}" ${original_args[@]+"${original_args[@]}"}
fi

mkdir -p "$tart_home"

vm_is_running() {
	tart list --format json | python3 -c '
import json
import sys

name = sys.argv[1]
for vm in json.load(sys.stdin):
    if vm.get("Name", vm.get("name")) == name and vm.get("Running", vm.get("running", False)):
        raise SystemExit(0)
raise SystemExit(1)
' "$vm_name"
}

if ! tart list --quiet | rg -Fxq -- "$vm_name"; then
	available_kib="$(df -Pk "$tart_home" | awk 'NR == 2 { print $4 }')"
	if [[ -z "$available_kib" ]] || (( available_kib < minimum_free_kib )); then
		available_gib=$((${available_kib:-0} / 1024 / 1024))
		printf 'Creating %s needs about 110 GiB free in Tart storage; found %s GiB at %s. Free or provide storage, then rerun.\n' \
			"$image" "$available_gib" "$tart_home" >&2
		exit 1
	fi
	printf 'Cloning %s as Tart VM %s...\n' "$image" "$vm_name"
	tart clone "$image" "$vm_name"
	# The pulled OCI image stays in Tart's cache after cloning; the VM never
	# needs it again, so drop it rather than keep a second copy on disk.
	if [[ "$image" == */* ]]; then
		tart delete "$image" >/dev/null 2>&1 || true
	fi
	slim=1
fi

if ! vm_is_running; then
	tart set "$vm_name" --cpu 6 --memory 12288 --display 2560x1600
else
	printf 'Tart VM %s is running; leaving its CPU, memory, and display settings unchanged.\n' "$vm_name"
fi

vm_pid=""
started_vm=0
stop_started_vm() {
	if (( started_vm == 1 )); then
		tart stop "$vm_name" >/dev/null 2>&1 || true
		[[ -n "$vm_pid" ]] && wait "$vm_pid" 2>/dev/null || true
	fi
}
trap stop_started_vm EXIT
trap 'exit 130' INT TERM

# Starts the VM when it isn't running (stopping it again on exit) and waits for its guest agent.
start_guest() {
	local failed="$1"
	if ! vm_is_running; then
		printf 'Starting Tart VM %s...\n' "$vm_name"
		tart run --no-graphics --no-audio "$vm_name" </dev/null >/dev/null 2>&1 &
		vm_pid=$!
		started_vm=1
	fi
	for _ in $(seq 1 180); do
		if tart exec "$vm_name" /usr/bin/true >/dev/null 2>&1; then
			return 0
		fi
		if (( started_vm == 1 )) && ! kill -0 "$vm_pid" 2>/dev/null; then
			"$failed" "Tart VM ${vm_name} exited before its guest agent became available."
		fi
		sleep 2
	done
	"$failed" "Timed out waiting for the Tart guest agent in VM ${vm_name}."
}

if (( slim == 1 )); then
	slim_failed() {
		printf '%s Rerun `scripts/setup-ui-tart-vm.sh --slim` to slim the VM.\n' "$1" >&2
		exit 1
	}
	start_guest slim_failed

	printf 'Removing guest components the macOS UI suite does not use...\n'
	tart exec -i "$vm_name" /bin/bash -s <<'GUEST_SCRIPT' || slim_failed "Slimming the guest of Tart VM ${vm_name} failed."
set -uo pipefail
used() { df -k /System/Volumes/Data | awk 'NR == 2 { printf "%.1f GiB", $3 / 1048576 }'; }
printf 'Guest data volume used before slimming: %s\n' "$(used)"

xcrun simctl shutdown all >/dev/null 2>&1 || true
xcrun simctl delete all >/dev/null 2>&1 || true
# Runtime deletion is asynchronous and occasionally leaves one behind; retry.
for _ in 1 2 3; do
	xcrun simctl runtime delete all >/dev/null 2>&1 || true
	sleep 10
	remaining="$(xcrun simctl runtime list -j 2>/dev/null | python3 -c 'import json, sys; print(len(json.load(sys.stdin)))' 2>/dev/null || echo 0)"
	(( remaining == 0 )) && break
done
if (( ${remaining:-0} > 0 )); then
	printf 'Note: %s simulator runtime record(s) remain after deletion.\n' "$remaining"
fi

rm -rf "$HOME/flutter" "$HOME/android-sdk"
find "$HOME/Library/Caches" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
status=0
if ! sudo -n rm -rf "/Applications/Kiro CLI.app" /System/Library/Caches/com.apple.coresymbolicationd; then
	printf 'Removing system-owned components needs passwordless sudo in the guest.\n' >&2
	status=1
fi
sync

printf 'Guest data volume used after slimming: %s\n' "$(used)"
exit "$status"
GUEST_SCRIPT
fi

opencode_failed() {
	printf '%s Rerun `scripts/setup-ui-tart-vm.sh` to install OpenCode %s in the VM.\n' "$1" "$opencode_version" >&2
	exit 1
}
start_guest opencode_failed
tart exec -i "$vm_name" /bin/bash -s "$opencode_version" <<'GUEST_SCRIPT' || opencode_failed "Installing OpenCode in Tart VM ${vm_name} failed."
set -euo pipefail
version="$1"
installed="$("$HOME/.opencode/bin/opencode" --version 2>/dev/null || true)"
if [[ "$installed" == "opencode v${version}" ]]; then
	printf 'OpenCode %s is already installed in the guest.\n' "$version"
	exit 0
fi
printf 'Installing OpenCode %s in the guest...\n' "$version"
curl -fsSL https://opencode.ai/v2/install | bash -s -- --version "$version" --no-modify-path
"$HOME/.opencode/bin/opencode" --version
GUEST_SCRIPT

printf 'Tart UI test VM ready: %s\n' "$vm_name"
printf 'Run a focused case with: scripts/test-ui-tart.sh --case <case-id>\n'
