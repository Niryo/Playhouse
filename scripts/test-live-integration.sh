#!/usr/bin/env bash
# Live integration suite against real installed providers.
#   PLAYHOUSE_RUN_LIVE_INTEGRATION=1 scripts/test-live-integration.sh [--provider claude|codex|opencode|all] [--skip-ui]
# PLAYHOUSE_LIVE_PROVIDER selects the provider when --provider is omitted (default: claude).
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repository_root}/scripts/app-profile.sh"
playhouse_load_app_profile "${repository_root}"
provider="${PLAYHOUSE_LIVE_PROVIDER:-claude}"
skip_ui=0
while (( $# > 0 )); do
  case "$1" in
    --provider) provider="${2:?Expected claude, codex, opencode, or all after --provider}"; shift 2 ;;
    --skip-ui) skip_ui=1; shift ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done
if [[ "${PLAYHOUSE_RUN_LIVE_INTEGRATION:-}" != "1" && "${PLAYHOUSE_RUN_CODEX_INTEGRATION:-}" != "1" ]]; then
  printf 'Set PLAYHOUSE_RUN_LIVE_INTEGRATION=1 to run live provider turns.\n' >&2
  exit 2
fi
if [[ "$provider" != claude && "$provider" != codex && "$provider" != opencode && "$provider" != all ]]; then
  printf 'Unknown provider: %s (use claude, codex, opencode, or all)\n' "$provider" >&2
  exit 2
fi
if (( skip_ui == 0 )) && [[ "${PLAYHOUSE_UI_TESTS_CONFIRMED:-0}" != "1" ]]; then
  bash "${repository_root}/scripts/confirm-ui-tests.sh"
fi
export PLAYHOUSE_UI_TESTS_CONFIRMED=1 PLAYHOUSE_RUN_LIVE_INTEGRATION=1

integration_key="$(python3 -c 'import uuid; print(uuid.uuid4().hex)')"
fixture_root="${PLAYHOUSE_BRIDGE_TEST_FIXTURE_ROOT:-${TMPDIR:-/tmp}/playhouse-live-integration-${integration_key}-fixture}"
export PLAYHOUSE_BRIDGE_TEST_FIXTURE_ROOT="${fixture_root}"
# Reuse the worktree's content-matched E2E build instead of compiling the app from scratch on
# every run. Runs of one cached build share its bridge identity, so they take turns on its
# .bridge-run.lock, as scripts/test-e2e.sh does; each run still has its own data directory.
bridge_run_lock=()
if [[ -z "${PLAYHOUSE_APP_PATH:-}" ]]; then
  build_info="$(python3 "${repository_root}/scripts/prepare-e2e-build.py" \
    --root "${repository_root}" \
    --profile-bundle-id "${PLAYHOUSE_PROFILE_BUNDLE_ID}" \
    --architecture "$(uname -m)")"
  derived_data="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["derivedData"])' "${build_info}")"
  PLAYHOUSE_APP_PATH="${derived_data}/Build/Products/Debug/Playhouse.app"
  bridge_run_lock=(python3 "${repository_root}/scripts/with-file-lock.py" "${derived_data}/.bridge-run.lock")
fi
app_bundle="${PLAYHOUSE_APP_PATH}"
export PLAYHOUSE_APP_PATH
test -x "${app_bundle}/Contents/MacOS/playhouse-cli"
python3 "${repository_root}/scripts/prepare-e2e-fixture.py" --fixture-root "${fixture_root}"
${bridge_run_lock[@]+"${bridge_run_lock[@]}"} python3 "${repository_root}/scripts/test-live-integration.py" --provider "${provider}"
if (( skip_ui == 1 )); then
  printf 'Skipped live UI cases (--skip-ui).\n'
  exit 0
fi
ui_providers=("$provider")
[[ "$provider" == all ]] && ui_providers=(claude codex)
for ui_provider in "${ui_providers[@]}"; do
  # Shared live UI cases run for every provider; Goal is Codex-only.
  ui_cases=(test_conversation_composer_rejects_blank_and_supports_live_turn_controls test_task_worktree_preparation_serializes_auto_branch_claims)
  [[ "$ui_provider" == codex ]] && ui_cases+=(test_thread_goal_lifecycle_persists_through_cli_xpc)
  for ui_case in "${ui_cases[@]}"; do
    PLAYHOUSE_LIVE_PROVIDER="${ui_provider}" "${repository_root}/scripts/test-ui.sh" --case "${ui_case}"
  done
done
