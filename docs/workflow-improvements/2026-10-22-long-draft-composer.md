# Long draft composer stall and missing scrollbar

Task: fix the stalled “Inspect Subagent Conversations and Results” composer and investigate the earlier scrollbar task (CCAAFDAD-4AC1-4704-B827-5D2F0BD8D632).

## Observed timeline

| Phase | Time (22 Oct 2026, Israel) | Duration and evidence |
| --- | --- | --- |
| Earlier diagnosis | Samples saved at 10:14:48 and 10:17:05 | 2m17s between captures, derived from file times. The fix request and intervening user wait are not timestamped. |
| Implementation and static review | Ledger opened 10:25:16; final static approval 10:28:16 | 3m00s observed wall time. Includes one UI review repair round; individual exploration, edit, and review durations were not recorded. |
| Transition to runtime | 10:28:16–10:29:01 | 45s wall time; activity within this interval is unrecorded. |
| CLI/XPC verification | Started 10:29:01; log ended 10:31:47 | 166s measured: 92s build (55%), 2s fixture (1%), 72s cases (43%). First full run passed all 54 cases with no skips or retries. |
| Completion and reporting | Log ended 10:31:47; ledger completed 10:32:13 | 26s derived wall time; individual actions unrecorded. |

The ledger covers 6m57s from 10:25:16 to 10:32:13. Its phase intervals reconcile to that span within rounding. The earlier diagnostic samples predate it; the user wait, discovery of the original task, and implementation before the ledger have no reliable start/end pair, so total task duration and active agent time cannot be calculated. The current task conversation, sample file times, verification ledger, runner log, and `scripts/test-e2e.sh` timing output were checked. No UI runtime or screenshots were part of routine verification.

The slowest cases were `test_conversation_composer_rejects_blank_and_supports_live_turn_controls` (4.479s), `test_task_repository_removal_preserves_state_on_dirty_worktree` (4.168s), and `test_task_pr_conflicts_detect_without_mutation` (3.645s). The composer case consumed 6.2% of case time; the build was the dominant measured operation.

## Practical improvements

1. **Measure the reported UI stall directly in the permitted Tart workflow.** The 54 passing CLI/XPC cases establish persistence and bridge behavior but do not measure whether opening the 5.7 KB draft accepts a click promptly. The time from task open to a responsive click, and scroll response, is missing because routine verification did not run UI tests. Add an opt-in Tart performance run around the existing composer UI case and record those two latencies for a long wrapped draft before and after future layout changes. Verify the improvement by comparing the same fixture and VM setup across runs; retain normal static UI coverage review for routine tasks.
2. **Keep scrollbar assertions local to the composer.** The original “scrollbar” task only changed the line limit from 5 to 12, and a global scrollbar assertion did not establish that the long draft itself could scroll. This task repaired the paired UI coverage to compare the composer’s document and viewport heights and scroll in both directions, plus a static guard. Run that focused case during the next on-demand Tart UI verification and confirm it fails if the composer loses its own scroll region. No additional generic scrollbar check is needed.
3. **Separate build cost from test cost when evaluating suite speed.** The cache miss build took 92 of 166 seconds (55%), while all 54 cases took 72 seconds. The existing runner already emits phase and per-case durations, so new logging is unnecessary. Compare a content-matched cache-hit run with this miss before proposing build changes; a reduction in build phase time, without changing required coverage, is the measurable target.

The ledger does not time repository exploration, task-history lookup, edit cycles, individual static reviews, or the 45-second handoff. Existing task records inspected here do not expose those boundaries; a future task ledger would need timestamps at those events to attribute their costs. This is a visibility gap, not evidence that those steps were slow.
