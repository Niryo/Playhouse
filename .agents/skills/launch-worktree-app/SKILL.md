---
name: launch-worktree-app
description: Build and launch the StationAI macOS app from a chosen source worktree with a window title identifying that worktree. Use when asked to open or relaunch a distinguishable local StationAI instance.
---

# Launch a StationAI worktree app

Run the chosen worktree's `scripts/run.sh` from that worktree root. For the current worktree:

```bash
./scripts/run.sh
```

For another worktree, run its own `scripts/run.sh` using its absolute path. Do not run this repository's launcher while pointing it at another worktree: the script derives its build and app profile from its own location.

The launcher builds the app, closes an existing StationAI instance from the same worktree, and opens the new build. It uses the current branch as the window label, or the worktree directory name for a detached HEAD, producing `StationAI — <label>`. Linked worktrees have separate app identities and data directories, so their instances can run together.

When launching a linked worktree, if `scripts/run.sh` reports that `STATIONAI_DATA_DIRECTORY` points elsewhere, the shell inherited the primary app's data-directory override. Retry with that override removed so the launcher uses this worktree's isolated profile:

```bash
env -u STATIONAI_DATA_DIRECTORY ./scripts/run.sh
```

For another worktree, run the same command from its root (or pass its `scripts/run.sh` absolute path). Do not replace the worktree's isolated data directory with the primary app's directory.

Launch directly without acquiring or waiting for an app lock. In particular, the repository's `.e2e.lock` serializes visible UI test runs; it does not apply to `scripts/run.sh` or direct app sessions.

Report which worktree was launched and the expected window title. If the launch fails, report the command's error and resolve an actionable local cause before retrying.
