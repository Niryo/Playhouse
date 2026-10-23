#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repository_root}/scripts/app-profile.sh"
stationai_load_app_profile "${repository_root}"
if [[ "${STATIONAI_RUN_CODEX_INTEGRATION:-}" != "1" ]]; then
  printf 'Set STATIONAI_RUN_CODEX_INTEGRATION=1 to run live Codex turns.\n' >&2
  exit 2
fi
if [[ "${STATIONAI_UI_TESTS_CONFIRMED:-0}" != "1" ]]; then
  bash "${repository_root}/scripts/confirm-ui-tests.sh"
fi
export STATIONAI_UI_TESTS_CONFIRMED=1

bash -c '
  set -euo pipefail
  repository_root="$1"
  integration_key="$(python3 -c '\''import uuid; print(uuid.uuid4().hex)'\'')"
  fixture_root="${STATIONAI_BRIDGE_TEST_FIXTURE_ROOT:-${TMPDIR:-/tmp}/stationai-codex-integration-${integration_key}-fixture}"
  derived_data="${TMPDIR:-/tmp}/StationAI-Codex-Integration-${integration_key}"
  export STATIONAI_BRIDGE_TEST_FIXTURE_ROOT="${fixture_root}"
  app_bundle="${STATIONAI_APP_PATH:-${derived_data}/Build/Products/Debug/StationAI.app}"
  if [[ -z "${STATIONAI_APP_PATH:-}" ]]; then
    architecture="$(uname -m)"
    xcodebuild build -quiet \
      -project "${repository_root}/StationAI.xcodeproj" \
      -scheme StationAI \
      -configuration Debug \
      -destination "platform=macOS,arch=${architecture}" \
      -derivedDataPath "${derived_data}" \
      CODE_SIGNING_ALLOWED=YES \
      CODE_SIGN_IDENTITY=- \
      ARCHS="${architecture}" \
      ONLY_ACTIVE_ARCH=YES \
      STATIONAI_APP_BUNDLE_IDENTIFIER="${STATIONAI_PROFILE_BUNDLE_ID}.e2e.codexintegration.${integration_key}"
  fi
  export STATIONAI_APP_PATH="${app_bundle}"
  test -x "${app_bundle}/Contents/MacOS/stationai-cli"
  python3 "${repository_root}/scripts/prepare-e2e-fixture.py" --fixture-root "${fixture_root}"
  python3 "${repository_root}/scripts/test-codex-integration.py"
  STATIONAI_UI_TESTS_CONFIRMED=1 "${repository_root}/scripts/test-ui.sh" --case test_conversation_composer_rejects_blank_and_supports_live_turn_controls
  STATIONAI_UI_TESTS_CONFIRMED=1 "${repository_root}/scripts/test-ui.sh" --case test_thread_goal_lifecycle_persists_through_cli_xpc
  STATIONAI_UI_TESTS_CONFIRMED=1 "${repository_root}/scripts/test-ui.sh" --case test_task_worktree_preparation_serializes_auto_branch_claims
' -- "${repository_root}"
