# Background agent results in conversation: workflow review

Task `8212363E-7AAC-4EBE-B9EA-39FF77E9B37D` · Client date: 2026-10-28

## Observed timeline

This is a partial timeline. The task-card creation time, first implementation timestamp, static-review call timestamps, and final outcome timestamp are unavailable in the supplied task evidence. The earlier stale Claude session described in the handoff is context for this fix, not active work on this implementation.

| Phase | Time or duration | Basis |
| --- | --- | --- |
| Context, repository exploration, implementation, and paired CLI/UI test edits | Duration unknown | Current conversation handoff and seven-file unstaged diff; no phase start/end times supplied. |
| Static review and repair | Duration unknown; multiple cycles | Verification ledger records six repaired findings: explicit summary versus progress detail, transcript ordering/deduplication, UI synchronization, parent-result ordering, empty background-task snapshot, and visible parent response. Final task, UI, and architecture reviewers approved fingerprint `60c35a426cf0d055a08c45303daf8d561485c994ccaa29695f6d00e0b36f8386`. Review timestamps are absent from the supplied ledger. |
| Static/parity checks | Duration unknown | `scripts/check-test-parity.py` passed 91 paired cases; `git diff --check` passed. The full E2E script also ran parity, button feedback, and lock checks during its approximately 1-second static phase. |
| One full `scripts/test-e2e.sh` run | 332 seconds measured by runner; approximately 11:03:33–11:09:05 local, derived from log modification time | Runner phase totals in the ledger and `/tmp/playhouse-bridge.nXsDtB/bridge-tests.log`; log modification time is only an approximate end marker. Build 144 seconds (43.4% of run), fixture 2 seconds (0.6%), CLI/XPC cases 184.890 seconds (55.7%); rounding and static checks account for roughly 1 second. Build cache missed. No failed or repeated runtime run is recorded. |
| Handoff/reporting | Duration unknown | Final runtime evidence and unchanged fingerprint recorded in verification ledger; no final outcome timestamp supplied. |

The only timed wall-clock segment is the 332-second runtime run. Total task elapsed and active agent time cannot be reconciled because implementation/review start and end signals are unavailable here. The runtime phase is tool/build wait and test execution, not 332 seconds of active agent work.

The three slowest named CLI cases were `test_task_done_preserves_worktree_and_branch` (23.487 seconds), `test_codex_questions_can_be_answered_over_cli_xpc` (20.856 seconds), and `test_review_pr_conflicts_probe_and_verify` (14.617 seconds). Together they took 58.960 seconds, 31.9% of case time. The changed case, `test_claude_background_agent_keeps_turn_open_until_resolved`, took 1.124 seconds. All 91 cases passed with no skips. These slower cases cover other required contracts, so this task provides no evidence that their cost was avoidable.

## Improvements

1. **Make event-order scenarios explicit before static review.** Six repair findings concerned lifecycle states or ordering in the same Claude background-agent flow, including a status-only update and an empty task snapshot before the final summary. The review/rework cost is unmeasured, but the repeated corrections are recorded in the ledger. For the next provider-event change, write a short protocol sequence table alongside the paired test design covering start, progress, status-only completion, snapshot removal, final notification, parent response, failure, and reload. Check that each sequence maps to an assertion before requesting static review. Measure impact by counting findings and revision cycles on comparable event-flow tasks; retain the required reviews and tests.

2. **Timestamp the existing verification ledger at phase boundaries.** The ledger records findings and a measured 332-second runtime run, but not implementation or review start/end times, so their wall-clock share and any idle gap cannot be computed. Record local timestamps when implementation is ready, each static review starts/returns, each repair ends, runtime starts/ends, and outcome is reported. A later workflow review should be able to reconcile task elapsed time and separate review wait from repair work without inferring it from the task card. This uses the existing ledger; no new product telemetry is justified by this evidence.

Evidence checked: current task conversation/handoff and progress summary, task verification ledger, the matching 91-case bridge log with per-case durations, and `scripts/test-e2e.sh` phase instrumentation. Exact coding/review timing is unavailable in the supplied records; this does not establish that Playhouse lacks other retained timing sources.
