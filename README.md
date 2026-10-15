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

## End-to-end verification

The UI test launches the real app with a temporary on-disk SwiftData store, creates multiple tasks, moves one between columns, relaunches the app, checks persistence, and attaches screenshots for visual review. It does not mock app behavior or persistence.

Run the full end-to-end suite on macOS with:

```sh
./scripts/test-e2e.sh
```

See `AGENTS.md` for the development testing, Git, and task-verification rules.
