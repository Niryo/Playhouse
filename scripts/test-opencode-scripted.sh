#!/usr/bin/env bash
# Scripted OpenCode suite: Playhouse drives the real installed `opencode` binary, whose model is
# a local scripted OpenAI-compatible server (scripts/fixtures/opencode-model-server.py), so it
# checks Playhouse against the OpenCode release on this machine with no account and no tokens.
#   scripts/test-opencode-scripted.sh [--opencode <path>]
# PLAYHOUSE_OPENCODE_BINARY names the binary when --opencode is omitted; else `opencode` on PATH.
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repository_root}/scripts/app-profile.sh"
playhouse_load_app_profile "${repository_root}"
run_key="$(python3 -c 'import uuid; print(uuid.uuid4().hex)')"
fixture_root="${TMPDIR:-/tmp}/playhouse-opencode-scripted-${run_key}-fixture"
derived_data="${TMPDIR:-/tmp}/Playhouse-OpenCode-Scripted-${run_key}"
app_bundle="${PLAYHOUSE_APP_PATH:-${derived_data}/Build/Products/Debug/Playhouse.app}"
cleanup() {
  [[ -z "${PLAYHOUSE_APP_PATH:-}" ]] && rm -rf "${derived_data}"
  rm -rf "${fixture_root}"
}
trap cleanup EXIT
if [[ -z "${PLAYHOUSE_APP_PATH:-}" ]]; then
  architecture="$(uname -m)"
  xcodebuild build -quiet \
    -project "${repository_root}/Playhouse.xcodeproj" \
    -scheme Playhouse \
    -configuration Debug \
    -destination "platform=macOS,arch=${architecture}" \
    -derivedDataPath "${derived_data}" \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGN_IDENTITY=- \
    ARCHS="${architecture}" \
    ONLY_ACTIVE_ARCH=YES \
    PLAYHOUSE_APP_BUNDLE_IDENTIFIER="${PLAYHOUSE_PROFILE_BUNDLE_ID}.e2e.opencodescripted.${run_key}"
fi
test -x "${app_bundle}/Contents/MacOS/playhouse-cli"
python3 "${repository_root}/scripts/prepare-e2e-fixture.py" --fixture-root "${fixture_root}"
PLAYHOUSE_APP_PATH="${app_bundle}" PLAYHOUSE_BRIDGE_TEST_FIXTURE_ROOT="${fixture_root}" \
  python3 "${repository_root}/scripts/test-opencode-scripted.py" "$@"
