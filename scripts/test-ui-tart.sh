#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script_path="${repository_root}/scripts/test-ui-tart.sh"
vm_name="${STATIONAI_UI_TART_VM:-stationai-ui}"
artifact_root="${STATIONAI_UI_TART_ARTIFACTS:-${TMPDIR:-/tmp}/stationai-ui-tart-artifacts}"

# Hold the host checkout's UI-test lock for the entire VM run.
# test-ui.sh sets the marker only when its caller already owns that host lock.
if [[ "${STATIONAI_UI_TART_HOST_LOCKED:-0}" != "1" ]]; then
	exec "${repository_root}/scripts/with-e2e-lock.sh" -- env STATIONAI_UI_TART_HOST_LOCKED=1 bash "${script_path}" "$@"
fi

usage() {
	cat <<'USAGE'
Usage: scripts/test-ui-tart.sh [--vm <tart-vm>] [--show-vm] [--live-provider <claude|codex>] [--case <case-id>]...

Runs visible UI tests in a stopped Tart macOS VM. It snapshots the checkout
inside the VM and copies test artifacts back to the host.
Pass --show-vm to open the VM display through Screen Sharing.
The runner holds the host repository's .e2e.lock for the full UI test session.
Pass --live-provider only when the guest has that provider's CLI and a login
(Claude Code for claude, Codex CLI for codex). --live-codex is shorthand for
--live-provider codex.

Environment:
  STATIONAI_UI_TART_VM         VM name (default: stationai-ui)
  STATIONAI_UI_TART_ARTIFACTS  Host artifact root
  --live-provider <provider>   Run live UI cases against claude or codex; guest access is required
USAGE
}

ui_cases=()
show_vm=0
live_provider=""
while (($#)); do
	case "$1" in
		--vm)
			if (($# < 2)) || [[ "$2" == --* ]]; then
				printf 'Expected a Tart VM name after --vm.\n' >&2
				exit 2
			fi
			vm_name="$2"
			shift 2
			;;
		--case)
			if (($# < 2)) || [[ "$2" == --* ]]; then
				printf 'Expected a test case ID after --case.\n' >&2
				exit 2
			fi
			ui_cases+=(--case "$2")
			shift 2
			;;
		--show-vm)
			show_vm=1
			shift
			;;
		--live-codex)
			live_provider=codex
			shift
			;;
		--live-provider)
			if (($# < 2)) || [[ "$2" != claude && "$2" != codex ]]; then
				printf 'Expected claude or codex after --live-provider.\n' >&2
				exit 2
			fi
			live_provider="$2"
			shift 2
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			printf 'Unknown argument: %s\n' "$1" >&2
			usage >&2
			exit 2
			;;
	esac
done

# Bash 3.2 treats expanding an empty array under `set -u` as an unbound
# variable. Pass an explicit sentinel so full-suite runs remain portable.
if ((${#ui_cases[@]} == 0)); then
	ui_cases=(--all-cases)
fi

if ! command -v tart >/dev/null 2>&1; then
	printf 'Tart is required but was not found in PATH.\n' >&2
	exit 1
fi
if ! tart list --quiet | rg -Fxq -- "$vm_name"; then
	printf 'Tart VM %q was not found. Create or clone the VM first.\n' "$vm_name" >&2
	exit 1
fi

run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
run_artifacts="${artifact_root}/${run_id}"
mkdir -p "$run_artifacts"
launch_log="${run_artifacts}/tart-run.log"
vm_pid=""

cleanup() {
	status=$?
	trap - EXIT INT TERM
	if [[ -n "$vm_pid" ]] && kill -0 "$vm_pid" 2>/dev/null; then
		tart stop "$vm_name" >/dev/null 2>&1 || true
		wait "$vm_pid" 2>/dev/null || true
	fi
	if (( status != 0 )) && [[ -f "$launch_log" ]]; then
		printf '\nTart VM launch log: %s\n' "$launch_log" >&2
		tail -40 "$launch_log" >&2 || true
	fi
}
trap cleanup EXIT INT TERM

if tart list --format json | python3 -c '
import json
import sys

name = sys.argv[1]
for vm in json.load(sys.stdin):
    if vm.get("Name", vm.get("name")) == name and vm.get("Running", vm.get("running", False)):
        raise SystemExit(0)
raise SystemExit(1)
' "$vm_name"; then
	printf 'Tart VM %q is already running. Stop it before using this runner so Tart can attach the source and artifact shares.\n' "$vm_name" >&2
	exit 1
fi

printf 'Starting Tart VM %s for UI run %s...\n' "$vm_name" "$run_id"
tart_display_args=(--no-graphics)
if (( show_vm == 1 )); then
	tart_display_args=(--vnc)
fi
env -u CI tart run "${tart_display_args[@]}" \
	--dir="source:${repository_root}:ro" \
	--dir="artifacts:${artifact_root}" \
	"$vm_name" >"$launch_log" 2>&1 &
vm_pid=$!

guest_ready=0
for _ in $(seq 1 180); do
	if tart exec "$vm_name" /usr/bin/true >/dev/null 2>&1; then
		guest_ready=1
		break
	fi
	if ! kill -0 "$vm_pid" 2>/dev/null; then
		printf 'Tart VM exited before the guest agent became available.\n' >&2
		exit 1
	fi
	sleep 2
done
if (( guest_ready == 0 )); then
	printf 'Timed out waiting for Tart guest agent in VM %q.\n' "$vm_name" >&2
	exit 1
fi

if (( show_vm == 1 )); then
	if [[ ! -t 0 ]]; then
		printf 'The --show-vm setup pause requires an interactive terminal.\n' >&2
		exit 2
	fi
	printf 'The VM display is open. Configure Accessibility permission in the guest if needed, then press Return to start the UI test (Ctrl-C to cancel).\n'
	read -r
fi

printf 'Running UI tests in VM-local source snapshot...\n'
set +e
tart exec -i "$vm_name" /bin/bash -s -- "$run_id" "${live_provider:-none}" "${ui_cases[@]}" <<'GUEST_SCRIPT'
set -uo pipefail
run_id="$1"
shift
live_provider="$1"
shift
if [[ "$live_provider" == "none" ]]; then
	live_provider=""
fi
if [[ "${1:-}" == "--all-cases" ]]; then
	shift
fi
if [[ ! "$run_id" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+$ ]]; then
	printf 'Invalid Tart UI run ID: %s\n' "$run_id" >&2
	exit 2
fi
source_root="/Volumes/My Shared Files/source"
artifact_root="/Volumes/My Shared Files/artifacts"
snapshot_root="${HOME}/StationAIUITestRuns/${run_id}"
source_snapshot_root="${HOME}/StationAIUITestRuns/SourceSnapshot"
source_snapshot_owner="${HOME}/StationAIUITestRuns/.source-snapshot-owner"
source_snapshot_owner_contents="StationAI Tart owns this reusable source snapshot (v1)."
guest_tmp="/tmp/stationai-ui-tart-${run_id}"
guest_log="${snapshot_root}/ui-test.log"
guest_artifacts="${artifact_root}/${run_id}"

mkdir -p "$snapshot_root" "$guest_tmp"
if ! mkdir -p "$guest_artifacts"; then
	printf 'Cannot create host artifact share path %s; guest run data is retained at %s.\n' "$guest_artifacts" "$snapshot_root" >&2
	exit 74
fi
if [[ ! -d "$source_root/StationAI.xcodeproj" ]]; then
	printf 'Shared source directory is unavailable or missing StationAI.xcodeproj: %s\n' "$source_root" >&2
	exit 2
fi
if ! xcode-select -p >/dev/null 2>&1; then
	printf 'Xcode command line tools are not configured in the VM.\n' >&2
	exit 2
fi
if [[ -n "$live_provider" ]] && ! command -v "$live_provider" >/dev/null 2>&1; then
	printf 'Live %s UI execution requires the %s CLI inside the VM. Configure guest access first.\n' "$live_provider" "$live_provider" >&2
	exit 2
fi

if [[ -e "$source_snapshot_owner" ]] && [[ "$(cat "$source_snapshot_owner")" != "$source_snapshot_owner_contents" ]]; then
	printf 'Refusing to replace the VM source snapshot without its ownership marker: %s\n' "$source_snapshot_root" >&2
	exit 74
fi
if [[ -e "$source_snapshot_root" ]]; then
	if [[ ! -f "$source_snapshot_owner" ]]; then
		printf 'Refusing to replace an unowned VM source snapshot: %s\n' "$source_snapshot_root" >&2
		exit 74
	fi
	rm -rf -- "$source_snapshot_root"
fi
mkdir -p "$source_snapshot_root"
printf '%s\n' "$source_snapshot_owner_contents" > "$source_snapshot_owner"
if ! ditto "$source_root" "$source_snapshot_root"; then
	printf 'Could not create the VM-local source snapshot; guest run data is retained at %s.\n' "$snapshot_root" >&2
	exit 74
fi
# A linked worktree's .git file points back to the host's common Git directory,
# which is not mounted in the VM. The snapshot only needs local repository
# identity for app-profile.sh, so give this disposable copy its own metadata.
if [[ -f "${source_snapshot_root}/.git" ]]; then
	mv "${source_snapshot_root}/.git" "${source_snapshot_root}/.git-host-worktree-pointer"
	git -C "$source_snapshot_root" init --quiet
fi
printf 'VM-local source snapshot: %s\n' "$source_snapshot_root"
printf 'Xcode: %s\n' "$(xcodebuild -version | tr '\n' ' ')"

# The base image restores a large Terminal window over newly launched apps.
# Close it so macOS UI automation sees the app's visible window consistently.
osascript -e 'tell application "Terminal" to quit' >/dev/null 2>&1 || true
sleep 2

if [[ -n "$live_provider" ]]; then
	printf '%s\n' "$live_provider" > /tmp/stationai-live-ui-integration
	export STATIONAI_RUN_LIVE_INTEGRATION=1
	export STATIONAI_LIVE_PROVIDER="$live_provider"
fi
set +e
STATIONAI_UI_TART_GUEST=1 STATIONAI_UI_DASHBOARD=0 TMPDIR="$guest_tmp" "${source_snapshot_root}/scripts/test-ui.sh" "$@" 2>&1 | tee "$guest_log"
test_status=${PIPESTATUS[0]}
set -e
if [[ -n "$live_provider" ]]; then
	rm -f /tmp/stationai-live-ui-integration
fi

artifact_copy_status=0
if ! ditto "$guest_log" "${guest_artifacts}/ui-test.log"; then
	printf 'Failed to copy the UI test log to the host artifact share.\n' >&2
	artifact_copy_status=1
fi
while IFS= read -r -d '' test_output; do
	if ! ditto "$test_output" "${guest_artifacts}/$(basename "$test_output")"; then
		printf 'Failed to copy test output %s to the host artifact share.\n' "$test_output" >&2
		artifact_copy_status=1
	fi
done < <(find "$guest_tmp" -maxdepth 1 -type d -name 'stationai-ui.*' -print0)
if ! printf '%s\n' "$test_status" > "${guest_artifacts}/exit-status.txt"; then
	printf 'Failed to write the UI test exit status to the host artifact share.\n' >&2
	artifact_copy_status=1
fi
if (( artifact_copy_status != 0 )); then
	printf 'Artifact export was incomplete; guest run data is retained at %s.\n' "$snapshot_root" >&2
	exit 74
fi
printf 'Host artifacts: %s\n' "$guest_artifacts"
rm -rf -- "$snapshot_root"
rm -rf -- "$guest_tmp"
exit "$test_status"
GUEST_SCRIPT
test_status=$?
set -e

printf 'Tart UI run artifacts: %s\n' "$run_artifacts"
exit "$test_status"
