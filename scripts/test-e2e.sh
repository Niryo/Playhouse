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
e2e_bundle_identifier="com.stationai.app.e2e.$$.${RANDOM}"
xcode_version="$(xcodebuild -version | awk '/^Xcode / {print $2}')"
repository_cache_key="$(printf '%s' "${repository_root}" | shasum -a 256 | cut -c 1-12)"
derived_data_dir="${TMPDIR:-/tmp}/stationai-bridge-derived-data-${xcode_version}-${architecture}-${repository_cache_key}"
app_bundle="${derived_data_dir}/Build/Products/Debug/StationAI.app"
cli_path="${app_bundle}/Contents/MacOS/stationai-cli"
data_root="${test_output_dir}/data"
bridge_log="${test_output_dir}/bridge-tests.log"
cleanup() {
  if [[ "$(head -n 1 "${selection_file}" 2>/dev/null || true)" == "${selection_owner}" ]]; then
    rm -f "${selection_file}"
  fi
  printf 'Bridge test artifacts: %s\n' "${test_output_dir}"
}
trap cleanup EXIT

python3 "${repository_root}/scripts/check-test-parity.py"
python3 "${repository_root}/scripts/check-button-feedback.py"

# Compile the paired UI test target without launching the app so UI-only source
# errors are caught by the fast verification path.
xcodebuild build-for-testing -quiet \
  -project "${repository_root}/StationAI.xcodeproj" \
  -scheme StationAI \
  -configuration Debug \
  -destination "platform=macOS,arch=${architecture}" \
  -derivedDataPath "${derived_data_dir}" \
  -only-testing:StationAIUITests/StationAIUITests \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGN_IDENTITY=- \
  ARCHS="${architecture}" \
  ONLY_ACTIVE_ARCH=YES \
  STATIONAI_APP_BUNDLE_IDENTIFIER="${e2e_bundle_identifier}"
python3 "${repository_root}/scripts/prepare-e2e-fixture.py"
legacy_store_seeder="/tmp/stationai-bridge-workspaces/seed-legacy-task-store"
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
  --fixture-root /tmp/stationai-bridge-workspaces
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
