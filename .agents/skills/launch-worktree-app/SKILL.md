---
name: launch-worktree-app
description: Build and launch the Playhouse macOS app from a chosen source worktree with a window title identifying that worktree. Use when asked to open or relaunch a distinguishable local Playhouse instance.
---

# Launch a Playhouse worktree app

Run the chosen worktree's `scripts/run.sh` from that worktree root, with the inherited Playhouse bridge variables cleared (see "Environment overrides" for why). For the current worktree:

```bash
env -u PLAYHOUSE_DATA_DIRECTORY -u PLAYHOUSE_BRIDGE_SERVICE_NAME -u PLAYHOUSE_BRIDGE_SOCKET_PATH ./scripts/run.sh
```

For another worktree, run its own `scripts/run.sh` using its absolute path. Do not run this repository's launcher while pointing it at another worktree: the script derives its build and app profile from its own location.

The launcher builds the app, closes an existing Playhouse instance from the same worktree, and opens the new build. It uses the current branch as the window label, or the worktree directory name for a detached HEAD, producing `Playhouse — <label>`. Linked worktrees have separate app identities and data directories, so their instances can run together.

## Environment overrides

Agent sessions inherit three variables from the Playhouse app that started them, and all three point at that app, not at the worktree being launched: `PLAYHOUSE_DATA_DIRECTORY` (its data directory) and `PLAYHOUSE_BRIDGE_SERVICE_NAME` / `PLAYHOUSE_BRIDGE_SOCKET_PATH` (its bridge daemon). `open -n` hands the launched app the caller's whole environment, so a window launched with the parent's bridge variables would send its own data directory to the parent's daemon, and every bridge request would fail with "This Playhouse worktree app cannot open another app's task store."

`scripts/run.sh` handles all three, saying so on stderr:

- A `PLAYHOUSE_DATA_DIRECTORY` that names another Playhouse app's profile directory (the primary app's or another worktree's) is replaced with this worktree's own. Any other value must match this worktree's profile; if `run.sh` rejects it with "uses this worktree's isolated data directory," do not retry unchanged or construct an app launch by hand. Clear it and rerun: `env -u PLAYHOUSE_DATA_DIRECTORY ./scripts/run.sh`.
- Bridge variables that don't name this worktree's own bridge (`playhouse_clear_inherited_bridge_overrides` in `scripts/app-profile.sh`) are dropped before `open`, so the window derives this worktree's bridge itself.

If a window already shows the task-store error, it was launched by an older `run.sh` with the parent's bridge variables. Relaunch it with `./scripts/run.sh`; it closes the old instance first.

`scripts/playhouse.sh` does not clear inherited bridge variables: it refuses with "The bridge service override does not match the selected app" rather than guess. Clear them for calls aimed at the launched worktree app, for example to create a task for the user to try:

```bash
env -u PLAYHOUSE_DATA_DIRECTORY -u PLAYHOUSE_BRIDGE_SERVICE_NAME -u PLAYHOUSE_BRIDGE_SOCKET_PATH ./scripts/playhouse.sh task list
```

Keep the variables when you report progress or outcomes for your own task through the parent app's CLI; that path needs them. Preserve other environment variables unless the launcher identifies them as the cause.

## Confirm the launch

Wait for `scripts/run.sh` to finish successfully; it builds and opens the app. Then verify that the GUI process belongs to this worktree's build, rather than relying only on the `open` command's exit status:

```bash
bash -c 'source scripts/app-profile.sh && playhouse_load_app_profile "$PWD" && playhouse_profile_processes'
```

A nonempty process ID confirms that the worktree-specific `Playhouse.app` is running. Do not use a broad `pgrep Playhouse` as the only check because another worktree may have its own app process. If the profile check is empty, inspect the launch/build output and resolve the local cause before reporting success.

Launch directly without acquiring or waiting for an app lock. In particular, the repository's `.e2e.lock` serializes visible UI test runs; it does not apply to `scripts/run.sh` or direct app sessions.

Report which worktree was launched, its expected window title, and that the worktree-specific process was confirmed. If the launch fails, report the command's error and resolve an actionable local cause before retrying.
