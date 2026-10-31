# StationAI → Playhouse: one-shot host migration

The app was renamed from StationAI to Playhouse. The rename changes the bundle identifier, the
UserDefaults suite, the bridge socket identity, the data directory, the log directory, the task
store filename and the worktree root, and it was done **without any migration code in the app**:
existing host state is moved once, by hand, with the checklist below. Nothing here runs at launch,
and a Playhouse build never looks at a StationAI path.

Run it once, with the app and its bridge daemon quit, from a shell whose working directory is not
inside `~/.stationAI` (that directory moves). The script is reproduced at the end of this file
rather than committed as an executable, because it is correct exactly once per machine.

## What moves

| Old | New |
|---|---|
| `~/Library/Application Support/StationAI` | `~/Library/Application Support/Playhouse` |
| `StationAI-v2.store` (+ `-wal`, `-shm`) | `Playhouse-v2.store` (+ `-wal`, `-shm`) |
| `StationAI.store` (v1, only on old installs) | `Playhouse.store` |
| `~/Library/Logs/StationAI` | `~/Library/Logs/Playhouse` |
| `~/.stationAI/worktrees` | `~/.playhouse/worktrees` |
| `com.stationai.app` preferences | `com.playhouse.app` |

## Order matters

1. **Kill stale processes first.** `playhouse_profile_processes` greps for `Playhouse`, so a
   surviving `StationAI` app or `stationai-daemon` is invisible to the new tooling and would keep
   writing to the old data directory during the move.
2. **Rename the v2 store before the v1 store.** `PlayhouseStore.importLegacyStoreIfNeeded` imports
   `Playhouse.store` only when `Playhouse-v2.store` is absent. Renaming v1 first — or forgetting v2
   — silently publishes a years-old snapshot as live data instead of failing loudly.
3. **Rewrite persisted paths, then repair git.** `RepositoryWorktreeRecord.worktreePath` is stored
   as an absolute path inside `ZBOARDTASK.ZREPOSITORYWORKTREESDATA` (JSON, escaped slashes), and the
   same records carry the hard-renamed `createdByStationAI` → `createdByPlayhouse` key. After moving
   the worktree root, each moved worktree also needs `git worktree repair`, because git records the
   old absolute path in both the worktree's `.git` file and the repository's
   `.git/worktrees/<name>/gitdir`.
4. **Drop state keyed by the old paths.** The per-worktree profile key is a hash of the source
   worktree path (`scripts/app-profile.sh`), so every
   `~/Library/Application Support/Playhouse/Worktrees/w<hash>` directory and every
   `com.stationai.app.worktree.w<hash>` preference domain is orphaned by the move. Same for
   `$TMPDIR/StationAI-DerivedData*`, `$TMPDIR/StationAI-E2E-BuildCache` and the `/tmp/stationai-*`
   fixture, socket and UI-test roots.
5. **Re-register with Launch Services** so stale `StationAI.app` bundles stop appearing.

## Tart UI-test VM

The VM is renamed `stationai-ui` → `playhouse-ui`. The image it is cloned from
(`ghcr.io/cirruslabs/macos-tahoe-xcode`) is third-party and unaffected. Stop and delete the old VM,
remove `/tmp/stationai-ui-tart-*` markers, then run `scripts/setup-ui-tart-vm.sh` to clone the new
one (~97 GB, needs ~110 GiB free). Deleting the old VM also disposes of the guest-side
`~/StationAIUITestRuns` snapshot, whose ownership marker text changed with the rename — keeping it
would fail every guest run with exit 74.

## Not covered

The checkout itself (`/Users/<you>/git/StationAI`) and the GitHub repository keep their names. The
primary profile key is the literal `primary`, so no data path depends on the folder name; a managed
worktree directory is named after the repository's last path component, which is why
`StationAI-<hash>` worktree directory names survive the migration unchanged.

## The script

```sh
#!/usr/bin/env bash
# One-shot StationAI -> Playhouse host-state migration.
#
# Run this ONCE, with the StationAI app and its bridge daemon quit, and from a
# shell whose working directory is NOT inside ~/.stationAI (this script moves
# that directory). Nothing in the app performs this migration: it is deliberately
# a one-time operation, not shipped code.
#
#   bash /tmp/playhouse-rename/migrate-to-playhouse.sh            # state only
#   bash /tmp/playhouse-rename/migrate-to-playhouse.sh --with-vm  # also delete the Tart VM
set -euo pipefail

support_old="${HOME}/Library/Application Support/StationAI"
support_new="${HOME}/Library/Application Support/Playhouse"
logs_old="${HOME}/Library/Logs/StationAI"
logs_new="${HOME}/Library/Logs/Playhouse"
root_old="${HOME}/.stationAI"
root_new="${HOME}/.playhouse"
tmp_dir="${TMPDIR:-/tmp}"
tmp_dir="${tmp_dir%/}"
with_vm=0
[[ "${1:-}" == "--with-vm" ]] && with_vm=1

step() { printf '\n== %s\n' "$1"; }

step "Preflight"
if pgrep -x StationAI >/dev/null || pgrep -x Playhouse >/dev/null \
  || pgrep -x stationai-daemon >/dev/null || pgrep -x playhouse-daemon >/dev/null; then
  printf 'Quit the app and its bridge daemon first (StationAI/Playhouse, *-daemon).\n' >&2
  exit 1
fi
case "$PWD/" in
  "${root_old}/"*) printf 'Run this from outside %s; it is about to move.\n' "${root_old}" >&2; exit 1 ;;
esac
if [[ -e "${support_new}" || -e "${root_new}" ]]; then
  printf 'Destination already exists (%s or %s). Migration looks done; refusing to overwrite.\n' \
    "${support_new}" "${root_new}" >&2
  exit 1
fi

step "Moving application support, logs and the worktree root"
[[ -d "${support_old}" ]] && mv "${support_old}" "${support_new}"
[[ -d "${logs_old}" ]] && mv "${logs_old}" "${logs_new}"
[[ -d "${root_old}" ]] && mv "${root_old}" "${root_new}"

step "Renaming the task store"
if [[ -f "${support_new}/StationAI-v2.store" ]]; then
  cp "${support_new}/StationAI-v2.store" "${support_new}/StationAI-v2.store.pre-playhouse-backup"
  sqlite3 "${support_new}/StationAI-v2.store" 'PRAGMA wal_checkpoint(TRUNCATE);' >/dev/null
  for suffix in '' '-wal' '-shm'; do
    [[ -f "${support_new}/StationAI-v2.store${suffix}" ]] &&
      mv "${support_new}/StationAI-v2.store${suffix}" "${support_new}/Playhouse-v2.store${suffix}"
  done
fi
# A v1 store only exists on installs that predate the v2 filename.
if [[ -f "${support_new}/StationAI.store" ]]; then
  mv "${support_new}/StationAI.store" "${support_new}/Playhouse.store"
fi

step "Rewriting persisted task records"
python3 - "${support_new}/Playhouse-v2.store" <<'PY'
import sqlite3, sys
store = sys.argv[1]
columns = ("ZREPOSITORYWORKTREESDATA", "ZWORKSPACEROOTPATHSDATA", "ZCONTEXTFOLDERPATHSDATA")
database = sqlite3.connect(store)
changed = 0
for column in columns:
    rows = database.execute(f"SELECT Z_PK, {column} FROM ZBOARDTASK WHERE {column} IS NOT NULL").fetchall()
    for key, blob in rows:
        if not isinstance(blob, (bytes, bytearray)):
            continue
        # Paths are stored as JSON with escaped slashes, so match the directory name alone.
        updated = blob.replace(b"createdByStationAI", b"createdByPlayhouse").replace(b".stationAI", b".playhouse")
        if updated != blob:
            database.execute(f"UPDATE ZBOARDTASK SET {column} = ? WHERE Z_PK = ?", (updated, key))
            changed += 1
database.commit()
database.close()
print(f"rewrote {changed} task columns")
PY

step "Rewriting worktree paths in on-disk JSON"
find "${support_new}" -type f \( -name '*.json' -o -name '*.jsonl' \) -print0 |
  xargs -0 -r sed -i '' 's#\.stationAI#.playhouse#g'

step "Copying preferences to the new bundle identifier"
if defaults read com.stationai.app >/dev/null 2>&1; then
  defaults export com.stationai.app - | defaults import com.playhouse.app -
  defaults delete com.stationai.app
fi
# Per-worktree and per-test suites were keyed by paths that no longer exist.
for plist in "${HOME}/Library/Preferences"/com.stationai.*.plist; do
  [[ -e "${plist}" ]] || continue
  domain="$(basename "${plist}" .plist)"
  defaults delete "${domain}" >/dev/null 2>&1 || true
  rm -f "${plist}"
done

step "Repairing moved git worktrees"
while IFS= read -r gitfile; do
  worktree="$(dirname "${gitfile}")"
  gitdir="$(sed -n 's/^gitdir: //p' "${gitfile}")"
  repository="${gitdir%%/.git/worktrees/*}"
  [[ -d "${repository}" ]] || continue
  git -C "${repository}" worktree repair "${worktree}" >/dev/null 2>&1 || true
  git -C "${worktree}" worktree repair >/dev/null 2>&1 || true
done < <(find "${root_new}/worktrees" -maxdepth 3 -name .git -type f 2>/dev/null)
printf 'repaired worktrees under %s/worktrees\n' "${root_new}"

step "Removing state that the old name owned"
rm -rf "${tmp_dir}/StationAI-DerivedData" "${tmp_dir}"/StationAI-DerivedData-* \
       "${tmp_dir}/StationAI-E2E-BuildCache" "${tmp_dir}"/StationAI-Live-Integration-* \
       "${tmp_dir}"/stationai-ui-tart-artifacts "${tmp_dir}"/stationai-ui.* \
       /tmp/stationai-bridge /tmp/stationai-bridge-workspaces /tmp/stationai-ui-test-fixtures \
       /tmp/stationai-ui-test-data /tmp/stationai-ui-tart-* /tmp/stationai-bridge.* 2>/dev/null || true
# Per-worktree app data was keyed by the old worktree paths, so every key is stale.
rm -rf "${support_new}/Worktrees"
# Drop Launch Services registrations for app bundles that no longer exist.
/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister \
  -kill -r -domain local -domain system -domain user >/dev/null 2>&1 || true

if (( with_vm )); then
  step "Removing the old Tart VM"
  export PATH="/opt/homebrew/bin:${PATH}"
  tart stop stationai-ui >/dev/null 2>&1 || true
  tart delete stationai-ui >/dev/null 2>&1 || true
  printf 'Deleted stationai-ui. Re-create it with scripts/setup-ui-tart-vm.sh (clones playhouse-ui, ~97 GB).\n'
fi

step "Done"
printf 'Data:      %s\nLogs:      %s\nWorktrees: %s/worktrees\nBackup:    %s\n' \
  "${support_new}" "${logs_new}" "${root_new}" "${support_new}/StationAI-v2.store.pre-playhouse-backup"
printf 'Next: ./scripts/run.sh from the renamed worktree, then check the board and `scripts/playhouse.sh status`.\n'
```
