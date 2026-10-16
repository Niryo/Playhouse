#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tool_directory="${repository_root}/scripts/monaco-diff"
resource_directory="${repository_root}/StationAI/Resources/Monaco"

npm ci --prefix "${tool_directory}"
npm run --prefix "${tool_directory}" build
python3 "${tool_directory}/sync-assets.py" \
  "${tool_directory}/dist" \
  "${resource_directory}" \
  "${tool_directory}/node_modules/monaco-editor"
