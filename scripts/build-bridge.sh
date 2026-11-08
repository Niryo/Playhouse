#!/usr/bin/env bash
set -euo pipefail

repository_root="${SRCROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${repository_root}/scripts/app-profile.sh"
playhouse_load_app_profile "${repository_root}"
playhouse_verify_build_identity "${PRODUCT_BUNDLE_IDENTIFIER:-com.playhouse.app}"
app_contents="${TARGET_BUILD_DIR:?}/${CONTENTS_FOLDER_PATH:?}"
app_macos="${app_contents}/MacOS"
cli_executable="${app_macos}/playhouse-cli"
app_executable="${app_macos}/${EXECUTABLE_NAME:?}"
# The daemon ships flat in Contents/MacOS, a sibling of the CLI, not as its own
# bundle: `Bundle.main` resolution for any executable under
# `<App>.app/Contents/MacOS/` already finds the app's own Info.plist by path
# structure alone, so the daemon gets the same app identity as the GUI process
# without needing a separate bundle/Info.plist (unlike the XPC service this
# replaced, which needed its own bundle specifically for XPC's service
# discovery).
daemon_executable="${app_macos}/playhouse-daemon"
# The plugin dev runner links only the plugin core (Foundation + JavaScriptCore)
# and the bridge client, so the core can never come to depend on SwiftUI or the
# app target: an import of either breaks this build.
plugin_dev_executable="${app_macos}/playhouse-plugin-dev"
architecture="${CURRENT_ARCH:-}"
if [[ -z "${architecture}" || "${architecture}" == "undefined_arch" ]]; then
  architecture="${ARCHS%% *}"
fi
if [[ -z "${architecture}" ]]; then
  architecture="$(uname -m)"
fi
deployment_target="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
sdk="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
debug_flags=()
if [[ "${CONFIGURATION:-Debug}" == "Debug" ]]; then
  debug_flags=(-D DEBUG)
fi

mkdir -p "${app_macos}"

# The scheduler LaunchAgent fires scheduled tasks while the app is closed. The app
# registers it with SMAppService only while a schedule exists. Each minute it runs a
# short-lived `playhouse-cli schedule tick`, which starts the daemon on demand. The
# label follows the bundle identifier so worktree profiles never share an agent.
launch_agents="${app_contents}/Library/LaunchAgents"
mkdir -p "${launch_agents}"
find "${launch_agents}" -name '*.scheduler.plist' ! -name "${PRODUCT_BUNDLE_IDENTIFIER:-com.playhouse.app}.scheduler.plist" -delete
python3 - "${launch_agents}/${PRODUCT_BUNDLE_IDENTIFIER:-com.playhouse.app}.scheduler.plist" "${PRODUCT_BUNDLE_IDENTIFIER:-com.playhouse.app}" <<'PYAGENT'
import plistlib
import sys
path, bundle_identifier = sys.argv[1:3]
agent = {
    'Label': bundle_identifier + '.scheduler',
    'BundleProgram': 'Contents/MacOS/playhouse-cli',
    'ProgramArguments': ['playhouse-cli', 'schedule', 'tick'],
    'AssociatedBundleIdentifiers': [bundle_identifier],
    'StartInterval': 60,
    'ProcessType': 'Background',
    'StandardOutPath': '/dev/null',
    'StandardErrorPath': '/dev/null',
}
try:
    with open(path, 'rb') as stream:
        if plistlib.load(stream) == agent:
            sys.exit(0)
except (OSError, plistlib.InvalidFileException):
    pass
with open(path, 'wb') as stream:
    plistlib.dump(agent, stream)
PYAGENT

if [[ ! -x "${app_executable}" ]]; then
  printf 'The Playhouse app executable is missing before the bridge tools are embedded: %s\n' "${app_executable}" >&2
  exit 1
fi

# Plugins/Core is a synchronized Xcode folder; every Swift file in it is part of
# the plugin core, shared by the app, the daemon and playhouse-plugin-dev.
plugin_core_sources=()
while IFS= read -r source; do
  plugin_core_sources+=("${source}")
done < <(find "${repository_root}/Playhouse/App/Plugins/Core" -name '*.swift' -type f | LC_ALL=C sort)
if (( ${#plugin_core_sources[@]} == 0 )); then
  printf 'No plugin core sources found in %s\n' "${repository_root}/Playhouse/App/Plugins/Core" >&2
  exit 1
fi

shared_sources=(
  "${repository_root}/Playhouse/App/BoardTask.swift"
  "${repository_root}/Playhouse/App/ConversationSubject.swift"
  "${repository_root}/Playhouse/App/WorkspaceSupport.swift"
  "${repository_root}/Playhouse/App/WorkspaceChanges.swift"
  "${repository_root}/Playhouse/App/CodexAppServerClient.swift"
  "${repository_root}/Playhouse/App/CodexSocketConnection.swift"
  "${repository_root}/Playhouse/App/ConversationModel.swift"
  "${repository_root}/Playhouse/App/ClaudeCodeClient.swift"
  "${repository_root}/Playhouse/App/ProviderRequestLog.swift"
  "${repository_root}/Playhouse/App/ProcessCPUSampler.swift"
  "${repository_root}/Playhouse/App/AgentRunHost.swift"
  "${repository_root}/Playhouse/App/AgentUsage.swift"
  "${repository_root}/Playhouse/App/AgentUsageStore.swift"
  "${repository_root}/Playhouse/App/ConversationTranscriptStore.swift"
  "${repository_root}/Playhouse/App/StandaloneChatStore.swift"
  "${repository_root}/Playhouse/App/SkillCatalog.swift"
  "${repository_root}/Playhouse/App/RuleCatalog.swift"
  "${repository_root}/Playhouse/App/McpCatalog.swift"
  "${repository_root}/Playhouse/App/CodexConfigTOML.swift"
  "${repository_root}/Playhouse/App/BridgeCore.swift"
  "${repository_root}/Playhouse/App/TaskSchedule.swift"
  "${repository_root}/Playhouse/Bridge/BridgeContract.swift"
  "${repository_root}/Playhouse/Bridge/BridgeSocket.swift"
  "${plugin_core_sources[@]}"
)

# The daemon compiles the app's sources as one Swift 5 module, so GRDB (a Swift 6
# package) is linked as its own prebuilt static module. Its output path embeds
# the GRDB source fingerprint.
grdb_module="$("${repository_root}/scripts/build-grdb.sh" "${architecture}" "${deployment_target}" "${sdk}")"

bridge_stamp="${TARGET_BUILD_DIR}/.playhouse-bridge-build-stamp-${PRODUCT_BUNDLE_IDENTIFIER//./_}"
bridge_inputs=(
  "${BASH_SOURCE[0]}"
  "${grdb_module}"
  "${shared_sources[@]}"
  "${repository_root}/Playhouse/Bridge/DaemonMain.swift"
  "${repository_root}/Playhouse/CLI/BridgeClient.swift"
  "${repository_root}/Playhouse/CLI/PlayhouseCLI.swift"
  "${repository_root}/Playhouse/PluginDev/PluginDevMain.swift"
  "${architecture}-apple-macosx${deployment_target}"
  "${sdk}"
  "$(xcrun --sdk macosx swiftc -version)"
  "${CONFIGURATION:-Debug}"
  "${PRODUCT_BUNDLE_IDENTIFIER:-com.playhouse.app}"
  "${MARKETING_VERSION:-1.0}"
  "${CURRENT_PROJECT_VERSION:-1}"
  "${PLAYHOUSE_PROFILE_ROOT}"
)
bridge_fingerprint="$(
  {
    for input in "${bridge_inputs[@]}"; do
      if [[ -f "${input}" ]]; then
        shasum -a 256 "${input}"
      else
        printf '%s\n' "${input}"
      fi
    done
  } | shasum -a 256 | awk '{print $1}'
)"

metadata_matches() {
  local app_info="${app_contents}/Info.plist"
  [[ -f "${app_info}" ]] || return 1
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :PlayhouseStoreCompatibilityVersion' "${app_info}" 2>/dev/null)" == "2" ]] &&
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :PlayhouseSourceWorktree' "${app_info}" 2>/dev/null)" == "${PLAYHOUSE_PROFILE_ROOT}" ]]
}

if [[ -x "${cli_executable}" && -x "${daemon_executable}" && -x "${plugin_dev_executable}" &&
      -f "${bridge_stamp}" && "$(cat "${bridge_stamp}")" == "${bridge_fingerprint}" ]] &&
      metadata_matches; then
  printf 'Reusing unchanged embedded bridge tools in %s\n' "${app_contents}"
  exit 0
fi

xcrun --sdk macosx swiftc \
  -swift-version 5 \
  -target "${architecture}-apple-macosx${deployment_target}" \
  -sdk "${sdk}" \
  -O \
  "${debug_flags[@]}" \
  -framework Foundation \
  -framework AppKit \
  -framework SwiftUI \
  -framework SwiftData \
  -framework Combine \
  -framework JavaScriptCore \
  -I "${grdb_module}" \
  -I "${repository_root}/Vendor/GRDB.swift/Sources/GRDBSQLite" \
  -L "${grdb_module}" \
  -lGRDB \
  "${shared_sources[@]}" \
  "${repository_root}/Playhouse/Bridge/DaemonMain.swift" \
  -o "${daemon_executable}"

xcrun --sdk macosx swiftc \
  -swift-version 5 \
  -target "${architecture}-apple-macosx${deployment_target}" \
  -sdk "${sdk}" \
  -O \
  "${debug_flags[@]}" \
  -framework Foundation \
  "${repository_root}/Playhouse/Bridge/BridgeContract.swift" \
  "${repository_root}/Playhouse/Bridge/BridgeSocket.swift" \
  "${repository_root}/Playhouse/CLI/BridgeClient.swift" \
  "${repository_root}/Playhouse/CLI/PlayhouseCLI.swift" \
  -o "${cli_executable}"

xcrun --sdk macosx swiftc \
  -swift-version 5 \
  -target "${architecture}-apple-macosx${deployment_target}" \
  -sdk "${sdk}" \
  -O \
  "${debug_flags[@]}" \
  -framework Foundation \
  -framework JavaScriptCore \
  "${plugin_core_sources[@]}" \
  "${repository_root}/Playhouse/Bridge/BridgeContract.swift" \
  "${repository_root}/Playhouse/Bridge/BridgeSocket.swift" \
  "${repository_root}/Playhouse/CLI/BridgeClient.swift" \
  "${repository_root}/Playhouse/PluginDev/PluginDevMain.swift" \
  -o "${plugin_dev_executable}"

# Checked without launching the selected executable, including overrides. Only
# the app's own Info.plist needs stamping now: the daemon and the CLI both
# resolve their identity from it via `Bundle.main`, since both live flat under
# this same bundle's Contents/MacOS, unlike the XPC service this replaced
# (which needed its own bundle and its own stamped Info.plist).
python3 - "${app_contents}/Info.plist" "${PLAYHOUSE_PROFILE_ROOT}" <<'PYMETA'
import plistlib
import sys
path, worktree = sys.argv[1:3]
with open(path, 'rb') as stream:
    info = plistlib.load(stream)
info['PlayhouseStoreCompatibilityVersion'] = '2'
info['PlayhouseSourceWorktree'] = worktree
with open(path, 'wb') as stream:
    plistlib.dump(info, stream)
PYMETA

chmod 755 "${cli_executable}" "${daemon_executable}" "${plugin_dev_executable}"
if [[ "${app_executable}" -ef "${cli_executable}" || "${app_executable}" -ef "${daemon_executable}" || "${app_executable}" -ef "${plugin_dev_executable}" ]]; then
  printf 'The CLI/daemon must not replace the Playhouse app executable: %s\n' "${app_executable}" >&2
  exit 1
fi

codesign --force --sign - --timestamp=none "${cli_executable}"
codesign --force --sign - --timestamp=none "${daemon_executable}"
codesign --force --sign - --timestamp=none "${plugin_dev_executable}"
printf '%s\n' "${bridge_fingerprint}" > "${bridge_stamp}"
printf 'Embedded playhouse CLI, bridge daemon and plugin dev runner in %s\n' "${app_contents}"
