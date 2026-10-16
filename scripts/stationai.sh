#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_bundle="${STATIONAI_APP_PATH:-${TMPDIR:-/tmp}/StationAI-DerivedData/Build/Products/Debug/StationAI.app}"
cli_path="${app_bundle}/Contents/MacOS/stationai-cli"

if [[ -z "${STATIONAI_APP_PATH:-}" ]]; then
  architecture="$(uname -m)"
  xcodebuild build -quiet \
    -project "${repository_root}/StationAI.xcodeproj" \
    -scheme StationAI \
    -configuration Debug \
    -destination "platform=macOS,arch=${architecture}" \
    -derivedDataPath "${TMPDIR:-/tmp}/StationAI-DerivedData" \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGN_IDENTITY=- \
    ARCHS="${architecture}" \
    ONLY_ACTIVE_ARCH=YES
fi
if [[ ! -x "${cli_path}" ]]; then
  printf 'StationAI CLI was not found at %s. Build the app bundle first.\n' "${cli_path}" >&2
  exit 69
fi

if [[ -z "${STATIONAI_BRIDGE_SERVICE_NAME:-}" ]]; then
  service_info="${app_bundle}/Contents/XPCServices/StationAIBridge.xpc/Contents/Info.plist"
  export STATIONAI_BRIDGE_SERVICE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${service_info}")"
fi

exec "${repository_root}/scripts/with-e2e-lock.sh" -- "${cli_path}" "$@"
