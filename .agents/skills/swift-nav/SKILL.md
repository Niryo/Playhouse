---
name: swift-nav
description: Navigate Swift source structure in the Playhouse repository with sourcekit-lsp.
---

# Swift source navigation

Use this skill when exploring Swift code in the Playhouse repository. Run `scripts/swift-nav.py` from any worktree; it finds the repository root and manages its per-worktree sourcekit-lsp helper.

**Run `outline` before reading any Swift file over 1,000 lines. Use `show` to read a symbol instead of guessing offset/limit. Use `refs` instead of repeated greps for a symbol. Do not re-read a range already in context.**

Commands:

- `scripts/swift-nav.py outline FILE [SCOPE]` lists nested types, extensions, and functions with source line ranges. Add `--vars` for properties and enum cases, or `--depth 2` for a compact high-level view.
- `scripts/swift-nav.py show FILE SYMBOL` prints the exact source with line numbers. Qualify nested members (`ConversationManager.sendTurn`). If a name is overloaded, use `--line N` to select the declaration or `--all` to print candidates. `--signature-only` and `--context N` are available.
- `scripts/swift-nav.py refs SYMBOL` lists definitions and uses across the repository. The current fallback is explicitly best-effort and labels matches; verify ambiguous short names in context.
- `scripts/swift-nav.py status` reports helper PID, worktree, idle time, and memory; `stop` stops the current worktree's helper.

Examples:

```sh
scripts/swift-nav.py outline Playhouse/Core/Bridge/BridgeCore.swift --depth 2
scripts/swift-nav.py show Playhouse/Core/Bridge/BridgeCore.swift BridgeRequest.requiredInt
scripts/swift-nav.py show Playhouse/Views/TaskConversationView.swift TaskConversationView.body
scripts/swift-nav.py refs ConversationManager
```

If sourcekit-lsp or the helper is unavailable, use `rg` to locate the declaration, then read a narrow range around that hit. For Claude edits, first Read the exact range printed by `show` so the editor has current source context. The script always sends current file contents to the server, so edits between calls are reflected.
