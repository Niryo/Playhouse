---
name: launch-worktree-app
description: Build and launch the Playhouse macOS app from a chosen source worktree with a window title identifying that worktree. Use when asked to open or relaunch a distinguishable local Playhouse instance.
---

# Launch a Playhouse worktree app

Run the chosen worktree's `scripts/run.sh` from that worktree root. For the current worktree:

```bash
./scripts/run.sh
```

For another worktree, run its own `scripts/run.sh` using its absolute path. Do not run this repository's launcher while pointing it at another worktree: the script derives its build and app profile from its own location.

The launcher builds the app, closes an existing Playhouse instance from the same worktree, and opens the new build. It uses the current branch as the window label, or the worktree directory name for a detached HEAD, producing `Playhouse — <label>`. Linked worktrees have separate app identities and data directories, so their instances can run together.

## Environment overrides

`PLAYHOUSE_DATA_DIRECTORY` must either be unset or match the selected worktree's isolated profile. If `scripts/run.sh` rejects the inherited value with “uses this worktree’s isolated data directory,” do not retry unchanged and do not manually construct an app launch. Clear only that override and rerun the worktree launcher:

```bash
env -u PLAYHOUSE_DATA_DIRECTORY ./scripts/run.sh
```

This lets `run.sh` select the profile directory computed by `scripts/app-profile.sh`. Preserve other environment variables unless the launcher identifies them as the cause.

## Confirm the launch

Wait for `scripts/run.sh` to finish successfully; it builds and opens the app. Then verify that the GUI process belongs to this worktree's build, rather than relying only on the `open` command's exit status:

```bash
bash -c 'source scripts/app-profile.sh && playhouse_load_app_profile "$PWD" && playhouse_profile_processes'
```

A nonempty process ID confirms that the worktree-specific `Playhouse.app` is running. Do not use a broad `pgrep Playhouse` as the only check because another worktree may have its own app process. If the profile check is empty, inspect the launch/build output and resolve the local cause before reporting success.

Launch directly without acquiring or waiting for an app lock. In particular, the repository's `.e2e.lock` serializes visible UI test runs; it does not apply to `scripts/run.sh` or direct app sessions.

Report which worktree was launched, its expected window title, and that the worktree-specific process was confirmed. If the launch fails, report the command's error and resolve an actionable local cause before retrying.
