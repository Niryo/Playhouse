# Speed Up Archived Tasks with Infinite Scrolling

Task: `D94D5E06-04C7-4FDA-9F61-339BE164471B`  
Date: 2026-10-22 (Asia/Jerusalem)

## Timeline and measured cost

| Phase | Time or duration | Basis |
| --- | --- | --- |
| Task began; investigation found eager conversation-history indexing and a board query including Done tasks | 12:43:54 UTC start; investigation end unknown | Task-card timestamp and supplied task ledger |
| Implementation, paired CLI/UI assertions, parity check | Duration unknown; parity passed 56 cases | Supplied ledger; no operation timestamps available here |
| Static review and repair | Duration unknown; first task/UI reviews rejected, architecture raised concerns; CLI pagination assertion, UI specificity, search lifecycle, and fixture count were repaired; all applicable reviews then approved | Supplied ledger; review start/end times unavailable here |
| First full CLI/XPC run | 137 s measured: build 71 s, cases 63 s, other phases about 3 s | Supplied runner output; 56 cases ran, one failed |
| Fixture repair and affected static review | Duration unknown | Supplied ledger; filler tasks could not move directly from Backlog to Done |
| Focused CLI/XPC retry | 102 s measured: build 83 s, named case 16.236 s, other phases about 2.8 s | Supplied runner output; 1/1 passed |
| Final full CLI/XPC run | 85 s measured: cases 82 s, other phases about 3 s; cached build reused | Supplied runner output; 56/56 passed, none skipped |
| Task completion/report handoff | Approximately 13:02 UTC; exact completion instant unavailable | Supplied end estimate and optimizer clock at 13:02:40 UTC |

Observed start-to-report window is about **18 min 46 s** (12:43:54–13:02:40 UTC; approximate because the final verification completion instant is not recorded). The three measured runtime invocations total **324 s (5 min 24 s)**, about 29% of that window. Their reported builds total **154 s** and case phases about **161 s**; the remaining roughly **9 s** is runner setup/fixture overhead, subject to whole-second phase rounding. About **13 min 22 s** of the window cannot be apportioned among investigation, implementation, static reviews, repair, tool waits, and inactive gaps from the evidence available to this optimizer. It is not an active-work estimate.

The slowest reported operations were the focused retry build (83 s), final full case phase (82 s), initial build (71 s), and initial full case phase (63 s). The focused named case took 16.236 s. Individual durations for the other 55 cases were not available in the supplied ledger, so no case ranking or shares are supported. The runner emits per-case timing, but no retained `bridge-tests.log` for these invocations was found in the accessible `/tmp` search.

## Improvements

1. **Reuse a valid Done-task fixture path.** The first full run failed only `test_task_done_preserves_worktree_and_branch`: archive filler tasks were created in Backlog and moved directly to Done, which the product rejects. The failure required a 137 s full run, fixture repair, a 102 s focused retry, and the required 85 s final run. Add one shared bridge-test helper that completes archive filler tasks through the real Codex fixture and Review-to-Done transition, then use it wherever large Done populations are needed. Verify future archive tests reach the intended pagination assertions on their first runtime run; compare failed fixture-setup attempts and rerun minutes.

2. **Record the build cache decision and slowest cases in the task ledger.** Two measured build phases consumed 154 s across the first and focused runs; the final run reused its cache. `scripts/prepare-e2e-build.py` already prints cache hit/miss and lock wait, and `scripts/test-bridge.py` emits per-case durations, but those lines and artifact paths were absent from the supplied ledger and the logs were inaccessible here. Preserve the existing runner summary, build cache decision/lock wait, artifact path, and top five case-duration lines with each runtime invocation. On the next source task, verify the ledger explains every build over 30 s and identifies its slowest cases without rerunning anything.

3. **Timestamp the review and repair transitions.** The initial static review found four concrete gaps and required another review cycle, but its cost cannot be separated from implementation, tool waits, or inactive time: about 13 min 22 s of the observed window is unattributed. Record start/end UTC timestamps when implementation becomes review-ready, each reviewer returns, a repair begins/ends, and runtime starts. Use existing conversation/tool timestamps if the producing task ledger can access them; add event logging only if that source proves unavailable. Verify the next report can reconcile the task window while keeping wait and active work separate.

## Evidence limits

Checked the supplied task card timestamp, verification ledger, available task conversation, current unstaged diff, `scripts/test-e2e.sh`, `scripts/test-bridge.py`, `scripts/prepare-e2e-build.py`, and accessible `/tmp` bridge-artifact paths. The full parent tool timeline and per-case runtime output were not available to this optimizer. The build warning text about exit code 0 did not stop the suite; its cause and cost are unmeasured, so no change is recommended from that line alone. No UI runtime suite ran in routine verification; the paired UI coverage received static approval.
