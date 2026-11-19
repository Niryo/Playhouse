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
# The tools follow the app's own SWIFT_OPTIMIZATION_LEVEL, which Xcode passes to this
# phase, so the app and its daemon and CLI are always built alike. Run outside Xcode,
# Debug is unoptimized like the project's Debug configuration, since the optimizer
# more than triples the time to compile these shared sources.
if [[ -n "${SWIFT_OPTIMIZATION_LEVEL:-}" ]]; then
  optimization_flag="${SWIFT_OPTIMIZATION_LEVEL}"
elif [[ "${CONFIGURATION:-Debug}" == "Debug" ]]; then
  optimization_flag=-Onone
else
  optimization_flag=-O
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
# the plugin core (the JavaScript runtime and node tree), shared by the app and
# the daemon's `plugin render` command.
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
  "${repository_root}/Playhouse/App/HoverRevealScrollers.swift"
  "${repository_root}/Playhouse/App/WorkspaceChanges.swift"
  "${repository_root}/Playhouse/App/CodexAppServerClient.swift"
  "${repository_root}/Playhouse/App/CodexSocketConnection.swift"
  "${repository_root}/Playhouse/App/ConversationModel.swift"
  "${repository_root}/Playhouse/App/ClaudeCodeClient.swift"
  "${repository_root}/Playhouse/App/ProviderRequestLog.swift"
  "${repository_root}/Playhouse/App/ProcessCPUSampler.swift"
  "${repository_root}/Playhouse/App/AgentRunHost.swift"
  "${repository_root}/Playhouse/App/ContextCompaction.swift"
  "${repository_root}/Playhouse/App/AgentUsage.swift"
  "${repository_root}/Playhouse/App/AgentUsageStore.swift"
  "${repository_root}/Playhouse/App/ConversationTranscriptStore.swift"
  "${repository_root}/Playhouse/App/StandaloneChatStore.swift"
  "${repository_root}/Playhouse/App/SkillCatalog.swift"
  "${repository_root}/Playhouse/App/RuleCatalog.swift"
  "${repository_root}/Playhouse/App/MentionCatalog.swift"
  "${repository_root}/Playhouse/App/SlashCommandCatalog.swift"
  "${repository_root}/Playhouse/App/McpCatalog.swift"
  "${repository_root}/Playhouse/App/CodexConfigTOML.swift"
  "${repository_root}/Playhouse/App/BridgeCore.swift"
  "${repository_root}/Playhouse/App/BoundedWaits.swift"
  "${repository_root}/Playhouse/App/TaskSchedule.swift"
  "${repository_root}/Playhouse/App/Plugins/Services/PluginServiceHost.swift"
  "${repository_root}/Playhouse/App/Plugins/Services/PullRequestModeService.swift"
  "${repository_root}/Playhouse/App/Plugins/Services/BuiltInCommandsPlugin.swift"
  "${repository_root}/Playhouse/App/UpdateManager.swift"
  "${repository_root}/Playhouse/Bridge/BridgeContract.swift"
  "${repository_root}/Playhouse/Bridge/CLICommandCatalog.swift"
  "${repository_root}/Playhouse/Bridge/BridgeSocket.swift"
  "${repository_root}/Playhouse/Bridge/UpdateCore.swift"
  "${repository_root}/Playhouse/Bridge/ReleaseSigningKey.swift"
  "${repository_root}/Playhouse/App/BoardConversationStorage.swift"
  "${repository_root}/Playhouse/App/BoardLifecycleStatus.swift"
  "${repository_root}/Playhouse/App/BoardOperationLocks.swift"
  "${repository_root}/Playhouse/App/BoardPromptPersistence.swift"
  "${repository_root}/Playhouse/App/BoardPullRequestLifecycle.swift"
  "${repository_root}/Playhouse/App/BoardRepositoryLifecycle.swift"
  "${repository_root}/Playhouse/App/BoardScheduling.swift"
  "${repository_root}/Playhouse/App/BoardTaskCRUD.swift"
  "${repository_root}/Playhouse/App/BoardTaskManager.swift"
  "${repository_root}/Playhouse/App/BoardUsageReporting.swift"
  "${repository_root}/Playhouse/App/ClaudeAccountUsage.swift"
  "${repository_root}/Playhouse/App/ClaudeClientMapping.swift"
  "${repository_root}/Playhouse/App/ClaudeOutputHandling.swift"
  "${repository_root}/Playhouse/App/ClaudeProcessLifecycle.swift"
  "${repository_root}/Playhouse/App/ClaudeProcessProtocol.swift"
  "${repository_root}/Playhouse/App/ClaudeSessionRunner.swift"
  "${repository_root}/Playhouse/App/ClaudeSessionSupport.swift"
  "${repository_root}/Playhouse/App/ClaudeTurnControl.swift"
  "${repository_root}/Playhouse/App/ClaudeTurnReporting.swift"
  "${repository_root}/Playhouse/App/CodexAccountUsage.swift"
  "${repository_root}/Playhouse/App/CodexMessageConversion.swift"
  "${repository_root}/Playhouse/App/CodexServerEvents.swift"
  "${repository_root}/Playhouse/App/CodexServerTransport.swift"
  "${repository_root}/Playhouse/App/CodexSharedServer.swift"
  "${repository_root}/Playhouse/App/CodexTaskInstructions.swift"
  "${repository_root}/Playhouse/App/CodexThreadLifecycle.swift"
  "${repository_root}/Playhouse/App/CodexTurnRecovery.swift"
  "${repository_root}/Playhouse/App/CodexBackgroundJobs.swift"
  "${repository_root}/Playhouse/App/CodexTurnSending.swift"
  "${repository_root}/Playhouse/App/ConversationCompaction.swift"
  "${repository_root}/Playhouse/App/ConversationHistory.swift"
  "${repository_root}/Playhouse/App/ConversationManager.swift"
  "${repository_root}/Playhouse/App/ConversationMessages.swift"
  "${repository_root}/Playhouse/App/ConversationProviderSelection.swift"
  "${repository_root}/Playhouse/App/ConversationStandaloneAutomation.swift"
  "${repository_root}/Playhouse/App/ConversationTranscriptRecording.swift"
  "${repository_root}/Playhouse/App/ConversationTurnControl.swift"
  "${repository_root}/Playhouse/App/ConversationTurnExecution.swift"
  "${repository_root}/Playhouse/App/ConversationTurnRecovery.swift"
  "${repository_root}/Playhouse/App/McpCatalogModels.swift"
  "${repository_root}/Playhouse/App/PlayhouseBridgeConversationFlow.swift"
  "${repository_root}/Playhouse/App/PlayhouseBridgeConversationOperations.swift"
  "${repository_root}/Playhouse/App/PlayhouseBridgeOverview.swift"
  "${repository_root}/Playhouse/App/PlayhouseBridgePullRequests.swift"
  "${repository_root}/Playhouse/App/PlayhouseBridgeRequestDiagnostics.swift"
  "${repository_root}/Playhouse/App/PlayhouseBridgeRuntime.swift"
  "${repository_root}/Playhouse/App/PlayhouseBridgeSettings.swift"
  "${repository_root}/Playhouse/App/PlayhouseBridgeTaskWorkspace.swift"
  "${repository_root}/Playhouse/App/PlayhouseDiagnostics.swift"
  "${repository_root}/Playhouse/App/PlayhouseStore.swift"
  "${repository_root}/Playhouse/App/PlayhouseWorktreeServices.swift"
  "${repository_root}/Playhouse/App/ProviderTokenMap.swift"
  "${repository_root}/Playhouse/App/PullRequestServices.swift"
  "${repository_root}/Playhouse/App/SkillCatalogModels.swift"
  "${repository_root}/Playhouse/App/SkillManifest.swift"
  "${repository_root}/Playhouse/App/WorkspaceActivity.swift"
  "${repository_root}/Playhouse/App/WorkspaceTaskManagers.swift"
  "${plugin_core_sources[@]}"
)

cli_sources=(
  "${repository_root}/Playhouse/Bridge/BridgeContract.swift"
  "${repository_root}/Playhouse/Bridge/CLICommandCatalog.swift"
  "${repository_root}/Playhouse/Bridge/BridgeSocket.swift"
  "${repository_root}/Playhouse/Bridge/UpdateCore.swift"
  "${repository_root}/Playhouse/Bridge/ReleaseSigningKey.swift"
  "${repository_root}/Playhouse/CLI/BridgeClient.swift"
  "${repository_root}/Playhouse/CLI/PlayhouseCLI.swift"
  "${repository_root}/Playhouse/CLI/PlayhouseCLIParsing.swift"
  "${repository_root}/Playhouse/CLI/PlayhouseCLIUtilities.swift"
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
  "${repository_root}/Playhouse/Bridge/SandboxCheck.h"
  "${cli_sources[@]}"
  "${architecture}-apple-macosx${deployment_target}"
  "${sdk}"
  "$(xcrun --sdk macosx swiftc -version)"
  "${CONFIGURATION:-Debug}"
  "${optimization_flag}"
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

if [[ -x "${cli_executable}" && -x "${daemon_executable}" &&
      -f "${bridge_stamp}" && "$(cat "${bridge_stamp}")" == "${bridge_fingerprint}" ]] &&
      metadata_matches; then
  printf 'Reusing unchanged embedded bridge tools in %s\n' "${app_contents}"
  exit 0
fi

xcrun --sdk macosx swiftc \
  -swift-version 5 \
  -target "${architecture}-apple-macosx${deployment_target}" \
  -sdk "${sdk}" \
  "${optimization_flag}" \
  ${debug_flags[@]+"${debug_flags[@]}"} \
  -framework Foundation \
  -framework AppKit \
  -framework SwiftUI \
  -framework SwiftData \
  -framework Combine \
  -framework JavaScriptCore \
  -framework Security \
  -I "${grdb_module}" \
  -I "${repository_root}/Vendor/GRDB.swift/Sources/GRDBSQLite" \
  -L "${grdb_module}" \
  -lGRDB \
  -import-objc-header "${repository_root}/Playhouse/Bridge/SandboxCheck.h" \
  "${shared_sources[@]}" \
  "${repository_root}/Playhouse/Bridge/DaemonMain.swift" \
  -o "${daemon_executable}"

xcrun --sdk macosx swiftc \
  -swift-version 5 \
  -target "${architecture}-apple-macosx${deployment_target}" \
  -sdk "${sdk}" \
  "${optimization_flag}" \
  ${debug_flags[@]+"${debug_flags[@]}"} \
  -framework Foundation \
  -framework Security \
  "${cli_sources[@]}" \
  -o "${cli_executable}"


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

chmod 755 "${cli_executable}" "${daemon_executable}"
if [[ "${app_executable}" -ef "${cli_executable}" || "${app_executable}" -ef "${daemon_executable}" ]]; then
  printf 'The CLI/daemon must not replace the Playhouse app executable: %s\n' "${app_executable}" >&2
  exit 1
fi

codesign --force --sign - --timestamp=none "${cli_executable}"
codesign --force --sign - --timestamp=none "${daemon_executable}"
printf '%s\n' "${bridge_fingerprint}" > "${bridge_stamp}"
printf 'Embedded playhouse CLI and bridge daemon in %s\n' "${app_contents}"
