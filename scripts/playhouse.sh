#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "${repository_root}/scripts/app-profile.sh"
playhouse_load_app_profile "${repository_root}"
app_bundle="${PLAYHOUSE_APP_PATH:-${PLAYHOUSE_PROFILE_DERIVED_DATA}/Build/Products/Debug/Playhouse.app}"
cli_path="${app_bundle}/Contents/MacOS/playhouse-cli"

if [[ -z "${PLAYHOUSE_APP_PATH:-}" && -z "$(playhouse_profile_processes)" ]]; then
  architecture="$(uname -m)"
  xcodebuild build -quiet \
    -project "${repository_root}/Playhouse.xcodeproj" \
    -scheme Playhouse \
    -configuration Debug \
    -destination "platform=macOS,arch=${architecture}" \
    -derivedDataPath "${PLAYHOUSE_PROFILE_DERIVED_DATA}" \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGN_IDENTITY=- \
    ARCHS="${architecture}" \
    ONLY_ACTIVE_ARCH=YES \
    PLAYHOUSE_APP_BUNDLE_IDENTIFIER="${PLAYHOUSE_PROFILE_BUNDLE_ID}"
elif [[ -z "${PLAYHOUSE_APP_PATH:-}" ]]; then
  printf 'Using this worktree’s running Playhouse build. Run scripts/run.sh to rebuild it.\n' >&2
fi
if [[ ! -x "${cli_path}" ]]; then
  printf 'Playhouse CLI was not found at %s. Build the app bundle first.\n' "${cli_path}" >&2
  exit 69
fi

PLAYHOUSE_DATA_DIRECTORY="$(python3 "${repository_root}/scripts/validate-app-launch.py" \
  "${app_bundle}" "${repository_root}" "${PLAYHOUSE_PROFILE_BUNDLE_ID}" "${PLAYHOUSE_PROFILE_DATA_DIRECTORY}")"
export PLAYHOUSE_DATA_DIRECTORY
# The CLI resolves its own bridge identity from the app bundle's Info.plist via
# `Bundle.main` (it lives at Contents/MacOS alongside the app executable), the
# same way the daemon does, so no separate `.xpc`-bundle lookup is needed here
# anymore. `PLAYHOUSE_BRIDGE_SERVICE_NAME` remains available as an override for
# test isolation, but this normal entry point doesn't need to set it.

exec "${cli_path}" "$@"
