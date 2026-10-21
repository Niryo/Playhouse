#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "${repository_root}/scripts/app-profile.sh"
stationai_load_app_profile "${repository_root}"
derived_data_dir="${STATIONAI_PROFILE_DERIVED_DATA}"
architecture="$(uname -m)"
app_bundle="${derived_data_dir}/Build/Products/Debug/StationAI.app"
app_executable="${app_bundle}/Contents/MacOS/StationAI"
if [[ "${STATIONAI_PROFILE_KIND}" == "linked" && -n "${STATIONAI_DATA_DIRECTORY:-}" && "${STATIONAI_DATA_DIRECTORY}" != "${STATIONAI_PROFILE_DATA_DIRECTORY}" ]]; then
  printf 'run.sh uses this worktree’s isolated data directory; STATIONAI_DATA_DIRECTORY points elsewhere.\n' >&2
  exit 2
fi
launch_data_directory="${STATIONAI_DATA_DIRECTORY:-${STATIONAI_PROFILE_DATA_DIRECTORY}}"

terminate_running_stationai() {
  local running_pids process_id attempt
  running_pids="$(stationai_profile_processes)"
  if [[ -z "${running_pids}" ]]; then
    return
  fi

  printf 'Closing StationAI instance(s) from this worktree before rebuilding...\n'
  while IFS= read -r process_id; do
    if [[ -n "${process_id}" ]]; then
      kill -TERM "${process_id}" 2>/dev/null || true
    fi
  done <<< "${running_pids}"

  for ((attempt = 0; attempt < 50; attempt++)); do
    if [[ -z "$(stationai_profile_processes)" ]]; then
      return
    fi
    sleep 0.1
  done

  running_pids="$(stationai_profile_processes)"
  if [[ -n "${running_pids}" ]]; then
    printf 'StationAI did not exit after SIGTERM; forcing it to stop.\n' >&2
    while IFS= read -r process_id; do
      if [[ -n "${process_id}" ]]; then
        kill -KILL "${process_id}" 2>/dev/null || true
      fi
    done <<< "${running_pids}"

    for ((attempt = 0; attempt < 20; attempt++)); do
      if [[ -z "$(stationai_profile_processes)" ]]; then
        return
      fi
      sleep 0.1
    done
    printf 'Could not stop the running StationAI process(es).\n' >&2
    return 1
  fi
}

terminate_running_stationai

# Older builds placed the lowercase CLI at Contents/MacOS/stationai. On the
# default case-insensitive macOS filesystem that replaced the GUI executable.
if [[ -f "${app_executable}" ]] && /usr/bin/strings "${app_executable}" | /usr/bin/grep -Fq 'StationAI CLI (uses the XPC service bundled in StationAI.app)'; then
  rm -f "${app_executable}"
fi

xcodebuild build -quiet \
  -project "${repository_root}/StationAI.xcodeproj" \
  -scheme StationAI \
  -configuration Debug \
  -destination "platform=macOS,arch=${architecture}" \
  -derivedDataPath "${derived_data_dir}" \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGN_IDENTITY=- \
  ARCHS="${architecture}" \
  ONLY_ACTIVE_ARCH=YES \
  STATIONAI_APP_BUNDLE_IDENTIFIER="${STATIONAI_PROFILE_BUNDLE_ID}"

app_executable_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "${app_bundle}/Contents/Info.plist")"
app_executable="${app_bundle}/Contents/MacOS/${app_executable_name}"
cli_executable="${app_bundle}/Contents/MacOS/stationai-cli"
if [[ ! -x "${app_executable}" ]]; then
  printf 'StationAI app executable is missing: %s\n' "${app_executable}" >&2
  exit 1
fi
if [[ ! -x "${cli_executable}" ]]; then
  printf 'StationAI CLI was not embedded: %s\n' "${cli_executable}" >&2
  exit 1
fi
if [[ "${app_executable}" -ef "${cli_executable}" ]]; then
  printf 'StationAI CLI and app executable resolve to the same file: %s\n' "${app_executable}" >&2
  exit 1
fi
open -n --env "STATIONAI_DATA_DIRECTORY=${launch_data_directory}" "${app_bundle}"
