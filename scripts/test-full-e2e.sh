#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 "${repository_root}/scripts/check-test-parity.py"
"${repository_root}/scripts/test-e2e.sh"
"${repository_root}/scripts/test-ui-tart.sh"

printf 'Full StationAI E2E verification passed: CLI/XPC first, then visible UI.\n'
