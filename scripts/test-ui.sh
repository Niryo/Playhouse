#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script_path="${repository_root}/scripts/test-ui.sh"

if [[ "${1:-}" != "--locked" ]]; then
	exec "${repository_root}/scripts/with-e2e-lock.sh" -- bash "${script_path}" --locked "$@"
fi
shift

ui_cases=()
while (( $# > 0 )); do
  case "$1" in
    --case)
      if (( $# < 2 )) || [[ "$2" == --* ]]; then
        printf 'Expected a test case ID after --case.\n' >&2
        exit 2
      fi
      ui_cases+=("$2")
      shift 2
      ;;
    *)
      printf 'Unknown argument: %s\nUsage: %s [--case test_case_id]...\n' "$1" "$0" >&2
      exit 2
      ;;
  esac
done

prepare_workspace_changes=0
if (( ${#ui_cases[@]} == 0 )); then
  prepare_workspace_changes=1
else
  for ui_case in "${ui_cases[@]}"; do
    if [[ "${ui_case}" == "test_task_workspace_changes_group_staged_and_unstaged_diffs" ]]; then
      prepare_workspace_changes=1
      break
    fi
  done
fi

if (( prepare_workspace_changes == 1 )); then
  python3 "${repository_root}/scripts/prepare-e2e-fixture.py" --workspace-changes
else
  python3 "${repository_root}/scripts/prepare-e2e-fixture.py"
fi
fixture_root="/tmp/stationai-bridge-workspaces"
fixture_owner="StationAI bridge tests own this deterministic fixture (v1)."
if [[ "$(cat "${fixture_root}/.stationai-bridge-fixture" 2>/dev/null || true)" != "${fixture_owner}" ]]; then
  printf 'Refusing to prepare UI Codex fixtures without the owned fixture root marker.\n' >&2
  exit 1
fi
cp "${repository_root}/scripts/fixtures/codex-app-server-fixture.py" "${fixture_root}/codex-fixture-ui"
cp "${repository_root}/scripts/fixtures/codex-app-server-fixture.py" "${fixture_root}/codex-fixture-empty"
chmod 755 "${fixture_root}/codex-fixture-ui" "${fixture_root}/codex-fixture-empty"
python3 "${repository_root}/scripts/check-test-parity.py"

contract_path="${repository_root}/StationAI/BridgeTests/BridgeTestContracts.json"
expected_count="$(python3 - "${contract_path}" "${ui_cases[@]}" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as contract_file:
    contracts = json.load(contract_file)
known_cases = [contract["id"] for contract in contracts]
selected_cases = sys.argv[2:]
if len(selected_cases) != len(set(selected_cases)):
    raise SystemExit("Focused UI test case IDs must be unique.")
unknown_cases = sorted(set(selected_cases) - set(known_cases))
if unknown_cases:
    raise SystemExit("Unknown UI test case IDs: " + ", ".join(unknown_cases))
print(len(selected_cases) if selected_cases else len(known_cases))
PY
)"

test_output_dir="$(mktemp -d "${TMPDIR:-/tmp}/stationai-ui.XXXXXX")"
architecture="$(uname -m)"
result_bundle="${test_output_dir}/StationAI-UI.xcresult"
live_ui_marker="/tmp/stationai-codex-live-ui-integration"
rm -f "${live_ui_marker}"
if [[ "${STATIONAI_RUN_CODEX_INTEGRATION:-0}" == "1" ]]; then
  touch "${live_ui_marker}"
fi
cleanup() {
  if [[ "${STATIONAI_RUN_CODEX_INTEGRATION:-0}" == "1" ]]; then
    rm -f "${live_ui_marker}"
  fi
  printf "Visible UI test artifacts: %s\n" "${test_output_dir}"
}
trap cleanup EXIT

test_arguments=(
  test
  -project "${repository_root}/StationAI.xcodeproj"
  -scheme StationAI
  -destination "platform=macOS,arch=${architecture}"
  -derivedDataPath "${test_output_dir}/DerivedData"
  -resultBundlePath "${result_bundle}"
  -parallel-testing-enabled NO
)
if (( ${#ui_cases[@]} == 0 )); then
  test_arguments+=("-only-testing:StationAIUITests")
else
  for ui_case in "${ui_cases[@]}"; do
    test_arguments+=("-only-testing:StationAIUITests/StationAIUITests/${ui_case}")
  done
fi
test_arguments+=(
  CODE_SIGNING_ALLOWED=YES
  CODE_SIGN_IDENTITY=-
  ARCHS="${architecture}"
  ONLY_ACTIVE_ARCH=YES
  STATIONAI_APP_BUNDLE_IDENTIFIER=com.stationai.app.e2e
)

set +e
xcodebuild "${test_arguments[@]}"
xcodebuild_status=$?
set -e

summary_path="${test_output_dir}/test-summary.json"
if ! xcrun xcresulttool get test-results summary --path "${result_bundle}" > "${summary_path}"; then
  printf "Could not read the visible UI test summary (xcodebuild exit %s).\n" "${xcodebuild_status}" >&2
  if (( xcodebuild_status != 0 )); then exit "${xcodebuild_status}"; fi
  exit 1
fi

python3 - "${summary_path}" "${xcodebuild_status}" "${expected_count}" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as summary_file:
    summary = json.load(summary_file)

result = summary.get("result")
total = summary.get("totalTestCount", 0)
passed = summary.get("passedTests", 0)
failed = summary.get("failedTests", 0)
skipped = summary.get("skippedTests", 0)
xcodebuild_status = int(sys.argv[2])
expected_count = int(sys.argv[3])
print(
    f"Visible UI suite: result={result}; total={total} (expected {expected_count}), passed={passed}, "
    f"failed={failed}, skipped={skipped}; xcodebuild exit={xcodebuild_status}"
)

if xcodebuild_status != 0 or result != "Passed" or total != expected_count or failed != 0 or skipped != 0 or passed != total:
    failures = summary.get("testFailures", [])
    for failure in failures:
        print(f"{failure.get('testName', 'Unknown test')}: {failure.get('failureText', '')}")
    if any("Timed out while enabling automation mode" in failure.get("failureText", "") for failure in failures):
        print(
            "XCTest did not start a UI case. On macOS, enable Xcode Helper under "
            "System Settings > Privacy & Security > Accessibility, then rerun scripts/test-ui.sh."
        )
    raise SystemExit("Every paired UI case must run and pass with no skips.")
PY

if (( ${#ui_cases[@]} == 0 )); then
  printf 'StationAI full visible UI suite passed. The app was launched and interacted with by XCTest.\n'
else
  printf 'StationAI focused UI cases passed: %s\n' "${ui_cases[*]}"
fi
