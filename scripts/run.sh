#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
derived_data_dir="${TMPDIR:-/tmp}/StationAI-DerivedData"
architecture="$(uname -m)"

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

app_bundle="${derived_data_dir}/Build/Products/Debug/StationAI.app"
if [[ -n "${STATIONAI_DATA_DIRECTORY:-}" ]]; then
  open -n --env "STATIONAI_DATA_DIRECTORY=${STATIONAI_DATA_DIRECTORY}" "${app_bundle}"
else
  open -a "${app_bundle}"
fi
