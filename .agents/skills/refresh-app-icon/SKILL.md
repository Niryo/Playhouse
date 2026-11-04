---
name: refresh-app-icon
description: Refresh and verify the Playhouse macOS Dock icon after AppIcon artwork changes when the Dock still shows an older image.
---

# Refresh the Playhouse Dock icon

Use this for an icon that is already in `Playhouse/Assets.xcassets/AppIcon.appiconset/AppIcon.png` but has not appeared in the Dock. Work from the source worktree whose app the user wants to run.

## Identify the app

Run `scripts/app-profile.sh "$PWD"` from that worktree. Its `derivedData` value identifies the app built by that worktree's `scripts/run.sh`: `<derivedData>/Build/Products/Debug/Playhouse.app`. A bundle under `/private/tmp/Playhouse-DerivedData-manual-*` is a separate manual E2E build; rebuilding it does not update the normal `run.sh` app. Check running copies with:

```bash
pgrep -x Playhouse | xargs -I{} ps -p {} -o pid=,lstart=,command=
```

If multiple copies are running, identify their exact bundle paths before closing one. Keep other worktree or test instances that the user still needs.

## Refresh in this order

```bash
killall iconservicesagent 2>/dev/null || true
./scripts/run.sh
killall Dock
```

`run.sh` rebuilds the selected worktree's app, closes its previous instance, and launches the new one. macOS restarts `iconservicesagent` and Dock automatically. Restart Dock **after** the new app launches: restarting it earlier can leave the old running-app tile visible. The launcher ignores a `PLAYHOUSE_DATA_DIRECTORY` inherited from another Playhouse app; if it rejects some other value, use `env -u PLAYHOUSE_DATA_DIRECTORY ./scripts/run.sh` in the middle step.

## Verify the actual Dock tile

Confirm the running process path matches the profile's app bundle. Inspect that bundle's `Contents/Resources/AppIcon.icns` if there is doubt about what was built; `sips -s format png <path-to-AppIcon.icns> --out /tmp/playhouse-app-icon-check.png` makes it viewable. Then inspect the **visible Dock** or a screenshot of it. The running app tile is on the app side of the Dock divider and has a dot beneath it. A playhouse image on the other side of the divider can be a minimized window thumbnail and does not prove the app tile changed.

If the tile still shows older artwork, inspect its **Options → Show in Finder** target if it is pinned, and compare all running Playhouse process paths. Close only the confirmed stale copy, relaunch the intended worktree app, and restart Dock once more. Do not report success from the bundle icon or `NSRunningApplication.icon` alone; both can show new artwork while the Dock still shows an old tile.

If the active (running-dot) tile is still old even though the intended bundle's `AppIcon.icns` is new and it is the only running Playhouse process, check for duplicate Launch Services registrations. Xcode, E2E, and scratchpad builds can register the same `com.playhouse.app` identifier with different icons:

```bash
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -dump
```

Inspect only records whose identifier is exactly `com.playhouse.app` (ignore test identifiers such as `com.playhouse.app.e2e`). For each candidate path, confirm that it exists, is not the intended bundle, is not running, and that its `Contents/Resources/AppIcon.icns` contains the stale artwork. Do not unregister every duplicate or delete any build. Unregister only the confirmed stale registration, then force-register the intended bundle:

```bash
"$LSREGISTER" -u "/exact/path/to/confirmed-stale/Playhouse.app"
"$LSREGISTER" -f "/exact/path/to/current/Playhouse.app"
```

Repeat the refresh sequence above, then inspect a screenshot of the visible Dock. In the reported incident, an old Claude scratchpad build was registered first for the same bundle identifier and carried the old U icon; removing just that registration and registering the `scripts/run.sh` bundle fixed the active Dock tile. This Launch Services cleanup is a fallback, not a routine first step.
