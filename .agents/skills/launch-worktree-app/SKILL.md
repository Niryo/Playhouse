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

Agent sessions inherit three variables from the Playhouse app that started them, and all three point at that app, not at the worktree being launched:

- `PLAYHOUSE_DATA_DIRECTORY`: the parent app's data directory.
- `PLAYHOUSE_BRIDGE_SERVICE_NAME` and `PLAYHOUSE_BRIDGE_SOCKET_PATH`: the parent app's bridge daemon.

`open -n` passes the caller's whole environment to the launched app, not only its `--env` values. `scripts/run.sh` replaces `PLAYHOUSE_DATA_DIRECTORY` with the worktree's own directory, but it does not touch the two bridge variables. A window launched with them still set connects to the parent app's daemon while sending its own worktree data directory, so every bridge request fails. The window shows "This Playhouse worktree app cannot open another app's task store." when you send a message, and the terminal and other bridge-backed actions fail the same way. Local-only actions such as saving a draft keep working, which hides the problem until the first send.

Always launch with all three cleared, as above, so `run.sh` and the app resolve this worktree's own data directory and bridge from `scripts/app-profile.sh`:

```bash
env -u PLAYHOUSE_DATA_DIRECTORY -u PLAYHOUSE_BRIDGE_SERVICE_NAME -u PLAYHOUSE_BRIDGE_SOCKET_PATH ./scripts/run.sh
```

If a window already shows that error, it was launched with the parent's bridge variables. Relaunch it with the command above; `run.sh` closes the old instance first.

Clear the same three variables for `scripts/playhouse.sh` calls aimed at the launched worktree app, for example to create a task for the user to try. Otherwise the CLI refuses with "The bridge service override does not match the selected app," or reaches the parent app instead:

```bash
env -u PLAYHOUSE_DATA_DIRECTORY -u PLAYHOUSE_BRIDGE_SERVICE_NAME -u PLAYHOUSE_BRIDGE_SOCKET_PATH ./scripts/playhouse.sh task list
```

Keep the variables when you report progress or outcomes for your own task through the parent app's CLI; that path needs them.

When `PLAYHOUSE_DATA_DIRECTORY` names another Playhouse app's profile directory (the primary app's or another worktree's), `scripts/run.sh` ignores it and says so on stderr. Any other value must match the selected worktree's profile; if `run.sh` rejects it with "uses this worktree's isolated data directory," do not retry unchanged or construct an app launch by hand. Clear the variables as above and rerun the worktree launcher. Preserve other environment variables unless the launcher identifies them as the cause.

## Confirm the launch

Wait for `scripts/run.sh` to finish successfully; it builds and opens the app. Then verify that the GUI process belongs to this worktree's build, rather than relying only on the `open` command's exit status:

```bash
bash -c 'source scripts/app-profile.sh && playhouse_load_app_profile "$PWD" && playhouse_profile_processes'
```

A nonempty process ID confirms that the worktree-specific `Playhouse.app` is running. Do not use a broad `pgrep Playhouse` as the only check because another worktree may have its own app process. If the profile check is empty, inspect the launch/build output and resolve the local cause before reporting success.

Launch directly without acquiring or waiting for an app lock. In particular, the repository's `.e2e.lock` serializes visible UI test runs; it does not apply to `scripts/run.sh` or direct app sessions.

Report which worktree was launched, its expected window title, and that the worktree-specific process was confirmed. If the launch fails, report the command's error and resolve an actionable local cause before retrying.
