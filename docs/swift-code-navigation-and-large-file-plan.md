# Swift code navigation: findings and large-file split plan

## Investigation findings

The official Claude Code `swift-lsp` plugin exists at `~/.claude/plugins/marketplaces/claude-plugins-official/plugins/swift-lsp`. It launches plain `sourcekit-lsp`, but does not configure an index, is Claude-only, is not installed in this environment, and Playhouse must not install user-home configuration. The repository-local CLI therefore supplies the shared Claude/Codex workflow; the plugin remains an optional local choice for Claude users.

`sourcekit-lsp` from the Xcode toolchain provides accurate hierarchical `documentSymbol` ranges for this Xcode project without a package manifest, build, or index. In measured runs, BridgeCore.swift returned 749 symbols in about 0.47 seconds after roughly 1 second startup, and PlayhouseUITests.swift returned 754 symbols in about 0.49 seconds. The helper keeps the server warm, reducing repeated outline/show calls to about 0.1–0.2 seconds. The output is compacted by collapsing member-heavy sections when needed.

Cross-file references require semantic indexing. The existing Playhouse DerivedData stores did not contain app units, because command-line builds do not index by default. Enabling `COMPILER_INDEX_STORE_ENABLE=YES`, providing a generated compile database, setting `--compilation-db-search-path`, and passing `initializationOptions.index.indexStorePath` did work, but index loading took about 15 seconds and the first semantic request about 4 seconds. With no build system/index, the options were ignored and reference requests took 42–49 seconds while returning no references. Accordingly, `refs` currently uses a labelled best-effort repository search plus document symbols; index-backed references can be a later improvement.

The selected backend is sourcekit-lsp. A custom Swift parser was not introduced. SwiftSyntax would require fetching/building a toolchain-matched dependency and would not provide cross-file references; tree-sitter-swift adds an install and may lag newer Swift syntax. The navigation script itself uses Python's standard library and does not access the network.

On this machine, after outlining BridgeCore.swift, the helper plus sourcekit-lsp used approximately 64–100 MB resident memory. A repo-wide `refs` request grew that to about 256–266 MB; idle usage fell to about 29 MB. A server that has only opened BridgeCore.swift is the relevant baseline for one active worktree. These are machine-specific measurements, not a memory limit.

## Proposed file split (plan only)

Current sizes observed in this worktree: `BridgeCore.swift` 11,452 lines, `TaskConversationView.swift` 9,134 lines, and `PlayhouseUITests.swift` 26,812 lines. The estimates below are rough extraction sizes based on `swift-nav outline` responsibilities, before formatting and shared-helper movement.

### BridgeCore.swift

| Proposed file | Responsibility | Rough size |
| --- | --- | ---: |
| `BridgeCore/BoardTaskManager.swift` | Task lifecycle, task persistence, task/repository attachment; current `BoardTaskManager` range 1662–5086 | 3,400 lines |
| `BridgeCore/ConversationManager.swift` | Conversation orchestration; current class range 5732–9790 plus the early extension 263–415 | 4,100 lines |
| `BridgeCore/PlayhouseBridgeRuntime.swift` | Bridge command dispatch and runtime; current range 9798–11263 | 1,600 lines |
| `BridgeCore/WorkspaceManagers.swift` | Workspace settings and workspace discovery/selection; ranges 5093–5653 | 650 lines |
| `BridgeCore/PullRequestManager.swift` | GitHub pull-request state, service and related result types; ranges 1195–1660 | 550 lines |
| `BridgeCore/StoreAndModels.swift` | Store lifecycle/schema, task records, shared conversation/value models and small support types | 1,200 lines |
| `BridgeCore/BridgeRequest+Accessors.swift` | Request decoding helpers; range 11274–11445 | 200 lines |

### TaskConversationView.swift

The file contains the conversation presentation surface plus many independently identifiable rendering, composer, transcript, and interaction helpers. A follow-up should group the outline's SwiftUI views and support models by responsibility, targeting four files: `Conversation/TaskConversationView.swift` for top-level composition and state wiring (~2,000 lines), `Conversation/TranscriptViews.swift` for message rows, markdown and transcript layout (~2,500), `Conversation/ComposerViews.swift` for the input box and draft/composer UI (~2,000), and `Conversation/ConversationSupport.swift` for formatting, measurement, and small supporting models (~2,600). Confirm ownership against a full `--vars` outline before extraction; the support estimate is intentionally broad.

### PlayhouseUITests.swift

The test file is one large XCTest class followed by shared fixtures and UI helpers. Split by user workflow into `PlayhouseUITests/TaskLifecycleUITests.swift` (~5,000 lines), `ConversationUITests.swift` (~6,000), `RepositoriesAndWorkspaceUITests.swift` (~4,000), `PluginsAndSkillsUITests.swift` (~4,000), `BoardAndPresentationUITests.swift` (~3,500), and `UITestSupport.swift` (~8,000 for shared app launch, fixture, accessibility, screenshot and assertion helpers). Move helpers only after checking their callers; where helpers are test-class-private, prefer extracting a shared support type with explicit access instead of widening everything.

### Risks and sequencing

- Swift `private` and `fileprivate` visibility can block extracted extensions and tests; preserve the current boundary where possible, then widen only the smallest required declarations.
- Moving shared helpers can create hidden coupling and alter XCTest discovery or setup behavior. Keep fixture ownership and test setup explicit, and run the focused affected UI cases during a future split.
- `PlayhouseUITests.swift` is a frequent merge-conflict hotspot. Extract in small responsibility slices and coordinate with in-flight branches before broad moves.
- Keep CLI/UI case names and shared expectations intact during UI test moves; the bridge contract and parity checker depend on them.
- The split is intentionally deferred to separate follow-up work; this task changes no production Swift files.

## Verification ledger

- **Static review:** final unstaged implementation fingerprint: `scripts/swift-nav.py` `e2b7745bf46bcf77463062c5d85ebe777a71fecbe9f086b3500658166b8cbc6b`; `scripts/test-swift-nav.py` `73ec52b7c7c93c1aa0716023dd5fc054c989a4c7f85653e7e2cacb0396308f44`; mirrored skill `e115c6af6917307fb7f026bc170fed3e8fc0c1614a60ab7e0e48d017e7e57338`; `AGENTS.md` `b790c9e6cebfe0c2c4a62ad2d7b6ee8cc7cc522e147fe78856ce56e8fa9c5c0e`; fixtures `8da156e8a772a093970ca795d5a8ecd33febd38e7684187c86073a9f89e39374` and `9fc603b3d58f29675cee5a9bd6cf8e2283eebf2aabca8ff468d3a12b76ab568c`.
- **Review decisions:** task verifier APPROVED; UI verifier APPROVED (no UI behavior or paired case applies); architecture reviewer APPROVED. Review scope was the unstaged implementation, smoke test, fixtures, skill, agent pointer, and this proposal. No staged-only content was included.
- **Runtime check:** `python3 scripts/test-swift-nav.py` passed. It exercises exact outline ranges/indentation and source extraction, overload resolution, extension lookup, labelled cross-file refs, compact production outline, helper reuse, concurrent startup and cleanup, crash recovery, file freshness, idle process exit, per-call mode, unavailable-runtime fallback, and clear not-found errors. `git diff --check` passed. The static reviewer also confirmed existing test parity (208 existing paired cases); no app bridge cases were added.
- **UI/showcase:** no UI case or screenshot was run or published because this repository developer tool has no Playhouse UI behavior to demonstrate.
- **CLI/XPC/build:** not applicable; no Playhouse product behavior or app source changed. The local smoke suite directly invokes the new CLI and sourcekit-lsp.
- **Mock audit:** no mocks, stubs, or fake implementations were added.
