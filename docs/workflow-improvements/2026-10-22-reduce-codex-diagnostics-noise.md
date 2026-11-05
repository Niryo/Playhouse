# Reduce Codex diagnostics noise — workflow evidence

Task `88C5B1BB-6105-4992-AEC4-0BDE96ABE241` (Investigate Issue Using App Logs or Task). Client date: 2026-10-22.

## Timeline

Times below are UTC. Progress events are from the retained Playhouse Diagnostics JSONL files; command durations and case timings are from the task's final `scripts/test-e2e.sh` output and `/tmp/playhouse-bridge.8VRPzG/bridge-tests.log`. Progress timestamps mark phase announcements, not continuous agent work.

| Interval | Activity | Duration and basis |
| --- | --- | --- |
| 20:05:11–20:05:21 | Earlier investigation measured Codex notification volume and explained app-server notification events. | 10 s between progress records, derived; this precedes the source-change request. |
| 20:05:21–20:07:08 | No task-specific activity timestamp is available; includes possible user reading/reply time. | 107 s gap, derived; **not** counted as agent work. |
| 20:07:08–20:09:22 | Measured high-volume notification methods and planned aggregation. | 134 s between progress records, derived; active work versus tool wait is not separable. |
| 20:09:22–20:13:40 | Changed Codex notification aggregation and paired fixture, CLI, UI, and contract assertions. | 258 s between progress records, derived; individual edit durations unavailable. |
| 20:13:40–20:15:55 | Static reviews and repair. First review found incomplete repeated command-output/plan coverage and a thread/turn correlation concern; the implementation and assertions were repaired. Final task, UI, and architecture reviews approved fingerprint `fb22011dca003708b93c4c06e9b862c2bc453fb065b64df66de435c4da7541be`. | 135 s between progress records, derived; review and repair subintervals unavailable. |
| 20:15:55–approximately 20:18:50 | Full CLI/XPC verification: 56/56 named cases passed, none skipped. | 175 s measured by runner: build 80 s, fixture 1 s, cases 94 s; static phase/rounding accounts for remaining reported total. |
| Approximately 20:18:50–20:19:07 | Verification handoff and reporting progress record. | Approximately 17 s derived from rounded runtime; final task outcome timestamp is unavailable. |

The source-change window visible between the first measurement progress event and reporting progress event is **719 s (11 min 59 s)**. Its phase windows are 134 s preparation, 258 s implementation, 135 s review/repair, and 192 s verification/reporting. These phase windows include unknown tool wait and gaps, so they are **not active-agent-time totals**. The preceding investigation is partially visible; the actual user request timestamp and definitive completion signal are unavailable. The broader visible progress window from 20:05:11 to 20:19:07 is 836 s, including the explicit 107 s unclassified gap.

## Slowest measured operations

The 80 s build was 46% of the 175 s full verification run; the 94 s case phase was 54%. Per-case durations sum to 93.788 s, consistent with the 93.792 s suite report. The slowest cases were `test_task_done_preserves_worktree_and_branch` (23.575 s, 25.1% of case time), `test_task_pr_conflicts_detect_without_mutation` (5.692 s, 6.1%), and `test_conversation_composer_rejects_blank_and_supports_live_turn_controls` (5.499 s, 5.9%). The source task had one final full runtime run in the supplied verification ledger; no failed runtime rerun is recorded. Static review did require one repair cycle, but its separate review/repair times are not recorded.

## Improvements

1. **Measure whether aggregation restores useful log retention.** The investigation found a 10 MiB diagnostics cap and 11,239 `codex.notification` records in a moving rotated archive, including 7,234 `item/agentMessage/delta` records; the incident at about 19:10 UTC had already rotated out. The source change aggregates delta records and now has paired assertions, but this task has no post-change live retention measurement. After the changed app runs a comparable live Codex session, sample event counts and oldest retained timestamp for both diagnostics files before and after a fixed observation period. Verify that per-delta records fall and the retained time span grows while turn and item lifecycle events remain searchable.

2. **Make review of notification streams complete at the first pass.** Static review found omitted repeated command-output and plan coverage plus a thread/turn correlation concern inside a 135 s review/repair window. For future changes to the notification recorder, use the real fixture to exercise agent-message, plan, and command-output streams with multiple chunks and assert method, item, thread, and turn correlation in the existing paired cases. Verify the first static review addresses all three streams without a repair cycle. The records do not separate reviewer time from repair time, so this is a repeat count rather than a claimed time saving.

3. **Investigate the one dominant case before changing suite behavior.** `test_task_done_preserves_worktree_and_branch` consumed 23.575 s, one quarter of case runtime, despite being unrelated to this log change. Capture its internal Git/app-operation timings on a later run and identify whether a repeatable setup or wait causes the duration. A targeted improvement is justified only if that trace reveals avoidable repeated work; no such cause is established by this task.

## Telemetry limits

Checked this task's progress records in Diagnostics JSONL, the final runner's phase output, per-case bridge output, the verification summary, and the runner's timing instrumentation. The runner emits phase and case durations, but the available task evidence does not timestamp each edit, reviewer start/end, fixture operation, or agent tool wait. The progress records supply phase boundaries only. A future review/repair attribution would need timestamps from the task conversation or reviewer records; app diagnostics alone cannot distinguish that work. No new app logging is proposed for this gap.
