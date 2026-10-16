#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script_path="${repository_root}/scripts/test-e2e.sh"

if [[ "${1:-}" != "--locked" ]]; then
  exec "${repository_root}/scripts/with-e2e-lock.sh" -- bash "${script_path}" --locked
fi
shift

test_output_dir="$(mktemp -d "${TMPDIR:-/tmp}/stationai-bridge.XXXXXX")"
architecture="$(uname -m)"
result_bundle="${test_output_dir}/StationAI.xcresult"
trap 'printf "Bridge test artifacts: %s\n" "${test_output_dir}"' EXIT

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
