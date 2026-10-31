#!/usr/bin/env bash
set -euo pipefail

# Source this file and call playhouse_load_app_profile from launch scripts.
# Running it directly prints the profile for diagnostics and test fixtures.
playhouse_load_app_profile() {
  local requested_root="${1:?Expected a Playhouse source worktree path}"
  local common_git_dir primary_root profile_hash
  PLAYHOUSE_PROFILE_ROOT="$(cd "${requested_root}" && pwd -P)"
  common_git_dir="$(git -C "${PLAYHOUSE_PROFILE_ROOT}" rev-parse --git-common-dir)"
  if [[ "${common_git_dir}" != /* ]]; then
    common_git_dir="${PLAYHOUSE_PROFILE_ROOT}/${common_git_dir}"
  fi
  common_git_dir="$(cd "${common_git_dir}" && pwd -P)"
  primary_root="$(cd "${common_git_dir}/.." && pwd -P)"

  if [[ "${PLAYHOUSE_PROFILE_ROOT}" == "${primary_root}" ]]; then
    PLAYHOUSE_PROFILE_KIND="primary"
    PLAYHOUSE_PROFILE_KEY="primary"
    PLAYHOUSE_PROFILE_BUNDLE_ID="com.playhouse.app"
    PLAYHOUSE_PROFILE_DERIVED_DATA="${TMPDIR:-/tmp}"
    PLAYHOUSE_PROFILE_DERIVED_DATA="${PLAYHOUSE_PROFILE_DERIVED_DATA%/}/Playhouse-DerivedData"
    PLAYHOUSE_PROFILE_DATA_DIRECTORY="${HOME}/Library/Application Support/Playhouse"
    PLAYHOUSE_PROFILE_LOG_FILE="${HOME}/Library/Logs/Playhouse/Diagnostics.jsonl"
    PLAYHOUSE_PROFILE_WORKTREE_ROOT="${PLAYHOUSE_PROFILE_DATA_DIRECTORY}/task-worktrees"
  else
    profile_hash="$(printf '%s' "${PLAYHOUSE_PROFILE_ROOT}" | shasum -a 256 | cut -c 1-16)"
    PLAYHOUSE_PROFILE_KIND="linked"
    PLAYHOUSE_PROFILE_KEY="w${profile_hash}"
    PLAYHOUSE_PROFILE_BUNDLE_ID="com.playhouse.app.worktree.${PLAYHOUSE_PROFILE_KEY}"
    PLAYHOUSE_PROFILE_DERIVED_DATA="${TMPDIR:-/tmp}"
    PLAYHOUSE_PROFILE_DERIVED_DATA="${PLAYHOUSE_PROFILE_DERIVED_DATA%/}/Playhouse-DerivedData-${PLAYHOUSE_PROFILE_KEY}"
    PLAYHOUSE_PROFILE_DATA_DIRECTORY="${HOME}/Library/Application Support/Playhouse/Worktrees/${PLAYHOUSE_PROFILE_KEY}"
    PLAYHOUSE_PROFILE_LOG_FILE="${PLAYHOUSE_PROFILE_DATA_DIRECTORY}/Diagnostics.jsonl"
    PLAYHOUSE_PROFILE_WORKTREE_ROOT="${PLAYHOUSE_PROFILE_DATA_DIRECTORY}/task-worktrees"
  fi
  PLAYHOUSE_PROFILE_BRIDGE_ID="${PLAYHOUSE_PROFILE_BUNDLE_ID}.bridge"
  export PLAYHOUSE_PROFILE_ROOT PLAYHOUSE_PROFILE_KIND PLAYHOUSE_PROFILE_KEY
  export PLAYHOUSE_PROFILE_BUNDLE_ID PLAYHOUSE_PROFILE_BRIDGE_ID PLAYHOUSE_PROFILE_DERIVED_DATA
  export PLAYHOUSE_PROFILE_DATA_DIRECTORY PLAYHOUSE_PROFILE_LOG_FILE PLAYHOUSE_PROFILE_WORKTREE_ROOT
}

playhouse_verify_build_identity() {
  local bundle_id="${1:?Expected the app bundle identifier}"
  if [[ "${bundle_id}" == "${PLAYHOUSE_PROFILE_BUNDLE_ID}" ||
        "${bundle_id}" == "${PLAYHOUSE_PROFILE_BUNDLE_ID}".e2e.* ]]; then
    return 0
  fi
  printf 'Bundle ID %s does not match this worktree profile (%s). Build with scripts/run.sh or pass PLAYHOUSE_APP_BUNDLE_IDENTIFIER=%s.\n' \
    "${bundle_id}" "${PLAYHOUSE_PROFILE_ROOT}" "${PLAYHOUSE_PROFILE_BUNDLE_ID}" >&2
  return 1
}

# Return only GUI and XPC processes launched from the selected worktree's app.
playhouse_profile_processes() {
  local app_bundle="${PLAYHOUSE_PROFILE_DERIVED_DATA}/Build/Products/Debug/Playhouse.app"
  local process_name process_id process_command
  if [[ "${app_bundle}" == /private/var/* ]]; then
    app_bundle="/var/${app_bundle#/private/var/}"
  fi
  for process_name in Playhouse PlayhouseBridge; do
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
  playhouse_load_app_profile "$1"
  python3 - <<'PY'
import json
import os
print(json.dumps({
    "root": os.environ["PLAYHOUSE_PROFILE_ROOT"],
    "kind": os.environ["PLAYHOUSE_PROFILE_KIND"],
    "key": os.environ["PLAYHOUSE_PROFILE_KEY"],
    "bundleID": os.environ["PLAYHOUSE_PROFILE_BUNDLE_ID"],
    "bridgeID": os.environ["PLAYHOUSE_PROFILE_BRIDGE_ID"],
    "derivedData": os.environ["PLAYHOUSE_PROFILE_DERIVED_DATA"],
    "dataDirectory": os.environ["PLAYHOUSE_PROFILE_DATA_DIRECTORY"],
    "logFile": os.environ["PLAYHOUSE_PROFILE_LOG_FILE"],
    "worktreeRoot": os.environ["PLAYHOUSE_PROFILE_WORKTREE_ROOT"],
}, sort_keys=True))
PY
fi
