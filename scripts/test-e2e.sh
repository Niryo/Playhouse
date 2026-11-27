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
  printf 'E2E total_seconds=%s exit_status=%s\n' "${SECONDS}" "${status}" >&2
  # A passing run has nothing to inspect, and each run's app data holds full
  # app copies from the update cases, so only failures keep their artifacts.
  if (( status == 0 )) && [[ "${PLAYHOUSE_E2E_KEEP_ARTIFACTS:-0}" != "1" ]]; then
    # A daemon idling out may still write under data/; a later run's prune
    # clears what is left rather than failing this passing run.
    if rm -rf -- "${test_output_dir}" 2>/dev/null; then
      printf 'Bridge test artifacts removed after a passing run (set PLAYHOUSE_E2E_KEEP_ARTIFACTS=1 to keep them).\n' >&2
    else
      printf 'Could not fully remove bridge test artifacts: %s\n' "${test_output_dir}" >&2
    fi
  else
    printf 'Bridge test artifacts: %s\n' "${test_output_dir}" >&2
  fi
}
trap cleanup EXIT
# A failed run's artifacts stay for inspection; earlier runs past the
# retention window are dropped so they do not pile up in /tmp.
python3 "${repository_root}/scripts/prune-test-artifacts.py" \
  --root "$(dirname "${test_output_dir}")" --prefix playhouse-bridge. --age-from mtime \
  --keep "$(basename "${test_output_dir}")"
architecture="$(uname -m)"
python3 "${repository_root}/scripts/check-test-parity.py"
python3 "${repository_root}/scripts/check-module-boundaries.py"
python3 "${repository_root}/scripts/check-atom-composites.py"
python3 "${repository_root}/scripts/check-button-feedback.py"
python3 "${repository_root}/scripts/check-hover-scrollers.py"
python3 "${repository_root}/scripts/check-polling-loops.py"
python3 "${repository_root}/scripts/check-e2e-locking.py"
python3 "${repository_root}/scripts/check-artifact-pruning.py"
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
# Pure-logic unit checks of the Codex CPU working-directory attribution.
codex_cpu_attribution_tests="${test_output_dir}/codex-cpu-attribution-tests"
xcrun swiftc -parse-as-library -swift-version 5 -package-name playhouse -O \
  "${repository_root}/Playhouse/Core/Providers/ProcessCPUSampler.swift" \
  "${repository_root}/Playhouse/Core/Platform/POSIX.swift" \
  "${repository_root}/scripts/unit/codex-cpu-attribution-tests.swift" \
  -o "${codex_cpu_attribution_tests}"
"${codex_cpu_attribution_tests}"
# Pure-logic unit checks of the agent usage payload parsing and reset rules.
agent_usage_parsing_tests="${test_output_dir}/agent-usage-parsing-tests"
xcrun swiftc -parse-as-library -swift-version 5 -package-name playhouse -O \
  "${repository_root}/Playhouse/Core/Providers/AgentUsage.swift" \
  "${repository_root}/Playhouse/Core/Platform/POSIX.swift" \
  "${repository_root}/scripts/unit/agent-usage-parsing-tests.swift" \
  -o "${agent_usage_parsing_tests}"
"${agent_usage_parsing_tests}"
# Unit checks of the process host that lets provider agents outlive their daemon.
agent_run_host_tests="${test_output_dir}/agent-run-host-tests"
xcrun swiftc -parse-as-library -swift-version 5 -package-name playhouse -O \
  "${repository_root}/Playhouse/Core/Providers/AgentRunHost.swift" \
  "${repository_root}/Playhouse/Core/Platform/POSIX.swift" \
  "${repository_root}/scripts/unit/agent-run-host-tests.swift" \
  -o "${agent_run_host_tests}"
"${agent_run_host_tests}"
# Unit checks of the bounded waits that keep a task delete from hanging on a turn that won't stop.
bounded_waits_tests="${test_output_dir}/bounded-waits-tests"
xcrun swiftc -parse-as-library -swift-version 5 -package-name playhouse -O \
  "${repository_root}/Playhouse/Core/Bridge/BoundedWaits.swift" \
  "${repository_root}/scripts/unit/bounded-waits-tests.swift" \
  -o "${bounded_waits_tests}"
"${bounded_waits_tests}"
# Pure-logic unit checks of the context compaction decisions and session state reader.
context_compaction_tests="${test_output_dir}/context-compaction-policy-tests"
xcrun swiftc -parse-as-library -swift-version 5 -package-name playhouse -O \
  "${repository_root}/Playhouse/Core/Conversation/ContextCompaction.swift" \
  "${repository_root}/scripts/unit/context-compaction-policy-tests.swift" \
  -o "${context_compaction_tests}"
"${context_compaction_tests}"
# Pure-logic unit checks of where provider dividers and goal achievements sit in the transcript.
transcript_row_anchor_tests="${test_output_dir}/transcript-row-anchors-tests"
xcrun swiftc -parse-as-library -swift-version 5 -package-name playhouse -O \
  "${repository_root}/Playhouse/Core/Conversation/TranscriptRowAnchors.swift" \
  "${repository_root}/scripts/unit/transcript-row-anchors-tests.swift" \
  -o "${transcript_row_anchor_tests}"
"${transcript_row_anchor_tests}"
# Pure-logic unit checks of the shared Markdown parser behind the transcript and the Markdown atom.
markdown_document_tests="${test_output_dir}/markdown-document-tests"
xcrun swiftc -parse-as-library -swift-version 5 -package-name playhouse -O \
  "${repository_root}/Playhouse/Core/Conversation/MarkdownDocument.swift" \
  "${repository_root}/Playhouse/Core/Catalogs/SkillManifest.swift" \
  "${repository_root}/Playhouse/Core/Platform/Hashing.swift" \
  "${repository_root}/scripts/unit/markdown-document-tests.swift" \
  -o "${markdown_document_tests}"
"${markdown_document_tests}"
# Checks that plugin nodes decode their props once per op, never when read, and that native
# typed props are never decoded and round-trip through Codable. Built from all of the plugin
# core, which so also builds with no SwiftUI or AppKit.
plugin_node_props_tests="${test_output_dir}/plugin-node-props-tests"
xcrun swiftc -parse-as-library -swift-version 5 -package-name playhouse -O -D PLAYHOUSE_ATOM_BENCHMARK \
  "${repository_root}"/Playhouse/Core/Plugins/Runtime/*.swift \
  "${repository_root}/scripts/unit/plugin-node-props-tests.swift" \
  -o "${plugin_node_props_tests}"
"${plugin_node_props_tests}"
# The CLI's command catalog against its parser: no handled command without a help entry, and
# no declared command without a handler. Built from the CLI's sources minus its entry point.
cli_command_catalog_tests="${test_output_dir}/cli-command-catalog-tests"
xcrun swiftc -parse-as-library -swift-version 5 -package-name playhouse -Onone \
  "${repository_root}/Playhouse/Core/Bridge/BridgeContract.swift" \
  "${repository_root}/Playhouse/Core/Bridge/CLICommandCatalog.swift" \
  "${repository_root}/Playhouse/Core/Bridge/BridgeSocket.swift" \
  "${repository_root}/Playhouse/Core/Bridge/UpdateCore.swift" \
  "${repository_root}/Playhouse/Core/Bridge/ReleaseSigningKey.swift" \
  "${repository_root}/Playhouse/Core/Platform/Hashing.swift" \
  "${repository_root}/Playhouse/CLI/BridgeClient.swift" \
  "${repository_root}/Playhouse/CLI/PlayhouseCLIParsing.swift" \
  "${repository_root}/Playhouse/CLI/PlayhouseCLIUtilities.swift" \
  "${repository_root}/Playhouse/Core/Platform/POSIX.swift" \
  "${repository_root}/scripts/unit/cli-command-catalog-tests.swift" \
  -o "${cli_command_catalog_tests}"
"${cli_command_catalog_tests}" "${repository_root}/Playhouse/CLI/PlayhouseCLIParsing.swift" \
  "${repository_root}/Playhouse/Core/Providers/CodexTaskInstructions.swift"
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
)
if (( ${#selected_cases[@]} > 0 )); then
  for selected_case in "${selected_cases[@]}"; do
    bridge_arguments+=(--case "${selected_case}")
  done
fi

report_phase cases
# Task status sounds play at volume 0 in every CLI call and daemon the suite starts.
export PLAYHOUSE_MUTE_SOUNDS=1
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
