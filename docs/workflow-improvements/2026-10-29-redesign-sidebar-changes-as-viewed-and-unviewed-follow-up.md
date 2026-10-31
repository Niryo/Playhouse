# Workflow review: Viewed and Unviewed sidebar follow-up

Task: `F543169F-AC84-4A27-A7C7-6FF0FE87E1DF` — Redesign Sidebar Changes as Viewed and Unviewed. Follow-up to user feedback on 2026-10-29. This report covers the follow-up delta only.

## Observed timeline

| Order | Operation | Elapsed | Evidence and limit |
| --- | --- | ---: | --- |
| 1 | User reported Viewed should appear above Unviewed and that marking the only change made both sections disappear | Unavailable | Follow-up request; no reliable start timestamp |
| 2 | Scanner retained every saved snapshot path in Viewed, including unchanged files; sidebar order changed; paired CLI/UI assertions added for retained rows, empty viewed diff, and order | Unavailable | Task progress supplied by main agent; implementation start/end not measured |
| 3 | Static task review requested a clean initial inventory assertion; paired external Git case gained it; task and UI reviews approved fingerprint `8bfd5693e1a21f1edffb94d1ef1f6be84bbcd8714d2c52ee0f8c073285d8a569`; architecture approval was retained because production inputs were unchanged | Unavailable | Review ledger supplied by main agent; review and repair waits unmeasured |
| 4 | Final full `scripts/test-e2e.sh`: 92/92 passed, zero skipped | **383s script wall time; 227.145s case suite** | Measured runner total and `bridge-tests.log`; 155.855s remains in setup, build, fixture, lock wait, or teardown without a retained phase split |
| 5 | Worktree launcher rejected inherited `STATIONAI_DATA_DIRECTORY`; `env -u STATIONAI_DATA_DIRECTORY ./scripts/run.sh` succeeded; isolated app PID 72960 was confirmed | Unknown total; 30s + 30s + 16s observed polling waits | Task progress supplied by main agent; polling waits are not launch or build duration and may include gaps |

The follow-up's **known verification script time is 6m 23s**. Case execution occupied 59.3% of that run; the other 40.7% is not attributable more precisely from the retained evidence. The task's total wall time and active agent time are unknown because feedback, implementation, review, launcher, and handoff timestamps are incomplete. Routine verification did not run the UI suite; its paired UI coverage received static approval.

In the final suite, the slowest cases were `test_task_done_preserves_worktree_and_branch` (30.169s), `test_codex_questions_can_be_answered_over_cli_xpc` (28.342s), and `test_review_pr_conflicts_probe_and_verify` (16.241s), totaling 74.752s or 32.9% of case time. The changed sidebar cases took 2.669s and 1.440s. No case was rerun after the passing full suite.

## Improvement

**Retain the runner's existing phase lines with each task verification result.** The follow-up records a 383s full run but cannot assign 155.855s outside the case suite to build, fixture preparation, lock wait, or other overhead. `scripts/test-e2e.sh` already emits `E2E phase=` and `E2E total_seconds=` lines; the task's supplied record retained only the total and suite duration. Store those lines and the artifact path under the task ID in the verification ledger. Verify the improvement on a later run by reconciling static, build, fixture, and cases phases with the script total, then rank actual setup costs before changing the runner. No new runner instrumentation is justified by this record.

The launcher rejection followed the documented isolation guard in `scripts/run.sh`; `.agents/skills/launch-worktree-app/SKILL.md` already prescribes clearing only the inherited override and confirming the worktree-specific process. The successful retry followed that procedure. The observed polling intervals do not establish a separate actionable launcher bottleneck.

## Evidence gaps

Checked the follow-up conversation and supplied progress/review ledger, the attributed 92-case `bridge-tests.log`, `scripts/test-e2e.sh`, `scripts/run.sh`, and the launcher skill. The task evidence does not include reliable start/end timestamps for implementation, static reviews, launcher build/open, or user waiting. Timestamped task progress and review start/end records would be needed to separate wall time from active work. Same-worktree logs without a follow-up task identifier were not attributed to this follow-up.
