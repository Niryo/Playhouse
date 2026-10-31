# Activity timing and current activity: workflow review

Date: 2026-10-23 (Asia/Jerusalem). Task ID: none supplied. Scope: per-call activity timing and persistence, current activity selection, Working for durations, and progress-report instructions.

## Timeline and measured cost

| Phase | Time or duration | Evidence and precision |
| --- | --- | --- |
| Planning, source inspection, implementation, and paired CLI/UI assertions | Start and duration unknown | Task conversation and change summary show these steps but expose no reliable wall-clock or active-work timestamps. |
| Static checks and review | Duration unknown | Parity passed for 58 paired cases; Python compilation, Swift parse, and diff checks passed. Task, UI, and architecture reviews approved after repairs to disclosure coverage and duration precision. Review start/end timestamps were unavailable. |
| First full CLI/XPC run | 188 s: build 86 s, fixture 2 s, cases 99 s | `scripts/test-e2e.sh` phase totals and `/tmp/playhouse-bridge.ifTPPU/bridge-tests.log`; 58 cases, one failure. Log modified at 00:10:26; inferred run start is about 00:07:18. |
| Repair and review of stale prompt assertion | Duration unknown | Failure showed the test expected `active test and position` while the prompt now says `active suite/case and position`. The task repaired paired assertions and refreshed affected reviews. |
| Focused failed-case retry | 92 s: build 87 s, fixture 2 s, case 2.155 s | Runner phase totals and `/tmp/playhouse-bridge.qHJWa2/bridge-tests.log`; passed. Log modified at 00:13:02; inferred start about 00:11:30. |
| Final full CLI/XPC confirmation | 87 s: fixture 2 s, cases 84 s; cached build reused | Runner phase totals and `/tmp/playhouse-bridge.fpLrXx/bridge-tests.log`; 58/58 passed, none skipped. Log modified at 00:14:33; inferred start about 00:13:06. |
| Final fingerprint check and reporting | Duration unknown | Verification ledger says the feature diff fingerprint was unchanged after the final suite. No timing record was supplied. |

The three measured runs total **367 s**: 173 s building, 6 s preparing fixtures, about 185 s executing cases, and about 3 s in static/runner overhead (integer phase timing). Their approximate wall-clock window is 00:07:18–00:14:33, or 435 s. The roughly 68 s outside the runs includes repair/review/coordination gaps, but the available evidence cannot split that interval into active work and waiting. The complete task elapsed time and active agent time remain unknown because the first implementation and review timestamps are absent. File modification times only approximate run endpoints; they are not start/end telemetry.

The longest case was `test_task_done_preserves_worktree_and_branch`: 25.571 s initially and 21.470 s finally, about one quarter of case execution in either full run. Next in the final run was `test_conversation_composer_rejects_blank_and_supports_live_turn_controls` at 5.949 s. The feature activity case took 0.631 s and the progress-instruction case 1.532 s in the final run. The failing assertion took 1.771 s during the first run; its focused retry took 2.155 s. Case durations come from the bridge log's per-case `elapsed_seconds` lines.

## Improvements supported by this task

1. **Check prompt assertions against the actual generated instruction text during static review.** The stale phrase survived parity and review, then failed the first full run. The required focused retry cost 92 s, including an 87 s build after paired UI test input changed. Add a reviewer check for exact instruction substrings in both paired assertions whenever prompt text changes. Verify impact by tracking prompt-assertion failures and focused-retry time in subsequent tasks; the target is zero stale-string failures. This does not change the required full suite or retry gate.
2. **Profile the dominant lifecycle case before changing it.** `test_task_done_preserves_worktree_and_branch` consumed 21–26 s in each full run, roughly 25% of case time. Its source includes a fixture turn, Git operations, a lock wait, and CLI calls; the per-case log does not identify which step dominates. Time those steps in one targeted diagnostic run, then optimize only the measured bottleneck while retaining the case's assertions. Compare its per-case duration in later full runs.
3. **Keep a task-level timestamp ledger for implementation and reviews.** The runner already emits phase and per-case durations, and this report inspected those logs, the task conversation/verification summary, and `scripts/test-e2e.sh` plus `scripts/test-bridge.py`. What remains unavailable is when implementation and static reviews started/ended, and whether the approximately 68 s between runtime calls was work or wait. Record task event timestamps and review dispatch/completion in the existing verification ledger; confirm future reports can reconcile total task wall time with active work and tool wait before adding product or runner logging.

The content-matched build cache in `scripts/prepare-e2e-build.py` includes the Swift UI test source, so the paired assertion edit correctly caused the focused retry's cache miss. The final run reused that build. No recommendation here removes mandatory review, paired UI coverage, or full CLI/XPC confirmation.
