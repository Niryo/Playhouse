#!/usr/bin/env bash
# Installs the latest Playhouse release (or --version x.y.z) into /Applications
# (or --destination <folder>). Later versions update themselves from inside the app.
#
# Releases are signed with a self-signed certificate and not notarized, so a
# copy downloaded by a browser is blocked by Gatekeeper. This script downloads
# it without the quarantine flag, checks it against the release's checksum, and
# moves it into place.
set -euo pipefail

repository="Niryo/Playhouse"
destination="/Applications"
version=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) version="${2#v}"; shift 2 ;;
    --destination) destination="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'install-release: unknown option %s\n' "$1" >&2; exit 2 ;;
  esac
done

[[ "$(uname -m)" == "arm64" ]] || { printf 'install-release: Playhouse releases are for Apple Silicon Macs.\n' >&2; exit 1; }
if [[ -n "${version}" ]]; then
  manifest_url="https://github.com/${repository}/releases/download/v${version}/playhouse-release.json"
else
  manifest_url="https://github.com/${repository}/releases/latest/download/playhouse-release.json"
fi

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
curl -fsSL "${manifest_url}" -o "${work}/manifest.json"
# Parse with plutil and base64, which every Mac has. /usr/bin/python3 is only a
# stub that offers the Command Line Tools on a Mac without them.
manifest_field() {
  plutil -extract "$1" raw -o - "$2" 2>/dev/null \
    || { printf 'install-release: the release manifest has no %s.\n' "$1" >&2; exit 1; }
}
manifest_field payload "${work}/manifest.json" | base64 -D > "${work}/release-info.json"
asset_url="$(manifest_field asset.url "${work}/release-info.json")"
asset_size="$(manifest_field asset.size "${work}/release-info.json")"
asset_sha="$(manifest_field asset.sha256 "${work}/release-info.json")"
version="$(manifest_field version "${work}/release-info.json")"
printf 'Downloading Playhouse %s...\n' "${version}"
curl -fL --progress-bar "${asset_url}" -o "${work}/Playhouse.zip"
[[ "$(stat -f %z "${work}/Playhouse.zip")" == "${asset_size}" ]] || { printf 'install-release: the download has the wrong size.\n' >&2; exit 1; }
[[ "$(shasum -a 256 "${work}/Playhouse.zip" | cut -d' ' -f1)" == "${asset_sha}" ]] || { printf 'install-release: the download has the wrong checksum.\n' >&2; exit 1; }
ditto -x -k "${work}/Playhouse.zip" "${work}/unpacked"
codesign --verify --strict --deep "${work}/unpacked/Playhouse.app"

target="${destination%/}/Playhouse.app"
if pgrep -f "^${target}/Contents/MacOS/Playhouse$" >/dev/null; then
  printf 'Quit Playhouse first, then run this again.\n' >&2
  exit 1
fi
if [[ -e "${target}" ]]; then
  rm -rf "${target}.previous-install"
  mv "${target}" "${target}.previous-install"
fi
mv "${work}/unpacked/Playhouse.app" "${target}"
xattr -dr com.apple.quarantine "${target}" 2>/dev/null || true
rm -rf "${target}.previous-install"
printf 'Installed Playhouse %s at %s\n' "${version}" "${target}"
