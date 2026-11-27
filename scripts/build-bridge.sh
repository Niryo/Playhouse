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

# The daemon links the same PlayhouseCore module the app builds from Playhouse/Core (every
# Swift file in it), compiled here as its own static module because this raw swiftc build
# can't resolve Swift packages. The app target's macOS platform services are compiled into
# the daemon itself, which installs them at launch.
core_sources=()
while IFS= read -r source; do
  core_sources+=("${source}")
done < <(find "${repository_root}/Playhouse/Core" -name '*.swift' -type f | LC_ALL=C sort)
if (( ${#core_sources[@]} == 0 )); then
  printf 'No PlayhouseCore sources found in %s\n' "${repository_root}/Playhouse/Core" >&2
  exit 1
fi
daemon_sources=(
  "${repository_root}/Playhouse/Bridge/DaemonMain.swift"
  "${repository_root}/Playhouse/App/Platform/MacPlatformServices.swift"
)

cli_sources=(
  "${repository_root}/Playhouse/Core/Bridge/BridgeContract.swift"
  "${repository_root}/Playhouse/Core/Bridge/CLICommandCatalog.swift"
  "${repository_root}/Playhouse/Core/Bridge/BridgeSocket.swift"
  "${repository_root}/Playhouse/Core/Bridge/UpdateCore.swift"
  "${repository_root}/Playhouse/Core/Bridge/ReleaseSigningKey.swift"
  "${repository_root}/Playhouse/Core/Platform/Hashing.swift"
  "${repository_root}/Playhouse/Core/Platform/POSIX.swift"
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
  "${core_sources[@]}"
  "${daemon_sources[@]}"
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

core_module="$(mktemp -d "${TARGET_TEMP_DIR:-${TMPDIR:-/tmp}}/playhouse-core.XXXXXX")"
trap 'rm -rf "${core_module}"' EXIT
xcrun --sdk macosx swiftc \
  -parse-as-library \
  -swift-version 5 \
  -module-name PlayhouseCore \
  -package-name playhouse \
  -target "${architecture}-apple-macosx${deployment_target}" \
  -sdk "${sdk}" \
  "${optimization_flag}" \
  ${debug_flags[@]+"${debug_flags[@]}"} \
  -I "${grdb_module}" \
  -I "${repository_root}/Vendor/GRDB.swift/Sources/GRDBSQLite" \
  -emit-module \
  -emit-module-path "${core_module}/PlayhouseCore.swiftmodule" \
  -emit-library -static \
  -o "${core_module}/libPlayhouseCore.a" \
  "${core_sources[@]}"

xcrun --sdk macosx swiftc \
  -swift-version 5 \
  -package-name playhouse \
  -target "${architecture}-apple-macosx${deployment_target}" \
  -sdk "${sdk}" \
  "${optimization_flag}" \
  ${debug_flags[@]+"${debug_flags[@]}"} \
  -framework Foundation \
  -framework AppKit \
  -framework ServiceManagement \
  -framework JavaScriptCore \
  -framework Security \
  -I "${core_module}" \
  -L "${core_module}" \
  -lPlayhouseCore \
  -I "${grdb_module}" \
  -I "${repository_root}/Vendor/GRDB.swift/Sources/GRDBSQLite" \
  -L "${grdb_module}" \
  -lGRDB \
  -import-objc-header "${repository_root}/Playhouse/Bridge/SandboxCheck.h" \
  "${daemon_sources[@]}" \
  -o "${daemon_executable}"

xcrun --sdk macosx swiftc \
  -swift-version 5 \
  -target "${architecture}-apple-macosx${deployment_target}" \
  -sdk "${sdk}" \
  "${optimization_flag}" \
  ${debug_flags[@]+"${debug_flags[@]}"} \
  -package-name playhouse \
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
