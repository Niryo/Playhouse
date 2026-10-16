#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
derived_data_dir="${TMPDIR:-/tmp}/StationAI-DerivedData"
architecture="$(uname -m)"
app_bundle="${derived_data_dir}/Build/Products/Debug/StationAI.app"
app_executable="${app_bundle}/Contents/MacOS/StationAI"

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
  ONLY_ACTIVE_ARCH=YES

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
if [[ -n "${STATIONAI_DATA_DIRECTORY:-}" ]]; then
  open -n --env "STATIONAI_DATA_DIRECTORY=${STATIONAI_DATA_DIRECTORY}" "${app_bundle}"
else
  open -n -a "${app_bundle}"
fi
