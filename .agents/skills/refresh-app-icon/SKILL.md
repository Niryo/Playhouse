---
name: refresh-app-icon
description: Refresh and verify the StationAI macOS Dock icon after AppIcon artwork changes when the Dock still shows an older image.
---

# Refresh the StationAI Dock icon

Use this for an icon that is already in `StationAI/Assets.xcassets/AppIcon.appiconset/AppIcon.png` but has not appeared in the Dock. Work from the source worktree whose app the user wants to run.

## Identify the app

Run `scripts/app-profile.sh "$PWD"` from that worktree. Its `derivedData` value identifies the app built by that worktree's `scripts/run.sh`: `<derivedData>/Build/Products/Debug/StationAI.app`. A bundle under `/private/tmp/StationAI-DerivedData-manual-*` is a separate manual E2E build; rebuilding it does not update the normal `run.sh` app. Check running copies with:

```bash
pgrep -x StationAI | xargs -I{} ps -p {} -o pid=,lstart=,command=
```

If multiple copies are running, identify their exact bundle paths before closing one. Keep other worktree or test instances that the user still needs.

## Refresh in this order

```bash
killall iconservicesagent 2>/dev/null || true
./scripts/run.sh
killall Dock
```

`run.sh` rebuilds the selected worktree's app, closes its previous instance, and launches the new one. macOS restarts `iconservicesagent` and Dock automatically. Restart Dock **after** the new app launches: restarting it earlier can leave the old running-app tile visible. For a linked worktree whose launcher rejects an inherited `STATIONAI_DATA_DIRECTORY`, use `env -u STATIONAI_DATA_DIRECTORY ./scripts/run.sh` in the middle step.

## Verify the actual Dock tile

Confirm the running process path matches the profile's app bundle. Inspect that bundle's `Contents/Resources/AppIcon.icns` if there is doubt about what was built; `sips -s format png <path-to-AppIcon.icns> --out /tmp/stationai-app-icon-check.png` makes it viewable. Then inspect the **visible Dock** or a screenshot of it. The running app tile is on the app side of the Dock divider and has a dot beneath it. A playhouse image on the other side of the divider can be a minimized window thumbnail and does not prove the app tile changed.

If the tile still shows older artwork, inspect its **Options → Show in Finder** target if it is pinned, and compare all running StationAI process paths. Close only the confirmed stale copy, relaunch the intended worktree app, and restart Dock once more. Do not report success from the bundle icon or `NSRunningApplication.icon` alone; both can show new artwork while the Dock still shows an old tile.
