# Playhouse

Playhouse is a native macOS task board for coordinating work across agents. The MVP provides a Kanban board, task creation, drag-and-drop status changes, and local persistence.

## Run the app

Open `Playhouse.xcodeproj` in Xcode and run the `Playhouse` scheme. The app targets macOS 14 and later.

To build and launch it from the terminal, run:

```sh
./scripts/run.sh
```

The script resolves the repository location and stores its build products under the system temporary directory.

Tasks are stored locally with SwiftData and remain available after the app closes.

## CLI bridge

Playhouse bundles a `playhouse-cli` command-line tool beside the GUI executable and an on-demand XPC service inside the app. The CLI uses the same task, workspace, settings, and conversation managers as the GUI and returns versioned JSON. Conversation sends print JSON event lines while Codex streams, followed by the final response.

Run a command from the repository:

```sh
./scripts/playhouse.sh status
./scripts/playhouse.sh board list
./scripts/playhouse.sh task list
```

The repository wrapper builds the app bundle if needed and routes each command through the bundled CLI. See [docs/bridge.md](docs/bridge.md) for the command list and JSON behavior.

## End-to-end verification

The default CLI suite is headless. It builds the real app, creates committed Git fixtures under `/tmp`, and invokes the bundled CLI through fresh XPC connections against isolated on-disk SwiftData and preferences. It covers task CRUD, validation, status changes, multi-root persistence, settings, repository suggestions, and conversation history. The shared contract defines the exact required case set; there is no independent fixed test-count threshold.

Run just the CLI/XPC suite with:

```sh
./scripts/test-e2e.sh
```

The visible UI suite launches Playhouse and exercises the same named cases through the real interface. UI tests always run inside the Tart macOS VM; direct `test-ui.sh` invocations on the host hand off to the VM runner:

```sh
./scripts/test-ui.sh
```

For a focused UI safety pass, select the paired case IDs:

```bash
./scripts/test-ui.sh --case test_task_creation_persists_ordered_roots_across_fresh_connections
```

To run a UI case in a Tart macOS VM while continuing to work in the host checkout, create a VM with Xcode 26.5 (matching the project's current Xcode), then run:

```sh
./scripts/setup-ui-tart-vm.sh
./scripts/test-ui-tart.sh --case test_task_creation_persists_ordered_roots_across_fresh_connections
```

The setup script clones the Cirrus Labs Xcode 26.5 image, drops the pulled image from Tart's cache, slims the VM by removing guest components the macOS UI suite does not use (simulator runtimes, Flutter, the Android SDK, Kiro CLI, and caches; about 50 GB), and configures a 6 CPU, 12 GB VM. It requires at least 110 GiB free in Tart storage while cloning. Run `./scripts/setup-ui-tart-vm.sh --slim` to slim an existing VM; setup holds the same VM lock as the test runner, so it waits for any UI run using the VM. The runner starts the stopped VM with a shared artifact directory mounted, copies the source through it into a VM-local snapshot, and runs the existing UI suite there. Test data and build products stay in the guest during the run; logs and `.xcresult` bundles are copied to `/tmp/playhouse-ui-tart-artifacts/<run-id>/`, then the per-run guest snapshot is removed. The VM is kept running for the next run; pass `--stop-vm-after-run` to stop it when the run finishes. Use `--show-vm` to open the display and pause before testing so you can grant Xcode Helper Accessibility permission if needed; this option requires an interactive terminal. Set `PLAYHOUSE_UI_TART_VM` or pass `--vm` to select a different VM.

For full end-to-end coverage, the combined script checks that the CLI and UI tests have exactly matching case names and shared expectation text, runs CLI/XPC first, then launches the UI suite:

```sh
./scripts/test-full-e2e.sh
```

The fast verifier runs all CLI/XPC cases and checks that the UI suite has the exact same case IDs and expectations. After the CLI gate passes, the UI coverage reviewer inspects only the paired cases affected by the change and does not execute tests. Any UI execution, including full E2E runs, happens in the Tart VM. Keep `./scripts/test-full-e2e.sh` for deliberate full E2E runs across every CLI and UI case. Add the same named case and shared expectation to both suites for each new behavior; `scripts/check-test-parity.py` rejects unmatched, duplicate, or mismatched cases. The VM needs XCTest UI automation available. It does not require Codex sign-in.

`PLAYHOUSE_MUTE_SOUNDS=1` makes the app and the bridge daemon play task status sounds (Ping for Waiting Response, Glass for Review) at volume 0. The sound still "plays", so the setting check and the `task.status_sound.*` diagnostics are unchanged, and each played sound records `environmentMuted: "true"`. A daemon keeps the value it was started with. The CLI/XPC, UI, and live integration runners always set it, so test runs never play sounds through the speakers.

Real provider turns use a separate opt-in suite. It runs against Claude Code by default; pass `--provider codex` for Codex or `--provider all` to also check a Claude → Codex → Claude handoff. Claude needs a working host `claude` login; Codex needs `codex login` and Luna access. Its live UI cases also run in Tart, where the VM needs the provider CLI installed and its own guest login. Use `--show-vm` on the direct Tart command when you need to sign in interactively:

```sh
PLAYHOUSE_RUN_LIVE_INTEGRATION=1 ./scripts/test-live-integration.sh                    # Claude
PLAYHOUSE_RUN_LIVE_INTEGRATION=1 ./scripts/test-live-integration.sh --provider codex
PLAYHOUSE_RUN_LIVE_INTEGRATION=1 ./scripts/test-live-integration.sh --skip-ui --provider all
```

`scripts/test-codex-integration.sh` remains as a wrapper for `--provider codex`. For a focused live UI case after guest sign-in, run `scripts/test-ui-tart.sh --live-provider claude --case test_conversation_composer_rejects_blank_and_supports_live_turn_controls`.

See `AGENTS.md` for the development testing, Git, and task-verification rules.
