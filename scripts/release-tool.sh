#!/bin/bash
# Runs scripts/release-tool.swift, compiling it once per source version into
# /tmp. See that file for its commands.
set -euo pipefail

source_file="$(cd "$(dirname "$0")" && pwd)/release-tool.swift"
digest="$(shasum -a 256 "${source_file}" | cut -c1-16)"
# PLAYHOUSE_RELEASE_TOOL_CACHE names another folder for the compiled tool. The UI
# tests compile it there before the sandboxed runner, which can't run xcrun, uses it.
tool="${PLAYHOUSE_RELEASE_TOOL_CACHE:-/tmp/playhouse-release-tool-$(id -u)}/release-tool-${digest}"

if [[ ! -x "${tool}" ]]; then
  mkdir -p "$(dirname "${tool}")"
  xcrun swiftc -O "${source_file}" -o "${tool}.partial.$$" >&2
  mv -f "${tool}.partial.$$" "${tool}"
fi

exec "${tool}" "$@"
