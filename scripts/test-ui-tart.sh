#!/usr/bin/env bash
set -euo pipefail

repository_root="${PLAYHOUSE_UI_TART_REPOSITORY_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
script_path="${repository_root}/scripts/test-ui-tart.sh"
vm_name="${PLAYHOUSE_UI_TART_VM:-playhouse-ui}"
artifact_root="${PLAYHOUSE_UI_TART_ARTIFACTS:-${TMPDIR:-/tmp}/playhouse-ui-tart-artifacts}"
export PLAYHOUSE_UI_LOCK_TIMEOUT_SECONDS="${PLAYHOUSE_UI_LOCK_TIMEOUT_SECONDS:-120}"

# Hold the host checkout's UI-test lock for the entire VM run.
# test-ui.sh sets the marker only when its caller already owns that host lock.
if [[ "${PLAYHOUSE_UI_TART_HOST_LOCKED:-0}" != "1" ]]; then
	exec "${repository_root}/scripts/with-e2e-lock.sh" -- env PLAYHOUSE_UI_TART_HOST_LOCKED=1 bash "${script_path}" "$@"
fi
if [[ "${PLAYHOUSE_UI_TART_IMMUTABLE:-0}" != "1" ]]; then
	immutable_runner="$(mktemp "${TMPDIR:-/tmp}/playhouse-ui-tart-runner.XXXXXX")"
	cp "${script_path}" "${immutable_runner}"
	chmod 700 "${immutable_runner}"
	exec env \
		PLAYHOUSE_UI_TART_IMMUTABLE=1 \
		PLAYHOUSE_UI_TART_IMMUTABLE_PATH="${immutable_runner}" \
		PLAYHOUSE_UI_TART_REPOSITORY_ROOT="${repository_root}" \
		bash "${immutable_runner}" "$@"
fi
original_args=("$@")

usage() {
	cat <<'USAGE'
Usage: scripts/test-ui-tart.sh [--vm <tart-vm>] [--stop-vm-after-run] [--reset-vm-state] [--show-vm] [--live-provider <claude|codex>] [--case <case-id>]...

Runs visible UI tests in a persistent Tart macOS VM. It snapshots the checkout
inside the VM and copies test artifacts back to the host.
Pass --show-vm to open the VM display through Screen Sharing.
The VM remains running for subsequent focused runs by default.
Pass --stop-vm-after-run to stop it after this invocation.
Pass --reset-vm-state to terminate leftover app/test processes first.
The runner holds the host repository's .e2e.lock for the full UI test session.
Pass --live-provider only when the guest has that provider's CLI and a login
(Claude Code for claude, Codex CLI for codex). --live-codex is shorthand for
--live-provider codex.

Environment:
  PLAYHOUSE_UI_TART_VM         VM name (default: playhouse-ui)
  PLAYHOUSE_UI_TART_ARTIFACTS  Host artifact root
  --live-provider <provider>   Run live UI cases against claude or codex; guest access is required
  --stop-vm-after-run          Stop the persistent VM after this run
  --reset-vm-state             Reset guest app/test processes before this run
USAGE
}

ui_cases=()
show_vm=0
live_provider=""
keep_vm=1
reset_vm_state=0
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
		--keep-vm)
			keep_vm=1
			shift
			;;
		--stop-vm-after-run)
			keep_vm=0
			shift
			;;
		--reset-vm-state)
			reset_vm_state=1
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

# Repository locks are worktree-local, while a Tart VM is shared host-wide.
# Serialize ownership checks, startup, execution, and cleanup for each VM.
if [[ "${PLAYHOUSE_UI_TART_VM_LOCKED:-0}" != "1" ]]; then
	vm_lock_name="${vm_name//\//_}"
	runner="${PLAYHOUSE_UI_TART_IMMUTABLE_PATH:-${script_path}}"
	exec python3 "${repository_root}/scripts/with-file-lock.py" \
		"/tmp/playhouse-ui-tart-${vm_lock_name}.lock" \
		env PLAYHOUSE_UI_TART_VM_LOCKED=1 bash "${runner}" ${original_args[@]+"${original_args[@]}"}
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
vm_started=0
# VM ownership is global per host VM, not per checkout's TMPDIR. A
# TMPDIR-scoped marker lets two worktrees both believe they own the same
# persistent VM and causes Tart guest transport collisions.
session_marker="${PLAYHOUSE_UI_TART_SESSION_MARKER:-/tmp/playhouse-ui-tart-${vm_name}.session}"
session_value="${repository_root}"$'\n'"${artifact_root}"
session_marker_owned=0
if [[ -L "$session_marker" ]]; then
	printf 'Refusing to use a symlink as the Tart session marker: %s\n' "$session_marker" >&2
	exit 74
fi

cleanup() {
	status=$?
	trap - EXIT INT TERM
	if (( vm_started == 1 && session_marker_owned == 0 )) ||
		(( keep_vm == 0 )) && (( vm_started == 1 || session_marker_owned == 1 )); then
		tart stop "$vm_name" >/dev/null 2>&1 || true
		if [[ -n "$vm_pid" ]]; then
			wait "$vm_pid" 2>/dev/null || true
		fi
	fi
	if (( session_marker_owned == 1 && keep_vm == 0 )); then
		rm -f "$session_marker"
	fi
	if (( status != 0 )) && [[ -f "$launch_log" ]]; then
		printf '\nTart VM launch log: %s\n' "$launch_log" >&2
		tail -40 "$launch_log" >&2 || true
	fi
	rm -f "${PLAYHOUSE_UI_TART_IMMUTABLE_PATH:-}"
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
	if [[ ! -f "$session_marker" ]] || [[ "$(cat "$session_marker")" != "$session_value" ]]; then
		printf 'Tart VM %q is running but was not retained by this checkout/artifact session.\n' "$vm_name" >&2
		printf 'Stop it manually, then start a new --keep-vm session.\n' >&2
		exit 1
	fi
	session_marker_owned=1
	printf 'Reusing already-running Tart VM %s.\n' "$vm_name"
else
	if [[ -e "$session_marker" ]]; then
		if [[ "$(cat "$session_marker" 2>/dev/null || true)" != "$session_value" ]]; then
			printf 'Refusing to remove an unrelated Tart session marker: %s\n' "$session_marker" >&2
			exit 74
		fi
		printf 'Discarding the retained-session marker because the Tart VM is stopped.\n'
		rm -f "$session_marker"
	fi
	printf 'Starting Tart VM %s for UI run %s...\n' "$vm_name" "$run_id"
	tart_display_args=(--no-graphics)
	if (( show_vm == 1 )); then
		tart_display_args=(--vnc)
	fi
	python3 - "$launch_log" "${tart_display_args[@]}" \
		--dir="source:${repository_root}:ro" \
		--dir="artifacts:${artifact_root}" \
		"$vm_name" <<'PY' &
import subprocess
import sys
import os

log_path = sys.argv[1]
arguments = sys.argv[2:]
try:
    os.setsid()
except PermissionError:
    pass
for descriptor in range(3, 256):
    try:
        os.close(descriptor)
    except OSError:
        pass
with open(log_path, "ab", buffering=0) as log_file:
    child = subprocess.Popen(
        ["tart", "run", *arguments],
        stdin=subprocess.DEVNULL,
        stdout=log_file,
        stderr=subprocess.STDOUT,
        start_new_session=True,
        env={key: value for key, value in os.environ.items() if key != "CI"},
        close_fds=True,
    )
    raise SystemExit(child.wait())
PY
	vm_pid=$!
	vm_started=1
fi
guest_ready=0
for _ in $(seq 1 180); do
	if tart exec "$vm_name" /usr/bin/true >/dev/null 2>&1; then
		guest_ready=1
		break
	fi
	if (( vm_started == 1 )) && ! kill -0 "$vm_pid" 2>/dev/null; then
		printf 'Tart VM exited before the guest agent became available.\n' >&2
		exit 1
	fi
	sleep 2
done
if (( guest_ready == 0 )); then
	printf 'Timed out waiting for Tart guest agent in VM %q.\n' "$vm_name" >&2
	exit 1
fi
if (( keep_vm == 1 )); then
	if ! session_marker_tmp="$(mktemp "${session_marker}.tmp.XXXXXX")"; then
		printf 'Could not create the Tart session marker temporary file.\n' >&2
		keep_vm=0
		exit 74
	fi
	if ! printf '%s\n' "$session_value" > "$session_marker_tmp" ||
		! mv -f "$session_marker_tmp" "$session_marker"; then
		rm -f "$session_marker_tmp"
		printf 'Could not write the Tart session marker; stopping the newly started VM.\n' >&2
		keep_vm=0
		exit 74
	fi
	session_marker_owned=1
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
source_sync_root="${run_artifacts}/source"
mkdir -p "$source_sync_root"
# Git metadata and build outputs are not needed in the VM (the snapshot gets its own
# repository below); copying them through the shared mount exhausted its file handles.
if ! rsync -a --delete --exclude='.git' --exclude='DerivedData/' --exclude='build/' --exclude='*.xcresult/' --exclude='node_modules/' --exclude='.idea/' --exclude='xcuserdata/' --exclude='.tmp-*' --exclude='.e2e.lock' --exclude='*.profraw' --exclude='__pycache__/' --exclude='*.pyc' "${repository_root}/" "${source_sync_root}/"; then
	printf 'Could not synchronize the current checkout into the Tart artifact share.\n' >&2
	exit 74
fi
set +e
tart exec -i "$vm_name" /bin/bash -s -- "$run_id" "${live_provider:-none}" "$reset_vm_state" "${PLAYHOUSE_UI_BATCH_SIZE:-}" "${ui_cases[@]}" <<'GUEST_SCRIPT'
set -uo pipefail
run_id="$1"
shift
live_provider="$1"
shift
reset_vm_state="$1"
shift
ui_batch_size="$1"
shift
if [[ -n "$ui_batch_size" ]]; then
	export PLAYHOUSE_UI_BATCH_SIZE="$ui_batch_size"
fi
if [[ "$live_provider" == "none" ]]; then
	live_provider=""
fi
reset_failed=0
if [[ "$reset_vm_state" == "1" ]]; then
	pkill -x Playhouse >/dev/null 2>&1 || true
	pkill -x PlayhouseUITests-Runner >/dev/null 2>&1 || true
	pkill -x "Diagnostics Reporter" >/dev/null 2>&1 || true
	pkill -f 'xcodebuild.*Playhouse' >/dev/null 2>&1 || true
	for _ in $(seq 1 40); do
		if ! pgrep -x Playhouse >/dev/null 2>&1 &&
			! pgrep -x PlayhouseUITests-Runner >/dev/null 2>&1 &&
			! pgrep -f 'xcodebuild.*Playhouse' >/dev/null 2>&1; then
			break
		fi
		sleep 0.25
	done
	if pgrep -x Playhouse >/dev/null 2>&1 ||
		pgrep -x PlayhouseUITests-Runner >/dev/null 2>&1 ||
		pgrep -f 'xcodebuild.*Playhouse' >/dev/null 2>&1; then
		reset_failed=1
	fi
fi
if [[ "${1:-}" == "--all-cases" ]]; then
	shift
fi
if [[ ! "$run_id" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+$ ]]; then
	printf 'Invalid Tart UI run ID: %s\n' "$run_id" >&2
	exit 2
fi
artifact_root="/Volumes/My Shared Files/artifacts"
source_root="${artifact_root}/${run_id}/source"
snapshot_root="${HOME}/PlayhouseUITestRuns/${run_id}"
source_snapshot_root="${HOME}/PlayhouseUITestRuns/SourceSnapshot"
source_snapshot_owner="${HOME}/PlayhouseUITestRuns/.source-snapshot-owner"
source_snapshot_owner_contents="Playhouse Tart owns this reusable source snapshot (v1)."
guest_tmp="/tmp/playhouse-ui-tart-${run_id}"
guest_log="${snapshot_root}/ui-test.log"
guest_artifacts="${artifact_root}/${run_id}"

export_early_failure() {
	status=$?
	mkdir -p "$snapshot_root" "$guest_tmp" "$guest_artifacts" 2>/dev/null || exit "$status"
	if [[ ! -f "$guest_log" ]]; then
		printf 'Guest UI runner exited before XCTest started (status %s).\n' "$status" > "$guest_log"
	fi
	ditto "$guest_log" "${guest_artifacts}/ui-test.log" >/dev/null 2>&1 || true
	printf '%s\n' "$status" > "${guest_artifacts}/exit-status.txt" 2>/dev/null || true
	exit "$status"
}
trap export_early_failure EXIT
mkdir -p "$snapshot_root" "$guest_tmp"
if ! mkdir -p "$guest_artifacts"; then
	printf 'Cannot create host artifact share path %s; guest run data is retained at %s.\n' "$guest_artifacts" "$snapshot_root" >&2
	exit 74
fi
if [[ ! -d "$source_root/Playhouse.xcodeproj" ]]; then
	printf 'Shared source directory is unavailable or missing Playhouse.xcodeproj: %s\n' "$source_root" >&2
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

if [[ -L "$source_snapshot_owner" ]]; then
	printf 'Refusing to use a symlink as the VM source snapshot ownership marker: %s\n' "$source_snapshot_owner" >&2
	exit 74
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
if ! rsync -a --exclude='.git' --exclude='DerivedData/' --exclude='build/' --exclude='*.xcresult/' --exclude='node_modules/' --exclude='.idea/' --exclude='xcuserdata/' --exclude='.tmp-*' --exclude='.e2e.lock' --exclude='*.profraw' --exclude='__pycache__/' --exclude='*.pyc' "${source_root}/" "${source_snapshot_root}/"; then
	printf 'Could not create the VM-local source snapshot; guest run data is retained at %s.\n' "$snapshot_root" >&2
	exit 74
fi
# The host's Git metadata is not copied (a linked worktree's .git file would point
# at an unmounted common directory anyway). The snapshot only needs local repository
# identity for app-profile.sh, so give this disposable copy its own metadata.
if [[ ! -d "${source_snapshot_root}/.git" ]]; then
	rm -f "${source_snapshot_root}/.git"
	git -C "$source_snapshot_root" init --quiet
fi
printf 'VM-local source snapshot: %s\n' "$source_snapshot_root"
printf 'Xcode: %s\n' "$(xcodebuild -version | tr '\n' ' ')"

# The base image restores a large Terminal window over newly launched apps.
# Close it so macOS UI automation sees the app's visible window consistently.
osascript -e 'tell application "Terminal" to quit' >/dev/null 2>&1 || true
# XCTest intentionally exercises process failures. Keep macOS crash reports in
# artifacts/logs instead of letting Diagnostics Reporter block later UI actions.
defaults write com.apple.CrashReporter DialogType none
pkill -x "Diagnostics Reporter" >/dev/null 2>&1 || true
sleep 2

if [[ -n "$live_provider" ]]; then
	printf '%s\n' "$live_provider" > /tmp/playhouse-live-ui-integration
	export PLAYHOUSE_RUN_LIVE_INTEGRATION=1
	export PLAYHOUSE_LIVE_PROVIDER="$live_provider"
fi
if (( reset_failed == 1 )); then
	printf 'Guest reset did not finish: an existing Playhouse or Xcode test process is still running.\n' | tee "$guest_log"
	test_status=74
else
	set +e
	PLAYHOUSE_UI_TART_GUEST=1 PLAYHOUSE_UI_TESTS_CONFIRMED=1 PLAYHOUSE_UI_DASHBOARD=0 TMPDIR="$guest_tmp" "${source_snapshot_root}/scripts/test-ui.sh" "$@" 2>&1 | tee "$guest_log"
	test_status=${PIPESTATUS[0]}
	set -e
fi
if [[ -n "$live_provider" ]]; then
	rm -f /tmp/playhouse-live-ui-integration
fi

artifact_copy_status=0
trap - EXIT
if ! ditto "$guest_log" "${guest_artifacts}/ui-test.log"; then
	printf 'Failed to copy the UI test log to the host artifact share.\n' >&2
	artifact_copy_status=1
fi
if [[ -n "${guest_tmp:-}" && -d "$guest_tmp" ]]; then
	while IFS= read -r -d '' test_output; do
		if ! ditto "$test_output" "${guest_artifacts}/$(basename "$test_output")"; then
			printf 'Failed to copy test output %s to the host artifact share.\n' "$test_output" >&2
			artifact_copy_status=1
		fi
	done < <(find "$guest_tmp" -maxdepth 1 -type d -name 'playhouse-ui.*' -print0)
fi
if ! printf '%s\n' "$test_status" > "${guest_artifacts}/exit-status.txt"; then
	printf 'Failed to write the UI test exit status to the host artifact share.\n' >&2
	artifact_copy_status=1
fi
if (( artifact_copy_status != 0 )); then
	printf 'Artifact export was incomplete; guest run data is retained at %s.\n' "$snapshot_root" >&2
	exit 74
fi
printf 'Host artifacts: %s\n' "$guest_artifacts"
if (( test_status != 0 )); then
	printf 'Failure diagnostics are attached in the xcresult bundles under %s.\n' "$guest_artifacts"
fi
rm -rf -- "$snapshot_root"
if [[ -n "${guest_tmp:-}" ]]; then
	rm -rf -- "$guest_tmp"
fi
exit "$test_status"
GUEST_SCRIPT
test_status=$?
set -e

printf 'Tart UI run artifacts: %s\n' "$run_artifacts"
exit "$test_status"
