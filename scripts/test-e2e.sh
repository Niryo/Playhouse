#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Headless runs use isolated fixtures and a cached build per worktree.
# Never take the shared UI/app lock here.
SECONDS=0
phase_start=0
phase="static"
report_phase() {
  printf 'E2E phase=%s elapsed_seconds=%s\n' "${phase}" "$((SECONDS - phase_start))" >&2
  phase_start=${SECONDS}
  phase="$1"
}
source "${repository_root}/scripts/app-profile.sh"
playhouse_load_app_profile "${repository_root}"

selected_cases=()
while (( $# > 0 )); do
  case "$1" in
    --case)
      if (( $# < 2 )) || [[ "$2" == --* ]]; then
        printf 'Expected a bridge test case ID after --case.\n' >&2
        exit 2
      fi
      selected_cases+=("$2")
      shift 2
      ;;
    *)
      printf 'Unknown argument: %s\nUsage: %s [--case test_case_id]...\n' "$1" "$0" >&2
      exit 2
      ;;
  esac
done

test_output_dir="$(mktemp -d /tmp/playhouse-bridge.XXXXXX)"
cleanup() {
  local status=$?
  report_phase finished
  printf 'E2E total_seconds=%s exit_status=%s\nBridge test artifacts: %s\n' "${SECONDS}" "${status}" "${test_output_dir}" >&2
}
trap cleanup EXIT
architecture="$(uname -m)"
python3 "${repository_root}/scripts/check-test-parity.py"
python3 "${repository_root}/scripts/check-button-feedback.py"
python3 "${repository_root}/scripts/check-e2e-locking.py"
python3 "${repository_root}/scripts/check-e2e-build-cache.py"
report_phase build
build_info="$(python3 "${repository_root}/scripts/prepare-e2e-build.py" \
  --root "${repository_root}" \
  --profile-bundle-id "${PLAYHOUSE_PROFILE_BUNDLE_ID}" \
  --architecture "${architecture}")"
report_phase fixture
derived_data_dir="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["derivedData"])' "${build_info}")"
e2e_bundle_identifier="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["bundleID"])' "${build_info}")"
app_bundle="${derived_data_dir}/Build/Products/Debug/Playhouse.app"
cli_path="${app_bundle}/Contents/MacOS/playhouse-cli"
data_root="${test_output_dir}/data"
fixture_root="${test_output_dir}/fixtures"
bridge_log="${test_output_dir}/bridge-tests.log"

# The build helper compiles the paired UI test target and reuses this
# content-matched DerivedData for focused retries and final full verification.
python3 "${repository_root}/scripts/prepare-e2e-fixture.py" --fixture-root "${fixture_root}"
legacy_store_seeder="${fixture_root}/seed-legacy-task-store"
xcrun swiftc -parse-as-library -swift-version 5 -O \
  "${repository_root}/scripts/seed-legacy-task-store.swift" \
  -o "${legacy_store_seeder}"
# Pure-logic unit checks of the Codex CPU working-directory attribution.
codex_cpu_attribution_tests="${test_output_dir}/codex-cpu-attribution-tests"
xcrun swiftc -parse-as-library -swift-version 5 -O \
  "${repository_root}/Playhouse/App/ProcessCPUSampler.swift" \
  "${repository_root}/scripts/unit/codex-cpu-attribution-tests.swift" \
  -o "${codex_cpu_attribution_tests}"
"${codex_cpu_attribution_tests}"
# Pure-logic unit checks of the agent usage payload parsing and reset rules.
agent_usage_parsing_tests="${test_output_dir}/agent-usage-parsing-tests"
xcrun swiftc -parse-as-library -swift-version 5 -O \
  "${repository_root}/Playhouse/App/AgentUsage.swift" \
  "${repository_root}/scripts/unit/agent-usage-parsing-tests.swift" \
  -o "${agent_usage_parsing_tests}"
"${agent_usage_parsing_tests}"
# Unit checks of the process host that lets provider agents outlive their daemon.
agent_run_host_tests="${test_output_dir}/agent-run-host-tests"
xcrun swiftc -parse-as-library -swift-version 5 -O \
  "${repository_root}/Playhouse/App/AgentRunHost.swift" \
  "${repository_root}/scripts/unit/agent-run-host-tests.swift" \
  -o "${agent_run_host_tests}"
"${agent_run_host_tests}"
if [[ ! -x "${cli_path}" ]]; then
  printf 'The app build did not produce its bundled CLI at %s.\n' "${cli_path}" >&2
  exit 1
fi

# The bridge daemon resolves its identity from the app's own Info.plist via
# `Bundle.main` (it ships flat in Contents/MacOS, no separate bundle anymore),
# so its service name is just the app's identifier plus the same ".bridge"
# suffix `BridgeContract.serviceName(forApplication:)` derives at runtime.
app_info="${app_bundle}/Contents/Info.plist"
service_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${app_info}").bridge"
bridge_arguments=(
  "${repository_root}/scripts/test-bridge.py"
  --cli "${cli_path}"
  --fixture-root "${fixture_root}"
  --data-root "${data_root}"
  --service-name "${service_name}"
  --legacy-store-seeder "${legacy_store_seeder}"
)
if (( ${#selected_cases[@]} > 0 )); then
  for selected_case in "${selected_cases[@]}"; do
    bridge_arguments+=(--case "${selected_case}")
  done
fi

report_phase cases
set +e
# Reused builds share an XPC identity and process-global diagnostics routing.
# Serialize only callers of that exact cached build, never unrelated worktrees/UI.
python3 "${repository_root}/scripts/with-file-lock.py" "${derived_data_dir}/.bridge-run.lock" \
  python3 "${bridge_arguments[@]}" 2>&1 | tee "${bridge_log}"
bridge_status="${PIPESTATUS[0]}"
set -e
if (( bridge_status != 0 )); then
  printf 'The CLI/XPC bridge suite failed; full output: %s\n' "${bridge_log}" >&2
  exit "${bridge_status}"
fi

printf 'Playhouse CLI/XPC bridge verification passed without launching the UI.\n'
