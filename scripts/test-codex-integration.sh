#!/usr/bin/env bash
# Compatibility entry point: the live suite with the Codex provider.
# Prefer scripts/test-live-integration.sh --provider <claude|codex|all>.
set -euo pipefail
repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "${PLAYHOUSE_RUN_CODEX_INTEGRATION:-}" != "1" && "${PLAYHOUSE_RUN_LIVE_INTEGRATION:-}" != "1" ]]; then
  printf 'Set PLAYHOUSE_RUN_CODEX_INTEGRATION=1 to run live Codex turns.\n' >&2
  exit 2
fi
PLAYHOUSE_RUN_LIVE_INTEGRATION=1 exec "${repository_root}/scripts/test-live-integration.sh" --provider codex "$@"
