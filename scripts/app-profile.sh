#!/usr/bin/env bash
set -euo pipefail

# Source this file and call stationai_load_app_profile from launch scripts.
# Running it directly prints the profile for diagnostics and test fixtures.
stationai_load_app_profile() {
  local requested_root="${1:?Expected a StationAI source worktree path}"
  local common_git_dir primary_root profile_hash
  STATIONAI_PROFILE_ROOT="$(cd "${requested_root}" && pwd -P)"
  common_git_dir="$(git -C "${STATIONAI_PROFILE_ROOT}" rev-parse --git-common-dir)"
  if [[ "${common_git_dir}" != /* ]]; then
    common_git_dir="${STATIONAI_PROFILE_ROOT}/${common_git_dir}"
  fi
  common_git_dir="$(cd "${common_git_dir}" && pwd -P)"
  primary_root="$(cd "${common_git_dir}/.." && pwd -P)"

  if [[ "${STATIONAI_PROFILE_ROOT}" == "${primary_root}" ]]; then
    STATIONAI_PROFILE_KIND="primary"
    STATIONAI_PROFILE_KEY="primary"
    STATIONAI_PROFILE_BUNDLE_ID="com.stationai.app"
    STATIONAI_PROFILE_DERIVED_DATA="${TMPDIR:-/tmp}"
    STATIONAI_PROFILE_DERIVED_DATA="${STATIONAI_PROFILE_DERIVED_DATA%/}/StationAI-DerivedData"
    STATIONAI_PROFILE_DATA_DIRECTORY="${HOME}/Library/Application Support/StationAI"
    STATIONAI_PROFILE_LOG_FILE="${HOME}/Library/Logs/StationAI/Diagnostics.jsonl"
    STATIONAI_PROFILE_WORKTREE_ROOT="${HOME}/.stationAI/worktrees"
  else
    profile_hash="$(printf '%s' "${STATIONAI_PROFILE_ROOT}" | shasum -a 256 | cut -c 1-16)"
    STATIONAI_PROFILE_KIND="linked"
    STATIONAI_PROFILE_KEY="w${profile_hash}"
    STATIONAI_PROFILE_BUNDLE_ID="com.stationai.app.worktree.${STATIONAI_PROFILE_KEY}"
    STATIONAI_PROFILE_DERIVED_DATA="${TMPDIR:-/tmp}"
    STATIONAI_PROFILE_DERIVED_DATA="${STATIONAI_PROFILE_DERIVED_DATA%/}/StationAI-DerivedData-${STATIONAI_PROFILE_KEY}"
    STATIONAI_PROFILE_DATA_DIRECTORY="${HOME}/Library/Application Support/StationAI/Worktrees/${STATIONAI_PROFILE_KEY}"
    STATIONAI_PROFILE_LOG_FILE="${STATIONAI_PROFILE_DATA_DIRECTORY}/Diagnostics.jsonl"
    STATIONAI_PROFILE_WORKTREE_ROOT="${HOME}/.stationAI/worktrees/${STATIONAI_PROFILE_KEY}"
  fi
  STATIONAI_PROFILE_BRIDGE_ID="${STATIONAI_PROFILE_BUNDLE_ID}.bridge"
  export STATIONAI_PROFILE_ROOT STATIONAI_PROFILE_KIND STATIONAI_PROFILE_KEY
  export STATIONAI_PROFILE_BUNDLE_ID STATIONAI_PROFILE_BRIDGE_ID STATIONAI_PROFILE_DERIVED_DATA
  export STATIONAI_PROFILE_DATA_DIRECTORY STATIONAI_PROFILE_LOG_FILE STATIONAI_PROFILE_WORKTREE_ROOT
}

stationai_verify_build_identity() {
  local bundle_id="${1:?Expected the app bundle identifier}"
  if [[ "${bundle_id}" == "${STATIONAI_PROFILE_BUNDLE_ID}" ||
        "${bundle_id}" == com.stationai.app.e2e.* ||
        "${bundle_id}" == "${STATIONAI_PROFILE_BUNDLE_ID}".e2e.* ||
        "${bundle_id}" =~ ^com\.stationai\.app\.worktree\.w[0-9a-f]{16}\.e2e\.[a-z0-9.]+$ ]]; then
    return 0
  fi
  printf 'Bundle ID %s does not match this worktree profile (%s). Build with scripts/run.sh or pass STATIONAI_APP_BUNDLE_IDENTIFIER=%s.\n' \
    "${bundle_id}" "${STATIONAI_PROFILE_ROOT}" "${STATIONAI_PROFILE_BUNDLE_ID}" >&2
  return 1
}

# Return only GUI and XPC processes launched from the selected worktree's app.
stationai_profile_processes() {
  local app_bundle="${STATIONAI_PROFILE_DERIVED_DATA}/Build/Products/Debug/StationAI.app"
  local process_name process_id process_command
  if [[ "${app_bundle}" == /private/var/* ]]; then
    app_bundle="/var/${app_bundle#/private/var/}"
  fi
  for process_name in StationAI StationAIBridge; do
    while IFS= read -r process_id; do
      [[ -n "${process_id}" ]] || continue
      process_command="$(ps -p "${process_id}" -o command= 2>/dev/null || true)"
      if [[ "${process_command}" == /private/var/* ]]; then
        process_command="/var/${process_command#/private/var/}"
      fi
      if [[ "${process_command}" == "${app_bundle}/Contents/"* ]]; then
        printf '%s\n' "${process_id}"
      fi
    done < <(pgrep -x "${process_name}" || true)
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  if (( $# != 1 )); then
    printf 'Usage: %s <source-worktree>\n' "$0" >&2
    exit 2
  fi
  stationai_load_app_profile "$1"
  python3 - <<'PY'
import json
import os
print(json.dumps({
    "root": os.environ["STATIONAI_PROFILE_ROOT"],
    "kind": os.environ["STATIONAI_PROFILE_KIND"],
    "key": os.environ["STATIONAI_PROFILE_KEY"],
    "bundleID": os.environ["STATIONAI_PROFILE_BUNDLE_ID"],
    "bridgeID": os.environ["STATIONAI_PROFILE_BRIDGE_ID"],
    "derivedData": os.environ["STATIONAI_PROFILE_DERIVED_DATA"],
    "dataDirectory": os.environ["STATIONAI_PROFILE_DATA_DIRECTORY"],
    "logFile": os.environ["STATIONAI_PROFILE_LOG_FILE"],
    "worktreeRoot": os.environ["STATIONAI_PROFILE_WORKTREE_ROOT"],
}, sort_keys=True))
PY
fi
