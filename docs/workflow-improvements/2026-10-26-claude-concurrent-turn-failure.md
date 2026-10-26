# Workflow review: Claude concurrent-turn failure

Task: `F3F5C51B-8C99-4421-9E39-FD85900DD819` (Investigate Reported Issue). Client date: 2026-10-26.

## Observed timeline

The available timeline is partial. The first retained test artifact starts at 18:57:43 local time; investigation and implementation began earlier, but their start time and active duration are not in the retained task evidence. The last test log ended at 21:31:25 local time. That is **2h 33m 42s of observed wall-clock span**, including implementation, review, runtime waits, and an unclassified 19:36–21:20 interval that includes the interruption. It is not an estimate of active agent time. Directory creation and log modification times are filesystem timestamps; command totals below come from task tool output, while per-case durations come from `bridge-tests.log`.

| Phase / evidence | Observed time or duration | Result |
| --- | ---: | --- |
| Initial investigation, client/bridge tracing, first implementation, static reviews | Before 18:57; elapsed unavailable | Found per-client and then per-process serialization did not cover separate XPC service processes. Diagnostics identified distinct Bridge PIDs. |
| Initial full CLI/XPC run (`/tmp/stationai-bridge.YtUAVp`) | 74 cases in 205.876s; command ~373s from task output | Two new concurrency cases failed. |
| First focused retry (`2lfZwA`) | 2 cases in 13.477s; command ~174s | Same two cases failed; Bridge process boundary became clear. |
| Cross-process lock and paired CLI/UI case implementation; static review/repair | Duration unavailable | File lock added; auxiliary client and UI/CLI process coverage were revised. A build attempt exposed Swift test compilation errors; its elapsed time is unavailable. |
| Three focused diagnostic-wait retries (`Gzvp5i`, `ysVQjj`, `LcpUMl`) | Failed case: 12.122s, 22.202s, 47.135s; command totals approximately 134s, 192s, 203–225s from task output | Test waited for `claude.turn.queued` before releasing the first turn, while that event was emitted after acquiring the lock. Increasing the wait could not satisfy the condition. |
| Focused failure-release retry (`N8aXtp`) | 2.526s case; command ~152s | Passed after test coordination was corrected. |
| Full CLI/XPC run (`RweRnV`) | 74 cases in 172.548s; command ~176s | One concurrency case still failed because the first turn was released before the second process attempted the lock. |
| Two affected focused cases (`tIKNos`) | 5.807s cases; command ~173s | Both passed after the second-process attempt was coordinated. |
| Final full CLI/XPC run (`fOdnAI`) | 74 cases in 185.977s; command ~195s, including about 1s matched build-cache reuse | All 74 passed, skipped 0. Static task/UI/architecture reviews approved fingerprint `55612a64850c7de0a7df25046251ece32f5b892ca9f998a267fb07caa69333e1`. UI runtime was not run under routine verification. |

The final suite's slowest cases were `test_task_done_preserves_worktree_and_branch` (35.375s, 19.0% of suite time) and `test_review_pr_conflicts_probe_and_verify` (17.429s, 9.4%). Together they used 52.804s, 28.4% of the 185.977s suite. Their duration alone does not establish avoidable work. The two changed concurrency cases took 2.306s and 2.170s in that final suite.

## Improvement to carry forward

**Make the contention handshake observable before the wait.** Three focused attempts spent 81.459s inside the failing case, and their command totals were approximately 9–10 minutes including repeated build/setup work. The test expected a queued diagnostic before releasing the first turn, but the diagnostic was produced only after lock acquisition. Put a contention event or fixture signal at the point where the second process starts waiting, then have the paired concurrency cases wait for that signal before releasing the first turn. Verify this by running both focused cases once and confirming they observe distinct process IDs and pass without extending timeouts.

## Measurement gaps

The task conversation and progress summaries, retained `bridge-tests.log` files, filesystem timestamps, and `scripts/test-e2e.sh` phase telemetry were checked. Test logs provide per-case time and lock wait; command output supplied some total/phase time. The retained artifact files do not contain the shell script's complete phase output, and the available task record does not timestamp every edit, static review, or the compile-failure attempt. Capture each `test-e2e.sh` invocation's existing `E2E phase=` and `E2E total_seconds=` lines alongside its artifact path in the task verification ledger; this would reconcile build, fixture, cases, and queue waits without adding new runtime instrumentation. The unclassified 19:36–21:20 span needs the task conversation/progress event timestamps to separate interruption and user wait from active work.
