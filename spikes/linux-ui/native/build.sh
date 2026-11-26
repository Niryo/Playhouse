#!/usr/bin/env bash
# Builds and runs the native macOS reference card from the app's real sources,
# without modifying them: TaskItemView.swift (minus its BoardTask initializer
# extension, which drags in the whole data model), the atoms it uses, the
# plugin prop types, BoardTask.swift (for CPUUsageHeatmap) and
# TokenCounterButton extracted from TokenStatsView.swift. Shims.swift stands in
# for WorkspaceTheme and the hover-cursor helper.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
A="$ROOT/Playhouse/App"
OUT="${1:-$HERE/../out}"
T="$(mktemp -d /tmp/native-card.XXXXXX)"
mkdir -p "$OUT"
awk 'NR<64 || NR>110' "$A/TaskItemView.swift" > "$T/TaskItemView.swift"
{ echo "import SwiftUI"; awk '/^struct TokenCounterButton/{p=1} p{print} p&&/^}/{exit}' "$A/TokenStatsView.swift"; } > "$T/TokenCounterButton.swift"
swiftc -O -swift-version 5 -Xfrontend -solver-expression-time-threshold=600 -parse-as-library -target "$(uname -m)-apple-macos15" -o "$T/native-card" \
  "$HERE/main.swift" "$HERE/Shims.swift" "$T/TaskItemView.swift" "$T/TokenCounterButton.swift" \
  "$A/Plugins/Atoms/AtomViews.swift" "$A/Plugins/Atoms/AtomContentViews.swift" \
  "$A/Plugins/Atoms/AtomSelectionViews.swift" "$A/Plugins/Atoms/AtomHighlight.swift" \
  "$A/Plugins/Atoms/AtomImageLoader.swift" "$A/Plugins/Core/"*.swift "$A/BoardTask.swift"
"$T/native-card" "$HERE/../shared/sample-task.json" "$OUT"
rm -rf "$T"
