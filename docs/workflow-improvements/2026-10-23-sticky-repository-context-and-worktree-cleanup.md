# Sticky repository context and worktree cleanup

Task: `519C2B59-ECEB-4FC6-B5CD-1D1FAAF992FD` — sticky repository selection, mismatch assessment, and durable task-worktree cleanup.

## Observed timeline

This is a partial timeline. The conversation establishes the task scope, implementation, static reviews, and repair cycles, but does not expose a timestamped task start or active-work intervals. Times below are command wall times supplied in the verification ledger unless identified as case runtime from retained `bridge-tests.log` artifacts. Build, fixture, and static-check times are included in command wall times but are not separately measured for those attempts.

| Sequence | Evidence | Measured time and result |
| --- | --- | --- |
| Earlier implementation and review | Conversation summary: source changes, paired cases, repeated task/UI/architecture reviews | Start/end and active-work duration unknown. Static parity eventually passed for 59 named cases; architecture retained a documented concern. |
| Earlier failed full and focused suites | `/tmp/playhouse-bridge.xI02KN`, `.CoJoNx`, `.qleMRW/bridge-tests.log` | Case execution: 59 cases in 104.874s (six failures), six in 68.792s, seven in 205.584s. These exclude unretained setup/build time. The seven-case run included a 90s CLI retry timeout. |
| Four-case focused repair run | Supplied verification ledger; `/tmp/playhouse-bridge.nfLyBK/bridge-tests.log` | About 134s wall; 38.032s cases. Repository removal failed after 31.489s; the other three cases passed, including migration. About 96s was outside case execution, but its split between build and setup is unknown. |
| Build after source repair | Supplied verification ledger | 13s wall; compilation failed before any case because a `WorkspaceManager` service property was missing. |
| Focused cleanup retry | Supplied verification ledger; `/tmp/playhouse-bridge.X46EDN/bridge-tests.log` | About 131s wall; cleanup failed after 33.390s because the dirty-path diagnostic did not appear. About 98s was outside case execution, with build/setup split unknown. |
| Focused retry after adding a fresh request | Supplied verification ledger; `/tmp/playhouse-bridge.bPqLTE/bridge-tests.log` | About 7s wall using the cached build; cleanup case passed in 3.558s. |
| Final full CLI/XPC run | Supplied verification ledger; `/tmp/playhouse-bridge.Mqs0hi/bridge-tests.log` | About 119s wall; all 59 cases passed with no skips in 115.989s of case execution. Slowest: `test_task_done_preserves_worktree_and_branch` 24.405s and `test_review_pr_conflicts_probe_and_verify` 14.040s, together 33.1% of case time. |

The last five command attempts total about **404s** of observed wall time (estimated from rounded ledger values). Earlier retained logs add **379.250s of case runtime** across three nonoverlapping attempts; their build/setup time is unknown. The full task wall time and active agent time cannot be reconciled because implementation, review, gaps between commands, and earlier command boundaries lack complete timestamps. Lock acquisition in the final log reports `wait_seconds=0.000`, so that run has no measured bridge-lock queue cost.

## Improvements

1. **Make deferred cleanup verification event-driven.** Two focused removal attempts spent 31.489s and 33.390s waiting for a cleanup result that did not occur or did not emit the expected dirty-path event. The final focused run passed in 3.558s after a fresh request triggered reconciliation. In the paired cleanup case, release the turn reservation, issue the next bridge request, then assert the persisted cleanup intent and terminal diagnostic. Keep the timeout for a real stalled reconciliation. Verify that this case remains green and its runtime approaches the final 3.558s rather than a 30s poll.
2. **Retain the runner's phase timings with each artifact.** `scripts/test-e2e.sh` already prints `E2E phase=... elapsed_seconds=...` and total wall time to stderr, while the retained `bridge-tests.log` contains only per-case times. Thus about 96s and 98s of two focused commands cannot be split between build, fixture setup, and static checks from the saved artifacts. Have the runner save its existing phase lines beside `bridge-tests.log`, without adding new timers. Verify that each run artifact reconciles phase durations and total wall time with the case log.
3. **Give retry fixtures an explicit terminating mode.** The earlier seven-case run spent 90s waiting for `conversation queue-retry` while the selected fixture requested user input that the CLI case could not provide. The repair switched to a fixture mode that completes without an unanswered question. Encode the fixture mode's expected terminal state in the case setup and fail quickly if it enters the wrong state. Verify that a wrong mode fails before the 90s CLI timeout and the intended retry case still passes.

## Remaining product risk

The architecture review recorded that the mismatch confirmation is view-local state. Navigating away before responding loses the prompt. A follow-up product change can persist the pending confirmation per task and cover reopening it with the paired CLI/UI cases.
