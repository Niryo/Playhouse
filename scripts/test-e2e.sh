#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script_path="${repository_root}/scripts/test-e2e.sh"

if [[ "${1:-}" != "--locked" ]]; then
  exec "${repository_root}/scripts/with-e2e-lock.sh" -- bash "${script_path}" --locked "$@"
fi
shift

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

selected_cases_csv=""
if (( ${#selected_cases[@]} > 0 )); then
  selected_cases_csv="$(IFS=,; printf '%s' "${selected_cases[*]}")"
fi
selection_file="/tmp/stationai-bridge-test-selection-${repository_root//\//_}"
selection_owner="StationAI bridge test selection (v1)."
if [[ -e "${selection_file}" ]] && [[ "$(head -n 1 "${selection_file}" 2>/dev/null || true)" != "${selection_owner}" ]]; then
  printf 'Refusing to overwrite an unowned bridge test selection file: %s\n' "${selection_file}" >&2
  exit 1
fi
if (( ${#selected_cases[@]} > 0 )); then
  printf '%s\n%s\n' "${selection_owner}" "${selected_cases_csv}" > "${selection_file}"
else
  rm -f "${selection_file}"
fi

test_output_dir="$(mktemp -d "${TMPDIR:-/tmp}/stationai-bridge.XXXXXX")"
architecture="$(uname -m)"
result_bundle="${test_output_dir}/StationAI.xcresult"
cleanup() {
  if [[ "$(head -n 1 "${selection_file}" 2>/dev/null || true)" == "${selection_owner}" ]]; then
    rm -f "${selection_file}"
  fi
  printf 'Bridge test artifacts: %s\n' "${test_output_dir}"
}
trap cleanup EXIT

python3 "${repository_root}/scripts/prepare-e2e-fixture.py"
python3 "${repository_root}/scripts/check-test-parity.py"

set +e
xcodebuild test -quiet \
  -project "${repository_root}/StationAI.xcodeproj" \
  -scheme StationAI \
  -destination "platform=macOS,arch=${architecture}" \
  -derivedDataPath "${test_output_dir}/DerivedData" \
  -resultBundlePath "${result_bundle}" \
  -parallel-testing-enabled NO \
  -only-testing:StationAIBridgeTests \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGN_IDENTITY=- \
  ARCHS="${architecture}" \
  ONLY_ACTIVE_ARCH=YES \
  STATIONAI_APP_BUNDLE_IDENTIFIER=com.stationai.app.e2e
xcodebuild_status=$?
set -e

summary_path="${test_output_dir}/test-summary.json"
if ! xcrun xcresulttool get test-results summary --path "${result_bundle}" > "${summary_path}"; then
  printf "Could not read the bridge test summary (xcodebuild exit %s).\n" "${xcodebuild_status}" >&2
  if (( xcodebuild_status != 0 )); then exit "${xcodebuild_status}"; fi
  exit 1
fi

python3 - "${summary_path}" "${xcodebuild_status}" <<'PY'
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
print(
    f"Xcode bridge suite: result={result}; total={total}, passed={passed}, "
    f"failed={failed}, skipped={skipped}; xcodebuild exit={xcodebuild_status}"
)

if xcodebuild_status != 0 or result != "Passed" or total == 0 or failed != 0 or skipped != 0 or passed != total:
    for failure in summary.get("testFailures", []):
        print(f"{failure.get('testName', 'Unknown test')}: {failure.get('failureText', '')}")
    raise SystemExit("Every discovered bridge test must pass without skips.")
PY

printf 'StationAI CLI/XPC bridge verification passed without launching the UI.\n'
