#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "${repository_root}/scripts/app-profile.sh"
stationai_load_app_profile "${repository_root}"
app_bundle="${STATIONAI_APP_PATH:-${STATIONAI_PROFILE_DERIVED_DATA}/Build/Products/Debug/StationAI.app}"
cli_path="${app_bundle}/Contents/MacOS/stationai-cli"

if [[ -z "${STATIONAI_APP_PATH:-}" && -z "$(stationai_profile_processes)" ]]; then
  architecture="$(uname -m)"
  xcodebuild build -quiet \
    -project "${repository_root}/StationAI.xcodeproj" \
    -scheme StationAI \
    -configuration Debug \
    -destination "platform=macOS,arch=${architecture}" \
    -derivedDataPath "${STATIONAI_PROFILE_DERIVED_DATA}" \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGN_IDENTITY=- \
    ARCHS="${architecture}" \
    ONLY_ACTIVE_ARCH=YES \
    STATIONAI_APP_BUNDLE_IDENTIFIER="${STATIONAI_PROFILE_BUNDLE_ID}"
elif [[ -z "${STATIONAI_APP_PATH:-}" ]]; then
  printf 'Using this worktree’s running StationAI build. Run scripts/run.sh to rebuild it.\n' >&2
fi
if [[ ! -x "${cli_path}" ]]; then
  printf 'StationAI CLI was not found at %s. Build the app bundle first.\n' "${cli_path}" >&2
  exit 69
fi

STATIONAI_DATA_DIRECTORY="$(python3 "${repository_root}/scripts/validate-app-launch.py" \
  "${app_bundle}" "${repository_root}" "${STATIONAI_PROFILE_BUNDLE_ID}" "${STATIONAI_PROFILE_DATA_DIRECTORY}")"
export STATIONAI_DATA_DIRECTORY
service_info="${app_bundle}/Contents/XPCServices/StationAIBridge.xpc/Contents/Info.plist"
export STATIONAI_BRIDGE_SERVICE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${service_info}")"

exec "${repository_root}/scripts/with-e2e-lock.sh" -- "${cli_path}" "$@"
