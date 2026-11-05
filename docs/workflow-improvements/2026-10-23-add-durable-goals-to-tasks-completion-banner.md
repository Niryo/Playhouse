# Add Durable Goals to Tasks: completion banner follow-up

Task `16B9117F-8308-4B7A-B1C8-ECE45ED805F6` · Client date 2026-10-23 (Asia/Jerusalem)

## Timeline and timing

| Sequence | Operation | Duration | Evidence |
| --- | --- | ---: | --- |
| 1 | Completion-banner implementation and paired case changes, context review, static task/UI approvals; prior architecture approval retained | Unknown | Task conversation and final reviewed fingerprint `a8ed6242ec65877887f8ad8e97eb38d265f06ce68fc2d4e2a92c206cca465219`; no start/end times supplied. |
| 2 | Full CLI/XPC suite, 57/57 passed without skips | **176 s runner**, **94.506 s cases** | Task verification output and `/tmp/playhouse-bridge.6Khs7W/bridge-tests.log`; about **81.5 s** outside cases. |
| 3 | Focused Tart Goal UI case, 1/1 passed | **173 s** from run marker to result artifact; **22.975 s** XCTest case | `20261023T084452Z-11804` Tart run ID and `exit-status.txt` mtime (derived, excludes later cleanup); `ui-test.log` case duration. At least **150 s** was outside the case. |
| 4 | Live Codex completion branch | Not run | Tart guest lacked `~/.codex/auth.json`; no live-completion pass is supported. |
| 5 | App rebuild/launch and process check from this worktree; handoff | Unknown | Task progress handoff; no command timing or completion timestamp supplied. |

The two measured verification invocations account for **at least 349 s (5 min 49 s)** of wall time, including **117.481 s** of case execution. This is a lower bound for the follow-up, not its full task duration or active agent time. Implementation, reviewer work and waits, the launch, and gaps between operations are unmeasured. The CLI case phase's slowest operation was `test_task_done_preserves_worktree_and_branch` at **23.353 s**, **24.7%** of that case phase; the Goal lifecycle case took **2.915 s**. The focused UI Goal case took **22.975 s**. The current evidence does not divide the runner overhead into build, VM, lock, or artifact stages.

## Actionable finding

**Make the guest authentication prerequisite visible before attempting opt-in live Goal verification.** The completion branch remains unverified because the Tart guest had no Codex login; time spent on this blocked attempt is unavailable. Before the next `--live-codex` run, check `codex login status` inside the guest and authenticate there if needed, then rerun the real completion branch. Verify the guest reports authenticated status and the live case reaches and asserts the completed Goal state. Do not count the passing default UI case as evidence for this branch.

## Evidence limits

Checked the task handoff and static-review result, task-specific CLI case log, focused Tart `ui-test.log` and result artifact, and runner timing code. `scripts/test-e2e.sh` emits phase totals to stderr, but those phase lines were not retained with the bridge case log used here; the Tart runner does not emit phase totals. Full follow-up start/end times, edit/review/communication durations, and live-auth-blocked attempt duration are unavailable. A timestamped task/tool timeline and retained runner stderr would be needed to reconcile the follow-up's total elapsed time. No speed recommendation is supported by the unallocated overhead alone.
