#!/usr/bin/env bash
set -euo pipefail

vm_name="${STATIONAI_UI_TART_VM:-stationai-ui}"
image="${STATIONAI_UI_TART_IMAGE:-ghcr.io/cirruslabs/macos-tahoe-xcode:26.5}"
tart_home="${TART_HOME:-${HOME}/.tart}"
minimum_free_kib=$((110 * 1024 * 1024))

if ! command -v tart >/dev/null 2>&1; then
	printf 'Tart is required but was not found in PATH.\n' >&2
	exit 1
fi

mkdir -p "$tart_home"

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
fi

tart set "$vm_name" --cpu 6 --memory 12288 --display 2560x1600
printf 'Tart UI test VM ready: %s\n' "$vm_name"
printf 'Run a focused case with: scripts/test-ui-tart.sh --case <case-id>\n'
