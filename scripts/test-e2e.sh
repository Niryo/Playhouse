#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_output_dir="$(mktemp -d "${TMPDIR:-/tmp}/stationai-e2e.XXXXXX")"
architecture="$(uname -m)"

"${repository_root}/scripts/with-e2e-lock.sh" -- xcodebuild test -quiet \
  -project "${repository_root}/StationAI.xcodeproj" \
  -scheme StationAI \
  -destination "platform=macOS,arch=${architecture}" \
  -derivedDataPath "${test_output_dir}/DerivedData" \
  -resultBundlePath "${test_output_dir}/StationAI.xcresult" \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGN_IDENTITY=- \
  ARCHS="${architecture}" \
  ONLY_ACTIVE_ARCH=YES

printf 'End-to-end result bundle: %s\n' "${test_output_dir}/StationAI.xcresult"
