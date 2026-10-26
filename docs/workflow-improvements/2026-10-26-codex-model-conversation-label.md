# Codex model versus conversation label mismatch

Task: `1FD66D25-C4F0-4BA7-8435-AA51B42F94E9` · 2026-10-26 (Asia/Jerusalem)

## Timeline and evidence

This is a partial timeline. The handoff conversation records discovery, implementation, an initial UI test compile repair, static reviews, and later design and test repairs, but does not timestamp those phases. The first task-specific timed artifact available here is a CLI/XPC log ending about 19:28:47 UTC; the final suite log ends about 20:11:20 UTC. These log file modification times are approximate end signals, not command start timestamps. The full task began earlier and the report creation followed the final suite.

| Phase | Time or duration | Basis |
| --- | ---: | --- |
| Initial trace, implementation, paired CLI/UI coverage, and first build compile repair | Unknown | Conversation handoff; no retained phase timestamps supplied |
| First full CLI/XPC suite: 72 cases, one error and one failure | 188.379 s of cases; end about 19:28:47 UTC | `/tmp/stationai-bridge.3dPkwg/bridge-tests.log`; log mtime for end |
| Focused async-question retry: one error | 2.036 s of cases; end about 19:38:29 UTC | `/tmp/stationai-bridge.pBJDvX/bridge-tests.log`; log mtime for end |
| Repair of active history and fixture behavior, static review cycles | Unknown | Conversation and verification handoff; no phase timestamps supplied |
| Next full CLI/XPC run: 72 cases, one model-label fixture error | 331 s command: 156 s build, 172.185 s cases, about 3 s other work; end about 20:02:51 UTC | Task verification ledger and `/tmp/stationai-bridge.I5c0Ck/bridge-tests.log` |
| Fixture repair and renewed static approvals | Unknown | Verification ledger; final task/UI/architecture approvals on fingerprint `f445c948372d38fb0a4138c726b2037f7d1cae28d0be7f9d6fbe4e7046524e9` |
| Focused model-label retry: one pass | 153 s command: 147 s build, 2.995 s case, about 3 s other work; end about 20:08:04 UTC | Verification ledger and `/tmp/stationai-bridge.5WXMPy/bridge-tests.log` |
| Final full CLI/XPC run: 72/72 pass | 190 s command: cached build, 185.519 s cases, about 4 s other work; end about 20:11:20 UTC | Verification ledger and `/tmp/stationai-bridge.i3fpML/bridge-tests.log` |

The last three commands total **674 s (11 min 14 s)** of observed wall time: 303 s building (45%), 360 s running cases (54%), and about 11 s in command overhead (rounded). The earlier full run and focused retry add **190.415 s of measured case time**, with command setup/build time unavailable. Thus at least **864 s (14 min 24 s)** of task runtime is accounted for. The interval from the approximate first suite end to final suite end is **42 min 34 s**; its gaps include repair, review, build/setup, and idle time that cannot be reliably apportioned. Planning and implementation before that interval make the complete task duration unknown. UI tests and screenshots were omitted at the user's request; UI coverage was statically approved.

In the final run, the two slowest cases were `test_task_done_preserves_worktree_and_branch` (27.922 s) and `test_review_pr_conflicts_probe_and_verify` (23.545 s). Together they used 51.467 s, **27.7%** of case time. The next three were composer live controls (7.438 s), conversation steering (7.289 s), and interrupted Codex retry (5.833 s). These are named case durations from the final log; there is no evidence here that their work is avoidable.

## Improvements

1. **Catch inconsistent fixture turn IDs before a full suite completes.** The model-label case failed after a 331 s run because the Codex fixture attached prior history to the current random turn ID. The focused case itself took 2.080 s in that run. Add a narrow fixture protocol check for two successive turns: each persisted history item must retain its originating turn ID, and the IDs must differ. Run this check in the existing fast fixture/parity preflight. Verify that intentionally reusing a turn ID fails the preflight and that the full CLI/XPC case remains green. This should move diagnosis from the end of a 72-case run to a check measured in seconds; the exact preflight cost must be measured after implementation.

2. **Make build invalidation visible at the call site.** The failed full run spent 156 of 331 s building (47%); the focused retry after fixture repair spent 147 of 153 s building (96%). The final run reused the build. Inspect the existing per-worktree build cache decision in `scripts/test-e2e.sh` and its invoked build helper, then emit the cache-key inputs and hit/miss reason in the command phase output if they are not already recorded there. Verify by editing only a fixture, then comparing the reported cache reason and build duration on the next focused run. The evidence shows repeated build cost, but does not establish that either rebuild was unnecessary.

3. **Preserve task-phase timestamps in the verification ledger.** The conversation gives the sequence of implementation, review rejections, repairs, and approvals, while the supplied ledger has only test durations. Record phase start/end and reviewer response times in the existing task progress or verification ledger, and distinguish active work from tool wait. Verify that a future task report can reconcile phase totals to task elapsed time without assigning the current 42-minute observed interval's gaps by inference. Existing bridge case logs and diagnostics were checked for this task; they time individual tests and requests, not implementation or review phases.

Evidence checked: current task conversation and handoff, supplied verification ledger, task-specific `bridge-tests.log` files above and their per-case `E2E case=... elapsed_seconds` lines, `scripts/test-e2e.sh` phase output declarations, repository status, and the existing workflow-report filename list. No other task conversations or earlier reports were used.
