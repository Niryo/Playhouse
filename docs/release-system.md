# Release system and in-app updates

Design for publishing Playhouse releases from the maintainer's Mac and updating installed copies from inside the app. Status: design, not yet implemented.

Constraints:

- Releases are built by hand on the maintainer's Mac (no remote Mac for CI).
- The repository (`Niryo/Playhouse`) is public; the app reads releases without signing in.
- No paid Apple Developer account: no Developer ID certificate and no notarization.
- Apple Silicon (`arm64`) only.
- Versions are semantic (`0.5.0`).

## Why the update runs outside the app

A running app cannot safely overwrite its own bundle. `Playhouse.app` holds the GUI, `playhouse-cli` and `playhouse-daemon` (`Contents/MacOS`), and the daemon outlives the app (`DaemonMain.swift` exits only after it has been idle). Agents survive a daemon restart through the manifest in `AgentRunHost.swift`, so replacing the daemon does not kill agent work. The update therefore quits the app, stops the daemon, swaps the whole bundle, and relaunches.

## One-time setup: `scripts/release-setup.sh`

Creates in the login Keychain:

1. A self-signed code-signing certificate, "Playhouse Release Signing". Signing every release with it keeps the app's identity stable, so macOS permissions granted to the app survive updates.
2. A release signing key. Its public half is compiled into the app; the app installs only archives signed with it, so replaced files on GitHub cannot push an update.

Both must be backed up. Without them, installed copies cannot verify new releases and need a manual reinstall.

## Publishing: `scripts/release.sh <version>` or `--bump major|minor|patch`

1. Preflight: on `master`, clean tree, in sync with `origin`, `gh` signed in, certificate and key present, tag unused. Runs `scripts/test-e2e.sh` unless `--skip-tests`. The repository slug comes from `gh repo view`.
2. Release build (`arm64`, bundle ID `com.playhouse.app`). Marketing version from the tag, build number from `git rev-list --count HEAD`; no project file is edited. The commit hash and a release marker are written into `Info.plist`.
3. Sign `playhouse-cli`, `playhouse-daemon`, then `Playhouse.app` with the certificate. Verify with `codesign --verify --strict` and run the bundled CLI's version command.
4. Package with `ditto -c -k --keepParent` into `Playhouse-<version>.zip` and write `playhouse-release.json`: version, build number, commit, architecture, minimum macOS, zip URL, size, SHA-256, release notes, and the zip's signature.
5. Create the tag and a draft GitHub release, upload both assets, then publish. The app never sees a partial release.

If a paid account is added later, notarization becomes one extra step between 3 and 4.

## First install

- `scripts/install-release.sh` (also usable as `curl -fsSL … | bash`) downloads the zip with `curl` and unpacks it into `/Applications`. `curl` downloads carry no quarantine flag, so there is no Gatekeeper prompt.
- A zip downloaded in a browser is blocked on first launch: System Settings → Privacy & Security → Open Anyway (once). The README says so.
- Updates fetched by the app never get the quarantine flag and never prompt.
- The install script refuses on Intel Macs with a clear message.

## Checking for updates

- `UpdateManager` lives in `BridgeCore.swift`; the GUI and the CLI (`update status | check | download | install`) call the same logic.
- Feed: `https://github.com/Niryo/Playhouse/releases/latest/download/playhouse-release.json`. It is served by github.com's download path rather than the rate-limited REST API, so users behind one NAT are not throttled. Fallbacks, in order: the REST `releases/latest` endpoint, then `gh api` when `gh` is installed.
- Cadence: at launch when 24 hours have passed, plus an hourly timer that checks only once 24 hours are up (covers sleep). "Check for Updates…" in the app menu and Settings checks on demand; Settings can turn automatic checks off.
- Only release builds update. A build without the release marker (anything from `scripts/run.sh`, worktrees, or the maintainer's dev builds) reports "Development build", shows no pill, and never installs. Dev builds keep their bundle ID and data folder unchanged; an installed release app shares them, so do not run both at once.
- Updates are disabled with "Move Playhouse to Applications" when the app runs from a translocated or read-only location.
- An update is offered only when its build number is higher, its architecture matches, and the running macOS satisfies its minimum.

## User interface

An update pill sits at the trailing end of the board's top toolbar:

| State | Pill | Interaction |
| --- | --- | --- |
| Available | `Update to 0.5.0` | Hover shows version, date, release-note excerpt; click starts the download |
| Downloading | `Downloading… 42%` | Click cancels |
| Ready | `Restart to update` / `Updating when agents are idle…` | Click restarts now |
| Failed | `Update failed` | Hover shows the reason; click retries |

When the download is verified, the app restarts by itself as soon as no agent turn is running and no composer holds an unsent draft; the pill's click restarts immediately regardless. After the restart a one-time toast reads "Updated to 0.5.0 — What's new". The same status and a manual check appear in Settings.

## Applying an update

1. Download to `~/Library/Caches/<bundle-id>/Updates/<version>/`.
2. Verify: manifest signature against the built-in public key; zip size and SHA-256; after unzipping, `codesign --verify --strict` with the same signing certificate and bundle ID as the running app; build number higher than the current one.
3. Stage next to the installed app as `<install dir>/.Playhouse.app.update` (same volume, required for the atomic swap).
4. Start the installer from the staged copy: `<staged>/Contents/MacOS/playhouse-cli update apply --target <installed app> --wait-pid <app pid>`, in its own session so it outlives the app, and so the install logic always comes from the new version.
5. The old app quits normally and saves state.
6. The installer waits for the app to exit, asks the old daemon to shut down (agents are left running), and sends SIGTERM if the daemon has not exited after a timeout.
7. Swap with `renamex_np(staged, target, RENAME_SWAP)`: one atomic step, so a path such as `/Applications/Playhouse.app/Contents/MacOS/playhouse-cli` never disappears for a running agent. The old bundle becomes the backup.
8. `open` the target. The new app starts a new daemon from the new bundle, which reattaches to running agents.
9. The new app writes a launched-OK marker. If it is missing after about 30 seconds the installer swaps the backup back and relaunches; otherwise it deletes the backup.

Daemon version check: the daemon reports its build ID on connect, and an app that sees a different build asks it to shut down and reconnects to a fresh one. This also covers rebuilds during development.

Database rule: rollback restores the app, not the SwiftData store. A release must not change the store in a way the previous version cannot read.

## Why not Sparkle

Sparkle does not know about the daemon or agent reattachment, and its interface would be replaced by the toolbar pill. A small manager, one CLI command and the pill is a contained alternative.

## Testing

Paired cases in the headless CLI suite and the visible UI suite (names to be added to `BridgeTestContracts.json`):

- An update is available: the pill shows, hover details, download progress, ready state.
- A download is rejected: bad manifest signature, size/hash mismatch, and a bundle signed by a different certificate each leave the installed app untouched and show the failed state.
- Install into a test app under `/tmp` while a daemon and a reattachable agent are running: bundle swapped, new daemon serves, agent reattached; a new app that never writes the launched-OK marker is rolled back.
- Deferred restart: the update waits while an agent turn is running or a draft is unsent, and applies once idle.

Tests set `PLAYHOUSE_UPDATE_FEED_URL` to a local server that hands out a real signed zip built during the test. Only the origin of the files is substituted; verification, unzip, install, daemon shutdown and relaunch run for real. (The maintainer approved this stand-in for GitHub.) Neither Claude nor Codex is involved in updating, so there is no provider parity work.

## Open risks

- macOS App Management protection may block one app from modifying another app's bundle. Confirm with a trial run whether a self-signed Playhouse needs a one-time permission grant, and if so tell the user how.
- Until the repository is public, the feed returns 404 and no updates are visible. A temporary development option can read the feed through `gh` for early testing.

## Implementation order

1. Daemon build-ID handshake (independently useful).
2. `release-setup.sh`, `release.sh`, `install-release.sh`.
3. `UpdateManager`, feed, verification, CLI commands, test feed and paired cases.
4. Installer (`update apply`) with swap and rollback.
5. Toolbar pill, Settings section, toast, deferred restart.
