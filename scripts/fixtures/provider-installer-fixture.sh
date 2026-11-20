#!/bin/sh
# Deterministic stand-in for the providers' official network installers, which the bridge
# and UI suites run instead of `curl ... | bash`. Run as `<fixture> <claude|codex>` from a
# folder the test owns, it logs the provider to `installs.log` beside itself, then installs
# `<provider>.payload` from that folder as the executable `<provider>`, where the test points
# PLAYHOUSE_E2E_<PROVIDER>_EXECUTABLE. A `<provider>.install-fails` file makes it fail the
# way a network installer does instead, printing that file's text.
set -eu
directory="$(cd "$(dirname "$0")" && pwd)"
provider="${1:?Name the provider to install.}"
printf '%s\n' "${provider}" >> "${directory}/installs.log"
if [ -e "${directory}/${provider}.install-fails" ]; then
  echo "Downloading ${provider}..."
  cat "${directory}/${provider}.install-fails" >&2
  exit 7
fi
echo "Downloading ${provider}..."
cp "${directory}/${provider}.payload" "${directory}/${provider}"
chmod 755 "${directory}/${provider}"
echo "Installed ${provider} to ${directory}/${provider}"
