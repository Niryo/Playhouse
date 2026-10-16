# StationAI CLI and XPC bridge

The `stationai-cli` executable is bundled at `StationAI.app/Contents/MacOS/stationai-cli` beside the GUI executable. Its distinct filename avoids macOS case-insensitive name collisions while keeping it in the application bundle's executable directory for private XPC service discovery. It connects to the app's private on-demand XPC service in `Contents/XPCServices/StationAIBridge.xpc`. Run it through `scripts/stationai.sh`, which builds the app if needed and serializes each command through `.e2e.lock`.

The service accepts a versioned JSON request, returns a versioned JSON response, and uses a reverse XPC callback for streamed conversation events. Errors include a stable code and a readable message; the CLI exits nonzero for failed operations.

## Commands

| Command | Operation |
| --- | --- |
| `status` | Service and API version |
| `board list` / `task list` | List persisted tasks |
| `task create --title <title> --root <path> [--root <path>...]` | Create a task with ordered working roots |
| `task get <task-id>` | Read a task and its thread/root state |
| `task move <task-id> <Backlog\|Ready\|In Progress\|Done>` | Change task status |
| `task rename <task-id> --title <title>` | Rename a task |
| `task roots get <task-id>` | Read ordered task roots |
| `task roots set <task-id> --root <path> [--root <path>...]` | Replace ordered task roots |
| `task delete <task-id>` | Delete a task |
| `workspace suggest --parent <path>` | Find Git repository roots below a parent folder |
| `settings get` | Read the default parent folder |
| `settings set-parent <path>` / `settings clear-parent` | Change the default parent folder |
| `conversation history <task-id>` | Load the task's Codex transcript |
| `conversation send <task-id> --message <text>` | Send a Codex turn and stream JSON event lines |

For example:

```sh
./scripts/stationai.sh task create --title "Update parser" --root /work/parser --root /work/fixtures
./scripts/stationai.sh task move 33F746B9-3E5E-4D84-890A-257BDB01B66A "In Progress"
./scripts/stationai.sh conversation send 33F746B9-3E5E-4D84-890A-257BDB01B66A --message "Inspect the parser and summarize its error handling."
```

The selected roots define task context and the initial working directory; they do not restrict Codex's full-access sandbox configuration.

## Shared implementation

The GUI and service both compile `BoardTaskManager`, `WorkspaceManager`, `WorkspaceSettingsManager`, and `CodexConversationManager` from `StationAI/App/BridgeCore.swift`. SwiftUI actions call these managers, and XPC commands dispatch to the same operations. `StationAIStore` opens the same application-support SwiftData store in both processes. In debug bridge tests, each request can supply an isolated store and defaults suite; release builds ignore those overrides.

The service bundle and CLI are built by `scripts/build-bridge.sh` during the app target's Xcode build phase. The CLI name is deliberately distinct from `StationAI` because the default macOS filesystem is case-insensitive. Keeping both executables in `Contents/MacOS` also lets the CLI discover its app's private XPC service.

## Verification

`StationAI/BridgeTests/BridgeTestContracts.json` defines the shared case IDs and their expectations. Each Python CLI case and Swift UI case carries an annotation that must exactly match the shared entry. `scripts/check-test-parity.py` fails if either suite has a missing, extra, duplicate, or mismatched case. The fast verifier reviews assertions in both implementations to confirm each pair covers the same behavior.

`scripts/test-e2e.sh` runs every focused, headless CLI/XPC case against the real embedded executable and service. It checks that runtime-discovered case names exactly match the shared contract. Xcode reports one bridge adapter test; the adapter launches the Python cases, and the output attachment contains their individual names and assertions.

`scripts/test-ui.sh` visibly launches the real app and runs all matching cases through the user interface. Pass `--case <case-id>` once or more to run a focused subset. It uses real persistence and the same fixture, and does not need Codex sign-in. Routine verification runs the complete CLI/XPC suite first, then invokes the UI verifier for just the affected paired cases. `scripts/test-full-e2e.sh` remains available for deliberate full CLI-plus-UI runs. New cases should each cover one logical behavior: small related expectations can extend an existing case, while independent behavior or distinct failure paths need a paired case in both suites.

The fixture at `/tmp/stationai-bridge-workspaces` includes clean committed Git repositories, nested-repository and symlink cases, and a marker checked before replacement. Test stores and preferences are unique per case, and persistence is checked using new CLI processes and XPC connections.

The UI suite requires XCTest UI automation in a logged-in macOS desktop session. On first use, macOS prompts for permission; enable Xcode Helper under **System Settings > Privacy & Security > Accessibility**. The CLI-only suite remains headless for the usual development loop.

The live Codex integration suite is opt-in because it requires an authenticated local Codex CLI with access to the pinned Luna model. Run it with `STATIONAI_RUN_CODEX_INTEGRATION=1 ./scripts/test-codex-integration.sh`. It streams a turn that edits files in two disposable Git roots, checks command output and the diff, resumes the thread, and reloads the full history.
