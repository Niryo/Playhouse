# Release system and in-app updates

How Playhouse releases are published from the maintainer's Mac and how installed copies update themselves.

## Constraints

- Releases are built by hand on the maintainer's Mac; there is no remote Mac for CI.
- The repository, `Niryo/Playhouse`, is public, so the app reads releases without signing in.
- No paid Apple Developer account: releases are signed with a self-signed certificate and are not notarized.
- Apple Silicon (`arm64`) only.
- Versions are semantic (`0.5.0`). The first release is `0.1.0`.
- The maintainer's dev builds (`scripts/run.sh`) are their daily app and never update themselves.

## Why the update runs outside the app

A running app can't safely overwrite its own bundle. `Playhouse.app` holds the GUI, `playhouse-cli` and `playhouse-daemon` in `Contents/MacOS`, and the daemon outlives the window. Agents survive a daemon restart through the manifest in `AgentRunHost.swift`.

An update therefore runs as its own process. It quits the app, stops the daemon, swaps the whole bundle in one step and relaunches. Everything Playhouse ships lives inside the bundle, so the swap replaces every part.

## Maintainer workflow

### One-time setup: `scripts/release-setup.sh`

The script creates two items in the login keychain:

1. **"Playhouse Release Signing"**, a self-signed code-signing certificate. Every release is signed with it. An installed Playhouse accepts an update only when it carries the same certificate, so the app's identity stays stable and macOS permissions survive updates.
2. **"Playhouse Release Manifest Key"**, an Ed25519 private key that signs each release's `playhouse-release.json`.

It writes the key's public half into `Playhouse/Bridge/ReleaseSigningKey.swift`, which you commit. Running it again reuses whatever already exists.

Back up both items with Keychain Access → Export. If either is lost, installed copies can't verify new releases and must be reinstalled by hand.

### Publishing: `scripts/release.sh <version>` or `scripts/release.sh --bump patch|minor|major`

Options: `--notes-file <path>`, `--skip-tests`, `--dry-run`.

1. **Preflight.** The script checks:
   - it runs from the primary checkout, so the release uses bundle ID `com.playhouse.app`;
   - the Mac is `arm64`;
   - `gh` is installed and signed in;
   - the checkout is on `master`, the tree is clean, and it is in sync with `origin/master`;
   - the version is newer than the latest release, and its tag is unused;
   - `ReleaseSigningKey.swift` has a key that matches the keychain's manifest key, and the certificate exists.
2. **Notes.** The commit subjects since the previous release tag, opened in `$VISUAL` or `$EDITOR` when run from a terminal, unless `--notes-file` is given. If the SwiftData model files changed since the previous release, the script warns that the previous version must still read the new data, because a rollback restores only the app (see Data compatibility).
3. **Tests.** `scripts/test-e2e.sh` runs unless `--skip-tests` is given.
4. **Build.**
   - Release configuration, `arm64`, into `/tmp/playhouse-release/<version>/`.
   - `MARKETING_VERSION` is the version and the build number is `git rev-list --count HEAD`. Both are build settings, so nothing needs committing.
5. **Stamp and sign.**
   - `Info.plist` gets `PlayhouseGitCommit` and `PlayhouseReleaseChannel = stable`.
   - `playhouse-cli` and `playhouse-daemon` are signed with the certificate, then `Playhouse.app`.
6. **Check.**
   - `codesign --verify --strict --deep` passes.
   - The bundled CLI's `version` reports the expected version, build, commit, channel and bundle ID.
   - `update verify-bundle` accepts the bundle. It runs the same checks the updater runs.
7. **Package.**
   - `ditto -c -k --keepParent` makes `Playhouse-<version>.zip`.
   - `release-info.json` holds the version, build, commit, date, minimum macOS, architecture (`arm64`), notes, and the zip's URL, size and SHA-256.
   - `scripts/release-tool.sh sign` wraps it into `playhouse-release.json`: `{payload: base64 of the JSON bytes, signature: Ed25519 over those bytes}`.
   - `--dry-run` stops here.
8. **Publish.**
   - Creates and pushes the annotated tag `v<version>`.
   - Uploads both files to a draft release, then publishes it as latest. A draft is invisible to the latest-release link, so the app never sees a partial release.
   - Waits until the public feed serves the new version.

If a paid Apple account is added later, notarization becomes one extra step between 6 and 7.

### First install for users

```sh
curl -fsSL https://raw.githubusercontent.com/Niryo/Playhouse/master/scripts/install-release.sh | bash
```

`scripts/install-release.sh [--version x.y.z] [--destination <folder>]` installs Playhouse:

- It downloads the manifest and zip with `curl`, checks the size and SHA-256, unpacks the zip, and runs `codesign --verify`.
- It moves the app into `/Applications`, and refuses while Playhouse is running.
- `curl` downloads carry no quarantine flag, so Gatekeeper doesn't prompt.
- It does not check the manifest's Ed25519 signature, because a shell script has no Ed25519 tool to call. The first install trusts GitHub's HTTPS, as any `curl | bash` install does; every later update the app fetches checks the signature.

A zip downloaded in a browser is blocked on first launch. Allow it once with System Settings → Privacy & Security → Open Anyway. Updates the app fetches itself never prompt.

## The app

### Who updates

- Only bundles with `PlayhouseReleaseChannel = stable` update. Every other build (dev builds from `run.sh`, worktree builds, test builds) reports the `development` phase. These builds show no pill, and Settings says "This is a development build. It updates from source, not from releases." `update check`, `download` and `install` fail with `development_build`.
- The release and the dev build share bundle ID `com.playhouse.app`. The maintainer therefore doesn't run a release on their own Mac; the automated tests cover the install.
- A stable build that runs from a folder it can't write to, such as a disk image or a translocated copy, reports the `misplaced` phase. It shows no pill, Settings says "Move Playhouse to Applications to receive updates.", and the app menu's Check for Updates… is disabled. `update check`, `download` and `install` fail with `update_location`.

### Shared ownership

- `UpdateManager` (`Playhouse/App/UpdateManager.swift`) runs inside the bridge daemon and owns checking, downloading, verifying, staging and starting the installer. The window's `UpdateController` and the CLI both call it through `update.*` bridge commands, so they share one download and one state.
- Signing, verification and the installer live in `Playhouse/Bridge/UpdateCore.swift`: `ReleaseManifestVerifier`, `ReleaseBundleVerifier` and `ReleaseInstaller`.
- State lives in the app's data folder under `Updates/`:
  - `state.json`: last check, offered release, staged version, whether the install waits, last error;
  - `last-install.json`: the installer's result;
  - `Updater.log`: the installer's log.
- The download is unpacked in `Updates/download/` and staged beside the installed app. A canceled or failed download leaves nothing there.

CLI commands (all print the update status unless noted):

| Command | Purpose |
| --- | --- |
| `update status` | Channel, current version and build, phase, last check, offered release, progress, error, last install |
| `update check [--automatic true]` | Check the feed. `--automatic` is the daily check: it does nothing when daily checks are off or the last check was under a day ago |
| `update download` | Download and verify the offered release and stage it. Streams `update_progress` events. A second download while one runs is refused with `update_busy` |
| `update cancel` | Stop the running download; the release stays offered with no error, and the download command fails with `update_cancelled`. With nothing downloading it fails with `no_download` |
| `update install [--when-idle true]` | Start the installer. With `--when-idle` while agents are running turns or a message is being written, it returns `started: false` with `activeTurns` and `unsentDrafts`, and the daemon installs by itself once neither holds it. While an installer is running, another install is refused with `update_busy` |
| `update set-auto-check on\|off` | Turn the daily check on or off |
| `update launched` | Called by the window at launch: confirms a new version started, and returns the last install with its release notes until it is dismissed or, for an install, a day has passed |
| `update dismiss-notice` | Mark the last install's notice as seen |
| `update verify-bundle --bundle <app> [--version x.y.z]` | Run the bundle checks; used by `release.sh` |
| `update apply ...` | Run by the installer only |
| `version` | Version, build, commit, channel, bundle ID |
| `daemon info`, `daemon shutdown` | The running daemon's identity; stop it without starting one |

Error codes: `development_build`, `update_location`, `update_unreachable`, `update_rejected`, `no_update`, `update_busy`, `update_cancelled`, `no_download`, `update_failed`.

### Checking

- **Feed.** `https://github.com/Niryo/Playhouse/releases/latest/download/playhouse-release.json`. GitHub serves it from its download path, not the rate-limited REST API, so many users behind one address (an office NAT) aren't throttled. If that link fails, the app reads the manifest's URL from the REST `releases/latest` listing.
- **Verification.** The manifest's Ed25519 signature must verify against `ReleaseSigningKey.publicKey` whichever path delivered it. Only a version newer than the installed one, built for `arm64` and needing at most the running macOS version, is offered.
- **When.**
  - The window asks for an automatic check at launch and then every hour. The daemon reaches the network at most once a day.
  - Playhouse → Check for Updates…, Settings → Updates → Check Now, and `update check` check immediately.
- **Errors.** A failed automatic check is silent and is retried the next day. A failed manual check shows its error in Settings and in the pill.
- **Setting.** "Check for updates every day", in Settings → Updates, is on by default.

### Downloading and verifying

Download starts when the user clicks the pill, or with `update download`. Before staging, the app checks:

1. the zip's size and SHA-256 match the signed manifest;
2. the unpacked bundle has the same bundle ID, the stable channel, and the offered version;
3. `Playhouse`, `playhouse-cli` and `playhouse-daemon` are all present;
4. the code signature is valid and uses the same certificate as the installed app. An ad-hoc signature passes only when a DEBUG test build (bundle ID containing `.e2e.`) is updated.

Any failure leaves nothing staged and shows the failed state with the reason. The verified bundle is staged as `.Playhouse.app.update` beside the installed app, on the same volume so the swap is atomic.

### Restarting

- **Automatic.** After the download, the pill asks the daemon to install once nothing holds it (`update install --when-idle true`). An agent running a turn holds it, and so does a message being written: an unsent composer draft in a task or chat edited in the last 10 minutes (`draftEditedAt`, saved with the draft by both the window and the CLI). A task's description that was never typed in the composer doesn't count, and a draft left alone for 10 minutes stops counting, so a forgotten draft can't hold an update forever. While something holds it, the daemon saves the request in `state.json`, reports the `waiting` phase with `activeTurns` and `unsentDrafts`, and checks every second; when nothing holds it it starts the installer itself, reopening the app the way the app that asked to wait would have reopened. The wait belongs to the daemon, so it continues with the window closed, and a daemon started later picks up a saved wait on its first `update.*` request. The pill reads "Restart to update", and its tooltip says how many agents are still working and messages are being written.
- **Manual.** Clicking "Restart to update" while it waits installs immediately. Running agents keep working, and the new daemon reattaches them.
- **Agents during the restart.** `daemon shutdown` stops only idle provider processes. A Claude Code run with an active turn (`ClaudeCodeClient.stopRunsBeforeExit` skips runners whose turn is active) and a Codex app-server with local work (`CodexAppServerClient.stopSharedServerIfIdle` returns early while `serverHasLocalWork`) keep running, and the next daemon reattaches them through the same paths that `test_claude_turn_reattaches_after_daemon_restart` and `test_codex_turn_reattaches_after_daemon_restart` cover. Waiting for idle is shared Playhouse logic over `ConversationRuntimeSnapshot`, which counts both providers' turns, so one Claude fixture covers it.

### Applying

Just before starting it, the daemon checks the staged bundle again, so a copy changed on disk after the download is removed and reported instead of installed. It then spawns the staged bundle's `playhouse-cli update apply --staged … --target … --state-dir … [--relaunch-env NAME=value …]` in its own session, so the install logic always comes from the new version. `--relaunch-env` carries the data folder and bridge service of the app that asked, so a reopened app uses the same ones; a normal install passes none. The installer:

1. checks the staged bundle again;
2. posts the `com.playhouse.app.update.quit` distributed notification for the target and waits for the app to quit;
3. swaps the bundles with `renamex_np(RENAME_SWAP)`, so `Contents/MacOS/playhouse-cli` never goes missing for agents that call it;
4. sends `daemon shutdown` to the target's daemon and waits up to 20 seconds for it to exit. It does this after the swap, so a caller that retries while the old daemon exits starts the new version's daemon. It then keeps the old bundle as `.Playhouse.app.previous`. If the old bundle can't be moved aside, it swaps back and records `failed` with the old version unchanged;
5. runs the installed `playhouse-cli version` and `playhouse-daemon --version`, which must both report the new version;
6. if the app was running, reopens it and waits up to 60 seconds for the new version's `update launched`;
7. if a step fails, swaps the previous version back, reopens it if it was running, and records `rolledBack` with the reason;
8. otherwise deletes the previous copy and records `installed`.

The daemon waits for the installer while it lives. If the installer exits without recording a result, for example because the release's own `playhouse-cli` can't run, the daemon records `failed` and the installed app is untouched.

On its next launch the window shows the result: "Updated to X", or "Update didn't install" with the reason in the tooltip. Clicking "Updated to X" opens What's new with the release notes; closing it dismisses the notice. A failure notice is dismissed by clicking it. An install notice that was never opened is hidden after a day. The window also watches an install it started, so it shows the result when the installer doesn't quit it.

### Daemon build check

Callers send `daemon.hello` with the identity of the daemon executable they expect. A daemon whose executable was replaced on disk exits and a new one starts from the new bundle. This covers a daemon that an agent's CLI started from the old bundle during an update.

### Data compatibility

A rollback restores the app, not the SwiftData store. A release must not change the store in a way the previous release can't read.

### UI

**Pill** (`update-pill`, built from plugin atoms). A compact rounded pill at the trailing end of the main window's title bar (an `NSTitlebarAccessoryViewController`), hidden on development builds and when there is nothing to show. The offer is a muted accent fill; status text is a faint wash.

| Phase | Pill | Tooltip and click |
| --- | --- | --- |
| available | `Update` (labelled `Update to 0.5.0`) | "Playhouse 0.5.0, released November 18, 2026" with the notes. Click: download, then install once nothing holds it |
| downloading | `Downloading 42%` | Click: cancel the download |
| ready | `Restart to update` | Downloaded. Click: install once nothing holds it |
| waiting | `Restart to update` | "1 agent is still working and a message is being written, so Playhouse restarts by itself when…" Click: restart now |
| installing | `Updating…` | Disabled |
| failed | `Update failed` | The reason, then "Click to try again." |

**Notice** (`update-notice`). It shows `Updated to 0.5.0` or `Update didn't install` after an install. Clicking `Updated to 0.5.0` opens What's new (`update-notes-title`, `update-notes-body`) and closing it dismisses the notice; clicking `Update didn't install` dismisses it.

**Settings → Updates.** It shows the current version, a Check Now button, the daily-check toggle, and a summary: the offered release, the last check, or the last error. When the app is misplaced it shows only the move message.

**App menu.** Playhouse → Check for Updates…, disabled on development builds, when misplaced, and while an update is working.

## Testing

Test builds take a local feed through environment variables. They are honored only by DEBUG test bundles (bundle ID containing `.e2e.`), and the CLI and the window forward them to the daemon as `__update*` request arguments:

- `PLAYHOUSE_E2E_UPDATE_FEED_URL`: the manifest's URL on `http://127.0.0.1`;
- `PLAYHOUSE_E2E_UPDATE_API_URL`: the release listing read when the feed link fails, in place of GitHub's `releases/latest` (a test feed without it has no listing fallback);
- `PLAYHOUSE_E2E_UPDATE_PUBLIC_KEY`: the key that signs the test manifest;
- `PLAYHOUSE_E2E_UPDATE_TARGET_APP`: the installed app to update, a copy under the test's data folder.

`scripts/make-update-fixture.py` builds the fixture from the test build itself:

- an "installed" stable 0.1.0 copy;
- a 0.2.0 release zip;
- a manifest signed with a throwaway Ed25519 key;
- `api-latest.json`, the release's asset list shaped like GitHub's latest-release API.

`--architecture` and `--minimum-system` make a release this Mac can't run. Every fixture is served by `scripts/serve-update-feed.py` (`--base-url`), which serves the feed folder over HTTP on 127.0.0.1 and can send the zip slowly (`--seconds`), so every test goes through the app's network path and a test can watch progress and cancel. Its `--tamper signature|archive|checksum|broken|installer` options produce a manifest signed by another key, a zip that grew after signing (wrong size), a zip with one byte changed (same size, wrong checksum), a release whose daemon doesn't run (rolled back), or a release whose CLI doesn't run (its installer can't start).

Only the origin of the files is substituted. Verification, unpacking, staging, daemon shutdown, the swap and rollback all run for real.

Paired cases (CLI suite and Tart UI suite, in `BridgeTestContracts.json`):

| Case | Covers |
| --- | --- |
| `test_update_check_offers_signed_release_on_release_builds` | Dev builds refuse; offer, date and notes; the release listing when the feed link fails; daily check skipped within a day; manual check failure from the app menu; auto-check setting; Intel-only and future-macOS releases not offered; misplaced app offers nothing and shows no pill |
| `test_update_download_reports_progress_and_cancels` | HTTP download progress; busy refusal; cancel keeps the offer and stages nothing; unreachable feed shown as "Update failed"; clicking it retries the download, which then waits for a half-written message |
| `test_update_rejects_tampered_release` | Foreign manifest signature refused at check; archive refused at download for its size and for its checksum; nothing staged |
| `test_update_install_replaces_app_cli_and_daemon` | Progress, staging, bundle swap, new CLI version, daemon restart, cleanup, install notice with What's new until opened or a day old |
| `test_update_install_rolls_back_broken_release` | Health check failure, rollback, cleanup, rollback notice until dismissed, release still offered; an installer that can't run is reported as failed |
| `test_update_waits_for_running_agents_before_installing` | A running Claude turn and a half-written message hold the install as `waiting` with "Restart to update"; an untyped task description doesn't; the daemon installs by itself once the turn ends and the message is cleared |
| `test_update_installs_over_its_own_app_and_daemon` | The installed copy's own installer replaces itself: `verify-bundle` accepts the intact bundle and refuses an altered one, the running daemon stops and the next one reports the new version, a stale daemon reports `replacedOnDisk` and retires; the UI case also quits and reopens the installed app |
| `test_update_restart_now_keeps_claude_turn_running` | "Restart to update" while a Claude Code turn runs: the installer starts at once, a second install is refused as `update_busy`, the daemon is stopped and replaced, and the new daemon reattaches the same Claude Code process, whose answer is kept once; a daemon that is stopping refuses a raw request as `daemon_exiting` and logs it, the CLI's retry and (in the UI case) the window's update check reach the next daemon, and that daemon takes the run back |
| `test_update_restart_now_keeps_codex_turn_running` | The same with a Codex turn: the shared app-server keeps running through the update and the new daemon reconnects to it |

`scripts/release.sh --dry-run` builds, signs, verifies and packages without tagging or publishing.

## Open risks and known limits

- macOS App Management protection may stop one app from replacing another app's bundle in `/Applications`. Playhouse replaces its own bundle, which macOS allows for the same signing identity. If an install fails with a permission error, allow Playhouse in System Settings → Privacy & Security → App Management; the installer rolls back, so the old version keeps working meanwhile. The first real release should confirm this before it is relied on.
- `daemon shutdown` answers every later request `daemon_exiting` without running it, gives quick requests on open connections up to 2 seconds, then hands its agents over and exits. The CLI and the app send a refused request again (for up to 30 seconds), so it reaches the next daemon, and callers that stop a daemon wait up to 20 seconds for it to exit; no second daemon starts while the first still owns the agents. A turn's streaming connection is dropped without a reply, and its caller sees the daemon as unavailable while the agent keeps running.
- The daemon reports `installing` for up to 10 minutes after it starts the installer. Its watch on the installer ends if that daemon is stopped, so an installer that dies without writing a result is noticed only through that timeout.
- The tests' ad-hoc signed fixtures pass bundle verification only in DEBUG test bundles (bundle ID containing `.e2e.`); release builds always require the release certificate.
