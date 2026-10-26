#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export STATIONAI_REPOSITORY_ROOT="${repository_root}"
script_path="${repository_root}/scripts/test-ui.sh"

# Visible UI automation must run in the isolated Tart guest. The VM runner
# supplies this marker only inside its source snapshot on virtual Mac hardware.
vm_model="$(sysctl -n hw.model 2>/dev/null || true)"
if [[ "${STATIONAI_UI_TART_GUEST:-}" != "1" || "$vm_model" != VirtualMac* ]]; then
	if [[ "${1:-}" == "--locked" ]]; then
		shift
		export STATIONAI_UI_TART_HOST_LOCKED=1
	fi
	if [[ "${STATIONAI_RUN_LIVE_INTEGRATION:-0}" == "1" ]]; then
		exec "${repository_root}/scripts/test-ui-tart.sh" --live-provider "${STATIONAI_LIVE_PROVIDER:-claude}" "$@"
	fi
	if [[ "${STATIONAI_RUN_CODEX_INTEGRATION:-0}" == "1" ]]; then
		exec "${repository_root}/scripts/test-ui-tart.sh" --live-provider codex "$@"
	fi
	exec "${repository_root}/scripts/test-ui-tart.sh" "$@"
fi

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

if [[ "${STATIONAI_UI_TESTS_CONFIRMED:-0}" != "1" ]]; then
  bash "${repository_root}/scripts/confirm-ui-tests.sh"
fi

test_output_dir="$(mktemp -d "${TMPDIR:-/tmp}/stationai-ui.XXXXXX")"
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

fixture_root="/tmp/stationai-ui-test-fixtures"
if (( prepare_workspace_changes == 1 )); then
  python3 "${repository_root}/scripts/prepare-e2e-fixture.py" --fixture-root "${fixture_root}" --workspace-changes
else
  python3 "${repository_root}/scripts/prepare-e2e-fixture.py" --fixture-root "${fixture_root}"
fi
fixture_owner="StationAI bridge tests own this deterministic fixture (v1)."
if [[ "$(cat "${fixture_root}/.stationai-bridge-fixture" 2>/dev/null || true)" != "${fixture_owner}" ]]; then
  printf 'Refusing to prepare UI Codex fixtures without the owned fixture root marker.\n' >&2
  exit 1
fi
codex_fixtures=(
  ui empty nonblocking slow plan-slow interrupted abort success unique-turns-success goal-success
  title-success title-failure title-success-wait hold
  progress-hold-release progress-hold-release-failed progress-hold-release-interrupted
  progress-question success-wait store-write-success-wait concurrent-serial-success-wait
  status-transition-ui nonblocking-slow async-question async-question-queued subagent context-compaction tool-activity markdown steer-queue-serial-success-wait
)
for fixture in "${codex_fixtures[@]}"; do
  fixture_path="${fixture_root}/codex-fixture-${fixture}"
  cp "${repository_root}/scripts/fixtures/codex-app-server-fixture.py" "${fixture_path}"
  chmod 755 "${fixture_path}"
done
cp "${repository_root}/scripts/fixtures/claude-code-fixture.py" "${fixture_root}/claude-fixture-ui"
chmod 755 "${fixture_root}/claude-fixture-ui"
for fixture in subagent context-compaction tool-activity markdown async-question async-question-queued goal-success; do
  fixture_path="${fixture_root}/codex-fixture-${fixture}"
  xattr -d com.apple.quarantine "${fixture_path}" 2>/dev/null || true
  xattr -d com.apple.provenance "${fixture_path}" 2>/dev/null || true
done
python3 "${repository_root}/scripts/check-test-parity.py"

contract_path="${repository_root}/StationAI/BridgeTests/BridgeTestContracts.json"
contract_arguments=("${contract_path}")
if (( ${#ui_cases[@]} > 0 )); then
  contract_arguments+=("${ui_cases[@]}")
fi
expected_count="$(python3 - "${contract_arguments[@]}" <<'PY'
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
if (( ${#ui_cases[@]} > 0 )); then
  selected_cases=("${ui_cases[@]}")
else
  selected_cases=()
  while IFS= read -r ui_case; do
    selected_cases+=("${ui_case}")
  done < <(python3 - "${contract_path}" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as contract_file:
    for contract in json.load(contract_file):
        print(contract["id"])
PY
)
fi

dashboard_script="${repository_root}/scripts/ui-test-dashboard.py"
dashboard_state="${test_output_dir}/dashboard.json"
dashboard_log="${test_output_dir}/xcodebuild.log"
dashboard_arguments=(init --state-file "${dashboard_state}" --contract "${contract_path}")
if (( ${#ui_cases[@]} > 0 )); then
  for ui_case in "${ui_cases[@]}"; do
    dashboard_arguments+=(--case "${ui_case}")
  done
fi
python3 "${dashboard_script}" "${dashboard_arguments[@]}" >/dev/null

architecture="$(uname -m)"
xcode_version="$(xcodebuild -version | awk '/^Xcode / {print $2}')"
if [[ "${STATIONAI_UI_TART_GUEST:-0}" == "1" ]]; then
  repository_cache_key="tart-vm-v5"
  derived_data_root="${HOME}/StationAIUITestRuns/DerivedData"
else
  repository_cache_key="$(printf '%s' "${repository_root}" | shasum -a 256 | cut -c 1-12)"
  derived_data_root="${TMPDIR:-/tmp}"
fi
derived_data_dir="${derived_data_root}/stationai-ui-derived-data-${xcode_version}-${architecture}-${repository_cache_key}"
test_run_identifier="$(basename "${test_output_dir}" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]')"
source_bundle_identifier="$("${repository_root}/scripts/app-profile.sh" "${repository_root}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["bundleID"])')"
task_pr_seeder="${fixture_root}/seed-task-pr-link"
xcrun swiftc -module-name StationAI \
  "${repository_root}/StationAI/App/BoardTask.swift" \
  "${repository_root}/scripts/seed-task-pr-link.swift" \
  -o "${task_pr_seeder}"
legacy_store_seeder="${fixture_root}/seed-legacy-task-store"
xcrun swiftc -parse-as-library -swift-version 5 -O \
  "${repository_root}/scripts/seed-legacy-task-store.swift" \
  -o "${legacy_store_seeder}"
# Live UI cases read the selected provider from this marker; the guest
# runner exports STATIONAI_LIVE_PROVIDER alongside STATIONAI_RUN_LIVE_INTEGRATION.
live_ui_marker="/tmp/stationai-live-ui-integration"
live_ui_provider=""
if [[ "${STATIONAI_RUN_LIVE_INTEGRATION:-0}" == "1" ]]; then
  live_ui_provider="${STATIONAI_LIVE_PROVIDER:-claude}"
elif [[ "${STATIONAI_RUN_CODEX_INTEGRATION:-0}" == "1" ]]; then
  live_ui_provider="codex"
fi
rm -f "${live_ui_marker}"
if [[ -n "${live_ui_provider}" ]]; then
  printf '%s\n' "${live_ui_provider}" > "${live_ui_marker}"
fi
cleanup() {
  if [[ -n "${live_ui_provider}" ]]; then
    rm -f "${live_ui_marker}"
  fi
  printf "Visible UI test artifacts: %s\n" "${test_output_dir}"
}
trap cleanup EXIT

dashboard_inline=0
if [[ "${STATIONAI_UI_DASHBOARD:-1}" != "0" ]]; then
  if command -v osascript >/dev/null 2>&1 && osascript - "${dashboard_script}" "${dashboard_state}" <<'APPLESCRIPT' >/dev/null 2>&1
on run argv
  set dashboardScript to item 1 of argv
  set dashboardState to item 2 of argv
  set dashboardCommand to "python3 " & quoted form of dashboardScript & " watch --state-file " & quoted form of dashboardState
  tell application "Terminal"
    activate
    do script dashboardCommand
  end tell
end run
APPLESCRIPT
  then
    printf 'Live UI test dashboard opened in a separate Terminal window.\n'
  else
    dashboard_inline=1
    printf 'Could not open a separate Terminal dashboard; test progress will be printed in this terminal.\n' >&2
  fi
else
  dashboard_inline=1
fi

base_test_arguments=(
  test
  -project "${repository_root}/StationAI.xcodeproj"
  -scheme StationAI
  -destination "platform=macOS,arch=${architecture}"
  -derivedDataPath "${derived_data_dir}"
  -parallel-testing-enabled NO
)
base_test_arguments+=(
  CODE_SIGNING_ALLOWED=YES
  CODE_SIGN_IDENTITY=-
  ARCHS="${architecture}"
  ONLY_ACTIVE_ARCH=YES
)

# A new xcodebuild test session every eight cases bounds sequence-dependent
# XCTest/macOS state while keeping each case single-shot and serial.
batch_size=8
batch_count=$(( (${#selected_cases[@]} + batch_size - 1) / batch_size ))
overall_failed=0
for (( batch_index=0; batch_index<batch_count; batch_index++ )); do
  first_case=$(( batch_index * batch_size ))
  batch_cases=("${selected_cases[@]:first_case:batch_size}")
  batch_number=$(( batch_index + 1 ))
  batch_tag="$(printf '%02d' "${batch_number}")"
  result_bundle="${test_output_dir}/StationAI-UI-batch-${batch_tag}.xcresult"
  summary_path="${test_output_dir}/test-summary-batch-${batch_tag}.json"
  dashboard_log="${test_output_dir}/xcodebuild-batch-${batch_tag}.log"
  app_bundle_identifier="${source_bundle_identifier}.e2e.${test_run_identifier}.b${batch_tag}"
  test_arguments=("${base_test_arguments[@]}" -resultBundlePath "${result_bundle}")
  for ui_case in "${batch_cases[@]}"; do
    test_arguments+=("-only-testing:StationAIUITests/StationAIUITests/${ui_case}")
  done
  test_arguments+=("STATIONAI_APP_BUNDLE_IDENTIFIER=${app_bundle_identifier}")

  printf '\nVisible UI batch %s/%s (%s cases): %s\n' \
    "${batch_number}" "${batch_count}" "${#batch_cases[@]}" "${batch_cases[*]}"
  set +e
  tracker_arguments=(track --state-file "${dashboard_state}" --log-file "${dashboard_log}")
  if (( dashboard_inline == 1 )); then
    tracker_arguments+=(--announce)
  fi
  caffeinate -d xcodebuild "${test_arguments[@]}" 2>&1 \
    | python3 "${dashboard_script}" "${tracker_arguments[@]}"
  pipeline_status=("${PIPESTATUS[@]}")
  xcodebuild_status="${pipeline_status[0]}"
  dashboard_tracker_status="${pipeline_status[1]}"
  set -e

  summary_read_status=0
  if xcrun xcresulttool get test-results summary --path "${result_bundle}" > "${summary_path}"; then
    :
  else
    summary_read_status=$?
    printf "Could not read UI batch %s summary (xcodebuild exit %s).\n" "${batch_number}" "${xcodebuild_status}" >&2
  fi

  batch_finish_arguments=(finish --state-file "${dashboard_state}" --exit-status "${xcodebuild_status}")
  for ui_case in "${batch_cases[@]}"; do
    batch_finish_arguments+=(--case "${ui_case}")
  done
  if (( summary_read_status == 0 )); then
    batch_finish_arguments+=(--summary "${summary_path}")
  fi
  python3 "${dashboard_script}" "${batch_finish_arguments[@]}" >/dev/null

  if (( dashboard_tracker_status != 0 )); then
    printf 'The live dashboard could not read batch %s output; see %s.\n' "${batch_number}" "${dashboard_log}" >&2
    overall_failed=1
  fi
  if (( summary_read_status != 0 )); then
    overall_failed=1
  else
    batch_validation_status=0
    if python3 - "${summary_path}" "${xcodebuild_status}" "${#batch_cases[@]}" "${batch_number}" <<'PY'
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
batch_number = sys.argv[4]
print(
    f"Visible UI batch {batch_number}: result={result}; total={total} (expected {expected_count}), "
    f"passed={passed}, failed={failed}, skipped={skipped}; xcodebuild exit={xcodebuild_status}"
)

failures = summary.get("testFailures", [])
automation_startup_failure = (
    total == 1
    and passed == 0
    and skipped == 0
    and failed == 1
    and any(
        "StationAIUITests-Runner" in failure.get("testName", "")
        and "failed to initialize for ui testing" in failure.get("failureText", "").lower()
        for failure in failures
    )
)
if xcodebuild_status != 0 or result != "Passed" or total != expected_count or failed != 0 or skipped != 0 or passed != total:
    for failure in failures:
        print(f"{failure.get('testName', 'Unknown test')}: {failure.get('failureText', '')}")
    if any("Timed out while enabling automation mode" in failure.get("failureText", "") for failure in failures):
        print(
            "XCTest could not start a UI case because macOS automation mode timed out. "
            "Check that the user session is unlocked and Xcode Helper is enabled under "
            "System Settings > Privacy & Security > Accessibility, then rerun scripts/test-ui.sh."
        )
    if automation_startup_failure:
        raise SystemExit(2)
    raise SystemExit(1)
PY
    then
      :
    else
      batch_validation_status=$?
      overall_failed=1
    fi
    if (( batch_validation_status == 2 )); then
      printf 'Stopping remaining UI batches because XCTest did not start any selected case; retrying would repeat the same system automation failure.\n' >&2
      break
    fi
  fi
done

if ! python3 - "${test_output_dir}" "${batch_count}" "${expected_count}" <<'PY'
import json
import pathlib
import sys

output_dir = pathlib.Path(sys.argv[1])
batch_count = int(sys.argv[2])
expected = int(sys.argv[3])
totals = {"totalTestCount": 0, "passedTests": 0, "failedTests": 0, "skippedTests": 0}
all_passed = True
for batch_number in range(1, batch_count + 1):
    summary_path = output_dir / f"test-summary-batch-{batch_number:02d}.json"
    try:
        with summary_path.open(encoding="utf-8") as summary_file:
            summary = json.load(summary_file)
    except (OSError, json.JSONDecodeError):
        print(f"UI batch {batch_number} has no readable xcresult summary.")
        all_passed = False
        continue
    all_passed = all_passed and summary.get("result") == "Passed"
    for key in totals:
        value = summary.get(key, 0)
        if not isinstance(value, int):
            all_passed = False
            value = 0
        totals[key] += value

print(
    "Aggregate xcresult counts: "
    f"total={totals['totalTestCount']} (expected {expected}), "
    f"passed={totals['passedTests']}, failed={totals['failedTests']}, "
    f"skipped={totals['skippedTests']}, batches={batch_count}"
)
if (
    not all_passed
    or totals["totalTestCount"] != expected
    or totals["passedTests"] != expected
    or totals["failedTests"] != 0
    or totals["skippedTests"] != 0
):
    raise SystemExit("Aggregate xcresult counts must include every selected UI case exactly once with no failures or skips.")
PY
then
  overall_failed=1
fi

python3 "${dashboard_script}" finish --state-file "${dashboard_state}" --exit-status "${overall_failed}" >/dev/null

python3 - "${dashboard_state}" "${expected_count}" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as state_file:
    state = json.load(state_file)
summary = state.get("summary") or {}
expected = int(sys.argv[2])
print(
    f"Visible UI suite: result={summary.get('result')}; total={summary.get('total')} (expected {expected}), "
    f"passed={summary.get('passed')}, failed={summary.get('failed')}, skipped={summary.get('skipped')}, "
    f"not run={summary.get('not_run')}; batches={summary.get('batch_count')}"
)
if state.get("suite_status") != "passed" or summary.get("total") != expected or summary.get("passed") != expected:
    raise SystemExit("Every paired UI case must run and pass with no skips.")
PY

if (( overall_failed != 0 )); then
  exit 1
fi
if (( ${#ui_cases[@]} == 0 )); then
  printf 'StationAI full visible UI suite passed across %s fresh serial Xcode sessions.\n' "${batch_count}"
else
  printf 'StationAI focused UI cases passed across %s Xcode session(s): %s\n' "${batch_count}" "${ui_cases[*]}"
fi
