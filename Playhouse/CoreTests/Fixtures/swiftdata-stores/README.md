# SwiftData task stores

Real task stores written by Playhouse builds from before the GRDB task store, which
`SwiftDataStoreMigration` moves into `Playhouse-v3.sqlite`. They're the input of
`PlayhouseCoreTests.SwiftDataStoreMigrationTests` and of the paired bridge/UI cases
`test_task_store_migrates_current_swiftdata_store` and
`test_task_store_migrates_legacy_swiftdata_store`.

- `current/Playhouse-v2.store`: written by the last SwiftData build (commit e1721195) through its
  own CLI, with the rest of each column filled in place: tasks in every column, a repository,
  a context folder, an unsent draft with an image, call usage, pending comments, a past pull
  request, one-time and paused recurring schedules, the standalone chat, a plugin editor and a
  parallel bubble. `expected.json` is what that build's CLI returned for `board list`,
  `task get` of every task, `schedule list` and `chat open`.
- `legacy-pending-prompt/Playhouse.store`: the pre-v2 store from before submitted prompts and
  drafts, as the old `scripts/seed-legacy-task-store.swift` wrote it.

Both are kept in SQLite's rollback-journal mode so each is one file. Nothing in the repository
writes SwiftData stores any more; regenerating one needs a build from before the GRDB store.
