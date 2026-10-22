#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repository_root}/scripts/app-profile.sh"
stationai_load_app_profile "${repository_root}"

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

test_output_dir="$(mktemp -d /tmp/stationai-bridge.XXXXXX)"
architecture="$(uname -m)"
python3 "${repository_root}/scripts/check-test-parity.py"
python3 "${repository_root}/scripts/check-button-feedback.py"
build_info="$(python3 "${repository_root}/scripts/prepare-e2e-build.py" \
  --root "${repository_root}" \
  --profile-bundle-id "${STATIONAI_PROFILE_BUNDLE_ID}" \
  --architecture "${architecture}")"
derived_data_dir="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["derivedData"])' "${build_info}")"
e2e_bundle_identifier="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["bundleID"])' "${build_info}")"
app_bundle="${derived_data_dir}/Build/Products/Debug/StationAI.app"
cli_path="${app_bundle}/Contents/MacOS/stationai-cli"
data_root="${test_output_dir}/data"
fixture_root="${test_output_dir}/fixtures"
bridge_log="${test_output_dir}/bridge-tests.log"
cleanup() {
  printf 'Bridge test artifacts: %s\n' "${test_output_dir}"
}
trap cleanup EXIT

# The build helper also compiles the paired UI test target and reuses this
# content-matched DerivedData for focused retries and final full verification.
python3 "${repository_root}/scripts/prepare-e2e-fixture.py" --fixture-root "${fixture_root}"
legacy_store_seeder="${fixture_root}/seed-legacy-task-store"
xcrun swiftc -parse-as-library -swift-version 5 -O \
  "${repository_root}/scripts/seed-legacy-task-store.swift" \
  -o "${legacy_store_seeder}"
if [[ ! -x "${cli_path}" ]]; then
  printf 'The app build did not produce its bundled CLI at %s.\n' "${cli_path}" >&2
  exit 1
fi

service_info="${app_bundle}/Contents/XPCServices/StationAIBridge.xpc/Contents/Info.plist"
service_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${service_info}")"
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

set +e
python3 "${bridge_arguments[@]}" 2>&1 | tee "${bridge_log}"
bridge_status="${PIPESTATUS[0]}"
set -e
if (( bridge_status != 0 )); then
  printf 'The CLI/XPC bridge suite failed; full output: %s\n' "${bridge_log}" >&2
  exit "${bridge_status}"
fi

printf 'StationAI CLI/XPC bridge verification passed without launching the UI.\n'
