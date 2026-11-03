#!/usr/bin/env bash
# Builds the vendored GRDB package as a static Swift module for raw swiftc builds
# (the bridge daemon and test probes), which cannot resolve Swift packages.
# Prints the directory holding GRDB.swiftmodule and libGRDB.a. Outputs are cached
# by source/toolchain fingerprint and published atomically, so concurrent
# worktrees and builds can share them.
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
architecture="${1:-$(uname -m)}"
deployment_target="${2:-14.0}"
sdk="${3:-$(xcrun --sdk macosx --show-sdk-path)}"
package_root="${repository_root}/Vendor/GRDB.swift"
sqlite_module="${package_root}/Sources/GRDBSQLite"

sources=()
while IFS= read -r -d '' source; do
  sources+=("${source}")
done < <(find "${package_root}/GRDB" -name '*.swift' -print0 | LC_ALL=C sort -z)

fingerprint="$(
  {
    printf '%s\n' "${architecture}" "${deployment_target}" "${sdk}" "$(xcrun --sdk macosx swiftc -version 2>&1)"
    shasum -a 256 "${BASH_SOURCE[0]}" "${sqlite_module}"/* "${sources[@]}"
  } | shasum -a 256 | awk '{print $1}'
)"
cache_root="${PLAYHOUSE_GRDB_CACHE:-${HOME}/Library/Caches/PlayhouseBuild/GRDB}"
output="${cache_root}/${fingerprint}"
if [[ -f "${output}/libGRDB.a" && -f "${output}/GRDB.swiftmodule" ]]; then
  printf '%s\n' "${output}"
  exit 0
fi

mkdir -p "${cache_root}"
staging="$(mktemp -d "${cache_root}/.staging.XXXXXX")"
trap 'rm -rf "${staging}"' EXIT
xcrun --sdk macosx swiftc \
  -parse-as-library \
  -module-name GRDB \
  -swift-version 6 \
  -enable-upcoming-feature MemberImportVisibility \
  -D SQLITE_ENABLE_FTS5 \
  -D SQLITE_ENABLE_SNAPSHOT \
  -target "${architecture}-apple-macosx${deployment_target}" \
  -sdk "${sdk}" \
  -O \
  -whole-module-optimization \
  -I "${sqlite_module}" \
  -emit-module \
  -emit-module-path "${staging}/GRDB.swiftmodule" \
  -emit-library -static \
  -o "${staging}/libGRDB.a" \
  "${sources[@]}" >&2

# rename(2) refuses a non-empty target, so a concurrent build that published the
# same fingerprint first wins; both outputs are identical.
python3 -c 'import os, sys
try:
    os.rename(sys.argv[1], sys.argv[2])
except OSError:
    pass' "${staging}" "${output}"
if [[ ! -f "${output}/libGRDB.a" || ! -f "${output}/GRDB.swiftmodule" ]]; then
  printf 'Could not publish the GRDB build to %s\n' "${output}" >&2
  exit 1
fi
printf '%s\n' "${output}"
