#!/usr/bin/env bash
set -euo pipefail

repository_root="${SRCROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${repository_root}/scripts/app-profile.sh"
stationai_load_app_profile "${repository_root}"
stationai_verify_build_identity "${PRODUCT_BUNDLE_IDENTIFIER:-com.stationai.app}"
app_contents="${TARGET_BUILD_DIR:?}/${CONTENTS_FOLDER_PATH:?}"
app_macos="${app_contents}/MacOS"
cli_executable="${app_macos}/stationai-cli"
app_executable="${app_macos}/${EXECUTABLE_NAME:?}"
service_bundle="${app_contents}/XPCServices/StationAIBridge.xpc"
service_contents="${service_bundle}/Contents"
service_macos="${service_contents}/MacOS"
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

mkdir -p "${app_macos}" "${service_macos}"

if [[ ! -x "${app_executable}" ]]; then
  printf 'The StationAI app executable is missing before the bridge tools are embedded: %s\n' "${app_executable}" >&2
  exit 1
fi

shared_sources=(
  "${repository_root}/StationAI/App/BoardTask.swift"
  "${repository_root}/StationAI/App/WorkspaceSupport.swift"
  "${repository_root}/StationAI/App/WorkspaceChanges.swift"
  "${repository_root}/StationAI/App/CodexAppServerClient.swift"
  "${repository_root}/StationAI/App/ConversationModel.swift"
  "${repository_root}/StationAI/App/ClaudeCodeClient.swift"
  "${repository_root}/StationAI/App/ConversationTranscriptStore.swift"
  "${repository_root}/StationAI/App/BridgeCore.swift"
  "${repository_root}/StationAI/Bridge/BridgeContract.swift"
)

bridge_stamp="${TARGET_BUILD_DIR}/.stationai-bridge-build-stamp-${PRODUCT_BUNDLE_IDENTIFIER//./_}"
bridge_inputs=(
  "${BASH_SOURCE[0]}"
  "${shared_sources[@]}"
  "${repository_root}/StationAI/Bridge/XPCServiceMain.swift"
  "${repository_root}/StationAI/Bridge/BridgeContract.swift"
  "${repository_root}/StationAI/CLI/BridgeClient.swift"
  "${repository_root}/StationAI/CLI/StationAICLI.swift"
  "${architecture}-apple-macosx${deployment_target}"
  "${sdk}"
  "$(xcrun --sdk macosx swiftc -version)"
  "${CONFIGURATION:-Debug}"
  "${PRODUCT_BUNDLE_IDENTIFIER:-com.stationai.app}"
  "${MARKETING_VERSION:-1.0}"
  "${CURRENT_PROJECT_VERSION:-1}"
  "${STATIONAI_PROFILE_ROOT}"
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
  local service_info="${service_contents}/Info.plist"
  [[ -f "${app_info}" && -f "${service_info}" ]] || return 1
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :StationAIStoreCompatibilityVersion' "${app_info}" 2>/dev/null)" == "2" ]] &&
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :StationAISourceWorktree' "${app_info}" 2>/dev/null)" == "${STATIONAI_PROFILE_ROOT}" ]] &&
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :StationAIStoreCompatibilityVersion' "${service_info}" 2>/dev/null)" == "2" ]] &&
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :StationAISourceWorktree' "${service_info}" 2>/dev/null)" == "${STATIONAI_PROFILE_ROOT}" ]]
}

if [[ -x "${cli_executable}" && -x "${service_macos}/StationAIBridge" &&
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
  "${shared_sources[@]}" \
  "${repository_root}/StationAI/Bridge/XPCServiceMain.swift" \
  -o "${service_macos}/StationAIBridge"

xcrun --sdk macosx swiftc \
  -swift-version 5 \
  -target "${architecture}-apple-macosx${deployment_target}" \
  -sdk "${sdk}" \
  -O \
  -framework Foundation \
  "${repository_root}/StationAI/Bridge/BridgeContract.swift" \
  "${repository_root}/StationAI/CLI/BridgeClient.swift" \
  "${repository_root}/StationAI/CLI/StationAICLI.swift" \
  -o "${cli_executable}"

service_identifier="${PRODUCT_BUNDLE_IDENTIFIER:-com.stationai.app}.bridge"
cat > "${service_contents}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>StationAIBridge</string>
  <key>CFBundleIdentifier</key><string>${service_identifier}</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>StationAIBridge</string>
  <key>CFBundlePackageType</key><string>XPC!</string>
  <key>CFBundleShortVersionString</key><string>${MARKETING_VERSION:-1.0}</string>
  <key>CFBundleVersion</key><string>${CURRENT_PROJECT_VERSION:-1}</string>
  <key>StationAIApplicationBundleIdentifier</key><string>${PRODUCT_BUNDLE_IDENTIFIER:-com.stationai.app}</string>
  <key>XPCService</key>
  <dict>
    <key>ServiceType</key><string>Application</string>
    <!-- Run in the caller's security session so provider CLIs that keep their
         sign-in in the login keychain (Claude Code) can authenticate. -->
    <key>JoinExistingSession</key><true/>
  </dict>
</dict>
</plist>
PLIST

# These are checked without launching the selected executable, including overrides.
python3 - "${app_contents}/Info.plist" "${service_contents}/Info.plist" "${STATIONAI_PROFILE_ROOT}" <<'PYMETA'
import plistlib
import sys
for path in sys.argv[1:3]:
    with open(path, 'rb') as stream:
        info = plistlib.load(stream)
    info['StationAIStoreCompatibilityVersion'] = '2'
    info['StationAISourceWorktree'] = sys.argv[3]
    with open(path, 'wb') as stream:
        plistlib.dump(info, stream)
PYMETA

chmod 755 "${cli_executable}" "${service_macos}/StationAIBridge"
if [[ "${app_executable}" -ef "${cli_executable}" ]]; then
  printf 'The CLI must not replace the StationAI app executable: %s\n' "${app_executable}" >&2
  exit 1
fi

codesign --force --sign - --timestamp=none "${cli_executable}"
codesign --force --sign - --timestamp=none "${service_bundle}"
printf '%s\n' "${bridge_fingerprint}" > "${bridge_stamp}"
printf 'Embedded stationai CLI and XPC service in %s\n' "${app_contents}"
