#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "${STATIONAI_RUN_CODEX_INTEGRATION:-}" != "1" ]]; then
  printf 'Set STATIONAI_RUN_CODEX_INTEGRATION=1 to run live Codex turns.\n' >&2
  exit 2
fi

"${repository_root}/scripts/with-e2e-lock.sh" -- bash -c '
  set -euo pipefail
  repository_root="$1"
  app_bundle="${STATIONAI_APP_PATH:-${TMPDIR:-/tmp}/StationAI-DerivedData/Build/Products/Debug/StationAI.app}"
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
  export STATIONAI_APP_PATH="${app_bundle}"
  test -x "${app_bundle}/Contents/MacOS/stationai-cli"
  python3 "${repository_root}/scripts/prepare-e2e-fixture.py"
  python3 "${repository_root}/scripts/test-codex-integration.py"
  "${repository_root}/scripts/test-ui.sh" --locked --case test_conversation_composer_rejects_blank_and_supports_live_turn_controls
' -- "${repository_root}"
