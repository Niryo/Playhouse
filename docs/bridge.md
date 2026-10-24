# StationAI CLI and XPC bridge

The `stationai-cli` executable is bundled at `StationAI.app/Contents/MacOS/stationai-cli` beside the GUI executable. Its distinct filename avoids macOS case-insensitive name collisions while keeping it in the application bundle's executable directory for private XPC service discovery. It connects to the app's private on-demand XPC service in `Contents/XPCServices/StationAIBridge.xpc`. Run it through `scripts/stationai.sh`, which builds the app if needed. CLI calls and app instances do not acquire the UI test lock; worktree profiles isolate app identity, XPC identity, data stores, logs, and build paths.

The service accepts a versioned JSON request, returns a versioned JSON response, and uses a reverse XPC callback for streamed conversation events. Errors include a stable code and a readable message; the CLI exits nonzero for failed operations.

## Commands

| Command | Operation |
| --- | --- |
| `status` | Service and API version |
| `board list` / `task list` | List persisted tasks |
| `task create --title <title> --repo <path> [--repo <path>...] [--branch <repo-path>=<name>] [--branch-from <repo-path>=<ref>] [--root <folder>...]` | Create one worktree per Git repository, with optional extra context folders |
| `task create --title <title> --root <folder> [--root <folder>...]` | Create a folder-only task without Git worktrees |
| `task get <task-id>` | Read a task and its thread/root state |
| `task move <task-id> <Backlog\|Ready\|In Progress\|Done>` | Change task status |
| `task rename <task-id> --title <title>` | Rename a task |
| `task roots get <task-id>` | Read ordered task roots |
| `task roots set <task-id> --root <path> [--root <path>...]` | Replace ordered task roots |
| `task delete <task-id>` | Delete a task |
| `workspace suggest --parent <path>` | Find Git repository roots below a parent folder |
| `settings get` | Read the default parent folder |
| `settings set-parent <path>` / `settings clear-parent` | Change the default parent folder |
| `task create ... [--provider <codex\|claude>]` | Create a task with a specific conversation provider instead of the default |
| `settings set-default-provider <codex\|claude>` | Change the provider new tasks start with |
| `conversation history <task-id>` | Load the task's transcript, including turns from every provider it has used |
| `conversation send <task-id> --message <text>` | Send a turn to the task's current provider and stream JSON event lines |
| `conversation stop <task-id>` | Stop the active turn, including one started by another process |
| `conversation provider <task-id>` / `conversation provider <task-id> set <codex\|claude>` | Read or switch the task's provider; switching requires a settled conversation and records a boundary |
| `conversation provider <task-id> capabilities` | Report the provider's availability, version, and capabilities |

For example:

```sh
./scripts/stationai.sh task create --title "Update parser" --repo /work/parser --root /work/fixtures
./scripts/stationai.sh task move 33F746B9-3E5E-4D84-890A-257BDB01B66A "In Progress"
./scripts/stationai.sh conversation send 33F746B9-3E5E-4D84-890A-257BDB01B66A --message "Inspect the parser and summarize its error handling."
```

Repository worktrees are created under `~/.stationAI/worktrees`; if the requested branch already has a worktree, StationAI reuses its current path. By default, the branch name is derived from the task title. `--branch` and `--branch-from` values are keyed to the repository path as `<repo-path>=<value>`. Branch creation uses `master`, or the detected default branch if `master` is absent. Moving a task to Done removes clean worktree directories while leaving their branches; a dirty worktree blocks the status change. Folder-only tasks store their roots directly.

The selected worktrees and context folders define task context and the initial working directory; they do not restrict the provider's full-access sandbox configuration.

## Shared implementation

The GUI and service both compile `BoardTaskManager`, `WorkspaceManager`, `WorkspaceSettingsManager`, and `ConversationManager` from `StationAI/App/BridgeCore.swift`. SwiftUI actions call these managers, and XPC commands dispatch to the same operations. `StationAIStore` opens the same application-support SwiftData store in both processes. In debug bridge tests, each request can supply an isolated store and defaults suite; release builds ignore those overrides.

The service bundle and CLI are built by `scripts/build-bridge.sh` during the app target's Xcode build phase. The CLI name is deliberately distinct from `StationAI` because the default macOS filesystem is case-insensitive. Keeping both executables in `Contents/MacOS` also lets the CLI discover its app's private XPC service.

## Verification

`StationAI/BridgeTests/BridgeTestContracts.json` defines the shared case IDs and their expectations. Each Python CLI case and Swift UI case carries an annotation that must exactly match the shared entry. `scripts/check-test-parity.py` fails if either suite has a missing, extra, duplicate, or mismatched case. The fast verifier reviews assertions in both implementations to confirm each pair covers the same behavior.

`scripts/test-e2e.sh` builds or reuses a content- and toolchain-matched app bundle per worktree and runs the Python CLI/XPC cases against its embedded executable and service. Each invocation has fresh committed Git fixtures and isolated app data. It does not take `.e2e.lock`, so it can overlap UI sessions and other worktrees. Build creation uses a per-worktree cache lock; callers of the exact same cached build use a build-local `.bridge-run.lock` to protect shared XPC diagnostics routing. Documentation (`docs/`, `README.md`) and agent configuration (`.agents/`, `.codex/`) do not invalidate that build cache; app resources, project settings, and build scripts remain fingerprinted. Completed builds remain cached, and fixture/log artifacts are retained in the printed directory. The runner reports static-check, build, fixture, case, and total durations; build output distinguishes cache reuse from misses, and each case reports elapsed seconds. Lock output identifies the holder PID/worktree and queue wait. Contended locks retry every 0.1 seconds, with waiting messages limited to once every 20 seconds. Runtime-discovered case names must exactly match the shared contract, with no missing, skipped, or incomplete cases. The headless suite does not start an XCTest runner or UI automation.

`scripts/test-ui-tart.sh` visibly launches the real app in the Tart VM and runs all matching cases through the user interface. Pass `--case <case-id>` once or more to run a focused subset. `scripts/test-ui.sh` on the host automatically hands off to the VM runner; the underlying UI suite runs only in the guest. It uses real persistence and the same fixture, and does not need Codex sign-in. Routine verification assigns the CLI/XPC suite to one task verifier and runs the read-only UI coverage and architecture reviews in parallel against the same fingerprint. `scripts/test-full-e2e.sh` remains available for deliberate full CLI-plus-UI runs, with its UI stage in the VM. New cases should each cover one logical behavior: small related expectations can extend an existing case, while independent behavior or distinct failure paths need a paired case in both suites.

Each headless run creates a fixture under its temporary artifact directory with clean committed Git repositories, nested-repository and symlink cases, and a marker checked before replacement. Test stores and preferences are unique per case, and persistence is checked using new CLI processes and XPC connections. The Xcode bridge adapter still uses `/tmp/stationai-bridge-workspaces` when invoked directly.

The UI suite requires XCTest UI automation in a logged-in macOS desktop session. The Cirrus Xcode VM image preconfigures Automation Mode without requiring user authentication, but Xcode Helper may still need Accessibility permission. If XCTest reports a timeout while enabling automation, rerun the same case with `scripts/test-ui-tart.sh --show-vm --case <case-id>`. The runner pauses after boot and before the test, so you can enable Xcode Helper under **System Settings > Privacy & Security > Accessibility** in the guest, then press Return to continue. This option requires an interactive terminal. The CLI-only suite remains headless for the usual development loop.

To run UI tests, first run `scripts/setup-ui-tart-vm.sh`, then use `scripts/test-ui-tart.sh [--vm <name>] [--show-vm] [--case <case-id>]`. The setup script creates the default VM from `ghcr.io/cirruslabs/macos-tahoe-xcode:26.5` with 6 CPUs and 12 GB memory; it requires at least 110 GiB free in Tart storage. This image includes Xcode 26.5, auto-login, Automation Mode configuration, and the Tart guest agent. The test runner starts the stopped VM with the checkout shared read-only, copies the checkout into guest-local storage, and runs the existing UI suite there. The VM-local copy is fixed for the run, so host edits made during testing do not affect it. Build products, fixtures, and app data remain in the guest during the run; test logs and `.xcresult` bundles are copied to `${TMPDIR}/stationai-ui-tart-artifacts/`, then the per-run guest snapshot is removed. The runner stops the VM when the run ends. Use `--show-vm` to open the display and configure Accessibility before the test starts. UI test execution on the regular host is blocked by the `test-ui.sh` handoff.

The live provider integration suite is opt-in because it requires an authenticated host provider CLI: Claude Code (the default) or Codex with access to the pinned Luna model. Run it with `STATIONAI_RUN_LIVE_INTEGRATION=1 ./scripts/test-live-integration.sh [--provider claude|codex|all] [--scenario <name>] [--skip-ui]`. Shared scenarios run against the selected provider: a plan turn, then an edit turn in two disposable Git roots with command output and diff checks, a resumed turn, and a full history reload; steering an active turn; stopping an active turn from another process; and concurrent automatic-branch claims. Claude-only scenarios cover the question round trip and the capability report; the Codex-only scenario covers the pinned model. `--provider all` also runs a Claude → Codex → Claude handoff and checks the mixed transcript's ordering and provider boundaries. Set `STATIONAI_LIVE_KEEP_WORKSPACE=1` to keep the disposable workspace for inspection. `scripts/test-codex-integration.sh` is kept as a wrapper for `--provider codex`. The live UI cases are handed off to Tart and require the provider CLI and a separate login in the guest. For an interactive guest login, run `scripts/test-ui-tart.sh --show-vm --live-provider claude --case test_conversation_composer_rejects_blank_and_supports_live_turn_controls` (`--live-codex` is an alias for `--live-provider codex`).
