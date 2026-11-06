#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "${repository_root}/scripts/app-profile.sh"
playhouse_load_app_profile "${repository_root}"
derived_data_dir="${PLAYHOUSE_PROFILE_DERIVED_DATA}"
architecture="$(uname -m)"
app_bundle="${derived_data_dir}/Build/Products/Debug/Playhouse.app"
app_executable="${app_bundle}/Contents/MacOS/Playhouse"
launch_data_directory="$(playhouse_resolve_launch_data_directory)" || exit 2
worktree_label="$(git -C "${repository_root}" branch --show-current)"
if [[ -z "${worktree_label}" ]]; then
  worktree_label="$(basename "${repository_root}")"
fi

terminate_running_playhouse() {
  local running_pids process_id attempt
  running_pids="$(playhouse_profile_processes)"
  if [[ -z "${running_pids}" ]]; then
    return
  fi

  printf 'Closing Playhouse instance(s) from this worktree before rebuilding...\n'
  while IFS= read -r process_id; do
    if [[ -n "${process_id}" ]]; then
      kill -TERM "${process_id}" 2>/dev/null || true
    fi
  done <<< "${running_pids}"

  for ((attempt = 0; attempt < 50; attempt++)); do
    if [[ -z "$(playhouse_profile_processes)" ]]; then
      return
    fi
    sleep 0.1
  done

  running_pids="$(playhouse_profile_processes)"
  if [[ -n "${running_pids}" ]]; then
    printf 'Playhouse did not exit after SIGTERM; forcing it to stop.\n' >&2
    while IFS= read -r process_id; do
      if [[ -n "${process_id}" ]]; then
        kill -KILL "${process_id}" 2>/dev/null || true
      fi
    done <<< "${running_pids}"

    for ((attempt = 0; attempt < 20; attempt++)); do
      if [[ -z "$(playhouse_profile_processes)" ]]; then
        return
      fi
      sleep 0.1
    done
    printf 'Could not stop the running Playhouse process(es).\n' >&2
    return 1
  fi
}

terminate_running_playhouse

# Older builds placed the lowercase CLI at Contents/MacOS/playhouse. On the
# default case-insensitive macOS filesystem that replaced the GUI executable.
if [[ -f "${app_executable}" ]] && /usr/bin/strings "${app_executable}" | /usr/bin/grep -Fq 'Playhouse CLI (uses the XPC service bundled in Playhouse.app)'; then
  rm -f "${app_executable}"
fi

xcodebuild build -quiet \
  -project "${repository_root}/Playhouse.xcodeproj" \
  -scheme Playhouse \
  -configuration Debug \
  -destination "platform=macOS,arch=${architecture}" \
  -derivedDataPath "${derived_data_dir}" \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGN_IDENTITY=- \
  ARCHS="${architecture}" \
  ONLY_ACTIVE_ARCH=YES \
  PLAYHOUSE_APP_BUNDLE_IDENTIFIER="${PLAYHOUSE_PROFILE_BUNDLE_ID}"

app_executable_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "${app_bundle}/Contents/Info.plist")"
app_executable="${app_bundle}/Contents/MacOS/${app_executable_name}"
cli_executable="${app_bundle}/Contents/MacOS/playhouse-cli"
if [[ ! -x "${app_executable}" ]]; then
  printf 'Playhouse app executable is missing: %s\n' "${app_executable}" >&2
  exit 1
fi
if [[ ! -x "${cli_executable}" ]]; then
  printf 'Playhouse CLI was not embedded: %s\n' "${cli_executable}" >&2
  exit 1
fi
if [[ "${app_executable}" -ef "${cli_executable}" ]]; then
  printf 'Playhouse CLI and app executable resolve to the same file: %s\n' "${app_executable}" >&2
  exit 1
fi
playhouse_clear_inherited_bridge_overrides
open -n \
  --env "PLAYHOUSE_DATA_DIRECTORY=${launch_data_directory}" \
  --env "PLAYHOUSE_WORKTREE_LABEL=${worktree_label}" \
  "${app_bundle}"
