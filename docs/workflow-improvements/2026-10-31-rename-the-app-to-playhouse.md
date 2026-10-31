
# Rename the app to Playhouse

Task: `rename-the-app-to-playhouse` (branch `rename-the-app-to-playhouse`)

Client date: 2026-10-31

## Observed timeline

Scope: the single repo-wide StationAI to Playhouse rename task. Times are UTC. Evidence checked:
the supplied task conversation and ledger, the five task-specific bridge logs under
`/tmp/playhouse-bridge.*` (lock `queued_at` timestamps and log mtimes), per-case
`E2E case=... elapsed_seconds=` lines in those logs, pre-rename logs under `/tmp/stationai-bridge.*`
used as a comparison baseline, `git diff --stat`, and `scripts/test-bridge.py`.

| Phase / operation | Time or duration | Evidence and limit |
| --- | --- | --- |
| Planning: parallel inventory + 4 scoping questions + plan approval | Duration unknown | Two read-only Explore agents ran concurrently; user decided no in-app migration code, VM re-clone, hard rename with no wire fallback, rewrite historical docs. No timestamps retained in the conversation record. |
| Implementation: `git mv` of 135 paths + scripted 4-way case-preserving substitution | Duration unknown | `git status --short` shows 277 entries; `git diff --stat` reports **252 files changed, 2375 insertions, 2365 deletions** — a near 1:1 line ratio consistent with a purely nominal change. |
| Re-derivation guard (re-apply substitutions to HEAD, byte-compare tree) | Duration unknown (estimated 1-3 min of tool time) | Described in the conversation; no command log retained. It isolated the only intentional deviations. |
| `xcodebuild` Debug build of the `Playhouse` scheme | Duration unknown; passed first attempt | No build log captured in the task evidence. |
| `check-test-parity.py`, `check-e2e-locking.py` | Duration unknown; both green | Static checks, no retained output. |
| First full `scripts/test-e2e.sh` | Lock acquired **16:58:07.766** (wait 0.000 s), finished **17:00:51**; **163.384 s** of case time, **~312 s** command total (≈5.2 min) | `/tmp/playhouse-bridge.6malF0/bridge-tests.log`: 93 ran, 1 failed (`test_task_done_preserves_worktree_and_branch`, 5.016 s fail-fast). The ~150 s before lock acquisition is build/setup; the runner does not break that down in the log. |
| Investigation round 1 (focused rerun) | Gap **17:00:51 → 17:03:56 = 3 m 05 s**; run **5.733 s**, still failing | `/tmp/playhouse-bridge.NOI97i`. Gap is agent reading env plumbing, not runtime wait. |
| Investigation round 2 (focused rerun with instrumented gh fixture) | Gap **17:04:01 → 17:08:05 = 4 m 04 s**; run **6.318 s**, still failing | `/tmp/playhouse-bridge.WtPr2j`. |
| Root-cause + fix in `scripts/test-bridge.py` | Gap **17:08:11 → 17:13:03 = 4 m 52 s** | Comparing against pre-rename artifacts under `/tmp/stationai-bridge.*` and writing the generated `gh` wrapper that bakes in state path and call log. |
| Focused confirmation run | Lock **17:13:03**, **20.686 s**, 1/1 OK | `/tmp/playhouse-bridge.TTd3G7`. Matches the pre-rename duration for the same case (18.700 / 20.437 / 21.761 / 23.471 s in `/tmp/stationai-bridge.W0MbHP`, `.BElxUS`, `.Rp4HOW`, `.x61LYq`). |
| Final full suite | Lock **17:13:41**, finished **17:16:36**; **175.255 s** case time, 93/93 OK, 0 skipped | `/tmp/playhouse-bridge.XMyzAP`. Build cache hit (lock 38 s after the previous run ended). |
| Static reviews (task / UI / architecture), run in parallel | ~5-6 min each, wall-clock overlapping (estimated; from the conversation, not logged) | task APPROVED, UI APPROVED, architecture CONCERN about the unrecorded host-migration checklist. **These ran after runtime verification, inverting the AGENTS.md phase order.** |
| Concern remediation | Duration unknown | `docs/playhouse-rename-migration.md` added. |
| Host actions | Duration unknown | Tart VM stopped, deleted, re-cloned as `playhouse-ui`. Data migration deferred to the user because the session's own working directory is under `~/.stationAI/worktrees`. |

Measured runtime-verification span: **16:58:07 → 17:16:36 = 18 m 29 s** from first lock to final
green, of which **371.4 s** is measured case time across five runs and **~12 min** is the three
inter-run investigation gaps. Adding the ~150 s pre-lock build of the first run gives roughly
**21 min** of runtime verification. Planning, implementation, the re-derivation guard, the
`xcodebuild` run, and the static reviews are **not** covered by any retained timestamp, so the
task's total wall-clock span and active agent time are unknown.

Slowest cases, final full run (seconds):

| Rank | Case | Final run | First run |
| --- | --- | --- | --- |
| 1 | `test_codex_questions_can_be_answered_over_cli_xpc` | 27.167 | 27.793 |
| 2 | `test_task_done_preserves_worktree_and_branch` | 20.342 | 5.016 (failed early) |
| 3 | `test_review_pr_conflicts_probe_and_verify` | 13.823 | 14.084 |
| 4 | `test_bridge_daemon_starts_on_demand_serves_watchers_and_exits_when_idle` | 8.721 | 8.612 |
| 5 | `test_conversation_composer_rejects_blank_and_supports_live_turn_controls` | 5.085 | 5.333 |

The top three account for **61.3 s of 175.3 s (35 %)** of final-run case time. A pre-rename
93-case full run (`/tmp/stationai-bridge.ckUIgN`, 180.515 s) brackets the post-rename 175.255 s,
so the rename produced no measurable suite slowdown.

## Findings and actions

1. **The one runtime failure was a pre-existing latent defect that only a new bundle identity
   could expose.** `test_task_done_preserves_worktree_and_branch` passed before the rename only
   because a daemon left over from an earlier suite run had inherited `STATIONAI_E2E_GH_*` from
   its original caller; the daemon itself keeps only `BridgeContract.sessionEnvironmentNames`
   across the socket, so those variables never crossed the boundary. The rename forced a fresh
   daemon and the case failed. Measured cost: **~12 min of investigation plus three extra runs
   (32.7 s of case time)**, and the first full run's 163 s was spent before the signal appeared.
   The fix (`scripts/test-bridge.py`, generating a `gh` wrapper that bakes
   `PLAYHOUSE_E2E_GH_STATE_PATH` / `PLAYHOUSE_E2E_GH_CALL_LOG` into the script on PATH) adopts the
   pattern `test_review_pr_conflicts_probe_and_verify` already used. Action: audit
   `scripts/test-bridge.py` for any remaining fixture that passes configuration to a subprocess
   via the caller's environment rather than a generated wrapper or an argument, and add a
   static check that every `PLAYHOUSE_E2E_*` name a fixture reads is either in
   `BridgeContract.sessionEnvironmentNames` or supplied by a wrapper. Verify by confirming the
   affected cases pass on a cold machine with no pre-existing daemon.

2. **The static reviews ran after runtime verification, which inverts the required phase order.**
   All three returned in ~5-6 min (estimated) and the architecture reviewer raised a CONCERN that
   produced a new file (`docs/playhouse-rename-migration.md`) — a change landing after the final
   green suite. It happened to be documentation-only, so the runtime evidence stayed valid; a
   source finding would have invalidated the 175 s final run and forced a repeat. Action: for
   bulk-rename tasks, start the three reviewers as soon as the substitution and build are green,
   in parallel with (not after) the first suite run is not permitted — instead run them before the
   first full suite, as AGENTS.md requires. Verify by checking the next rename-class task's ledger
   records static approvals with a fingerprint predating the first runtime run.

3. **The re-derivation guard was the highest-value step and should be reusable.** Re-applying the
   four-way substitution to HEAD and byte-comparing the working tree proved the 252-file change
   was purely nominal and surfaced exactly the intentional deviations — including the textually
   substituted Monaco bundle, which would otherwise have needed an `npm ci` rebuild of a pinned
   third-party artifact to trust. The script exists only in this session's transcript. Action:
   keep it as a committed helper under `scripts/` (for example
   `scripts/verify-nominal-substitution.py`, taking a from/to token pair and a base revision) so
   the next brand, namespace, or API-token rename gets the same proof without re-authoring it.
   Verify by running it against this task's commit and confirming it reports only the known
   deviations.

## Timing gaps

- **Measured:** bridge lock `queued_at` timestamps, per-case `elapsed_seconds`, suite totals, and
  log mtimes — all five runs of this task are fully covered post-lock.
- **Not emitted anywhere:** the runner logs the lock acquisition but not command start/end, so the
  ~150 s build/setup prefix of the first run is only derivable as a residual from the reported
  ~5.2 min command total. Adding a single `E2E phase=build elapsed_seconds=` line at the end of
  the build step in the e2e runner would close this; confirm first that
  `scripts/prepare-e2e-build.py` does not already print it.
- **Not retained:** no timestamps for planning, the `git mv` / substitution pass, the
  re-derivation guard, `xcodebuild`, or the parity/locking checks. The ~5-6 min per static review
  is an estimate from the conversation, not a recorded duration; reviewer start/end times are not
  written to the ledger.
- **Baseline nuance:** this task had no *task-owned* pre-change suite run, but prior-day artifacts
  under `/tmp/stationai-bridge.*` supplied a usable comparison for both the full suite and the
  failing case. Those artifacts are machine-local and unretained long-term; a rename-class task
  should capture a baseline full run under its own task directory before the first mass edit so
  the comparison does not depend on another task's leftovers.
