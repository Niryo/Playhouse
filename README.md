# StationAI

StationAI is a native macOS task board for coordinating work across agents. The MVP provides a Kanban board, task creation, drag-and-drop status changes, and local persistence.

## Run the app

Open `StationAI.xcodeproj` in Xcode and run the `StationAI` scheme. The app targets macOS 14 and later.

To build and launch it from the terminal, run:

```sh
./scripts/run.sh
```

The script resolves the repository location and stores its build products under the system temporary directory.

Tasks are stored locally with SwiftData and remain available after the app closes.

## CLI bridge

StationAI bundles a `stationai-cli` command-line tool beside the GUI executable and an on-demand XPC service inside the app. The CLI uses the same task, workspace, settings, and conversation managers as the GUI and returns versioned JSON. Conversation sends print JSON event lines while Codex streams, followed by the final response.

Run a command from the repository:

```sh
./scripts/stationai.sh status
./scripts/stationai.sh board list
./scripts/stationai.sh task list
```

The repository wrapper builds the app bundle if needed and routes each command through the bundled CLI. See [docs/bridge.md](docs/bridge.md) for the command list and JSON behavior.

## End-to-end verification

The default CLI suite is headless. It builds the real app, creates committed Git fixtures under `/tmp`, and invokes the bundled CLI through fresh XPC connections against isolated on-disk SwiftData and preferences. It covers task CRUD, validation, status changes, multi-root persistence, settings, repository suggestions, and conversation history. The shared contract defines the exact required case set; there is no independent fixed test-count threshold.

Run just the CLI/XPC suite with:

```sh
./scripts/test-e2e.sh
```

The visible UI suite launches StationAI and exercises the same named cases through the real interface:

```sh
./scripts/test-ui.sh
```

For a focused UI safety pass, select the paired case IDs:

```bash
./scripts/test-ui.sh --case test_task_creation_persists_ordered_roots_across_fresh_connections
```

For full end-to-end coverage, the combined script checks that the CLI and UI tests have exactly matching case names and shared expectation text, runs CLI/XPC first, then launches the UI suite:

```sh
./scripts/test-full-e2e.sh
```

The fast verifier runs all CLI/XPC cases and checks that the UI suite has the exact same case IDs and expectations. After the CLI gate passes, the UI verifier runs only the paired cases affected by the change. Keep `./scripts/test-full-e2e.sh` for deliberate full E2E runs across every CLI and UI case. Add the same named case and shared expectation to both suites for each new behavior; `scripts/check-test-parity.py` rejects unmatched, duplicate, or mismatched cases. The UI suite needs a logged-in macOS desktop session with XCTest UI automation available. It does not require Codex sign-in.

Real Codex turns use a separate opt-in suite that requires a working `codex login` and Luna access:

```sh
STATIONAI_RUN_CODEX_INTEGRATION=1 ./scripts/test-codex-integration.sh
```

See `AGENTS.md` for the development testing, Git, and task-verification rules.
