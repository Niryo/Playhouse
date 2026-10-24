# Add Durable Goals to Tasks — workflow findings

Task: `16B9117F-8308-4B7A-B1C8-ECE45ED805F6`  
Client date: 2026-10-22 (Asia/Jerusalem)

## Observed timeline

| Order | Phase | Duration | Basis |
| --- | --- | ---: | --- |
| 1 | Official Goal/app-server research, repository discovery, implementation, paired CLI/UI case, and several static review/repair rounds | Unknown | Task conversation and progress summary establish order, but provide no phase timestamps. |
| 2 | First E2E invocation stopped by button-feedback preflight; controls were repaired and the check passed | Unknown | Task conversation; no elapsed output retained. No case executed. |
| 3 | First full E2E attempt stopped by duplicate `modeMenu` declaration during build; repair and affected static approval refresh followed | 63 s runner; repair/review unknown | Runner duration supplied in task verification handoff. No case executed. |
| 4 | Full CLI/XPC run found a missing delegation diagnostic event and Goal resume's active-writer error | 179 s runner, including 92.635 s for 57 cases | Runner output and `/tmp/stationai-bridge.DUR92B/bridge-tests.log`. Remaining approximately 86 s is static/build/fixture/lock overhead, not separately attributable from the retained case log. |
| 5 | App-server shutdown repair and affected static re-reviews | Unknown | Task conversation; the interval between runs includes work and possible waits that cannot be separated. |
| 6 | Focused Goal lifecycle retry passed | 93 s runner, 3.964 s case | Runner output and `/tmp/stationai-bridge.8O26ov/bridge-tests.log`; approximately 89 s outside the case, including a changed-source build. |
| 7 | Focused delegation retry passed | 4 s runner, 1.095 s case | Runner output and `/tmp/stationai-bridge.jJE3z2/bridge-tests.log`. |
| 8 | Final full CLI/XPC run passed 57/57, no skips | 97 s runner, 93.510 s cases | Runner output and `/tmp/stationai-bridge.GDRn8L/bridge-tests.log`; matching build reused. |
| 9 | Handoff and this analysis | Unknown | No task completion timestamp was supplied. |

The five timed runner invocations total **436 s (7 min 16 s)**, of which **191.204 s** is measured case execution and about **245 s** is runner overhead or the build-only failed attempt. This is a lower bound on observed task time, not a full task duration: research, editing, static reviews, repairs, tool waits, gaps, and reporting have no supported totals. The latest retained case log ended at about 23:49:54 IDT; a trustworthy task start and end are unavailable. File modification times give only coarse end signals, not active agent time.

In the final suite, `test_task_done_preserves_worktree_and_branch` took **24.416 s**, or **26.1%** of the 93.510 s case phase; the same case took 24.490 s in the failed full run. Next were conversation composer/live controls (**5.257 s**) and PR conflicts (**3.720 s**). The Goal case took **2.919 s** in the final run. The slowest case creates and completes 40 archive filler tasks after checking Done behavior, so its pagination work is directly visible in `scripts/test-bridge.py`.

## Improvements

1. **Run the existing button-feedback check immediately after editing action controls.** The first E2E invocation stopped at that preflight, before a build or case; its elapsed cost was not retained. Add `python3 scripts/check-button-feedback.py` to the local UI edit checkpoint before static review. Verify on the next UI-control task that the first E2E preflight passes without a repair cycle.

2. **Separate archive pagination from the Done lifecycle case in both paired suites and their shared contract.** The case spent 24.416 s in the final run (26.1% of case time), and its 40 filler completions exercise archive paging after an independent Done workflow. Keep real CLI/XPC persistence and the visible UI pair, but give pagination its own named case so failures and focused retries isolate the relevant behavior. Verify that the Done case's measured duration falls, pagination remains covered, and the full suite retains parity and passes; a full-suite speedup is not claimed from splitting alone.

## Evidence limits

Checked the task conversation/progress and verification handoff, four task-specific bridge logs with per-case times, and `scripts/test-e2e.sh`/`scripts/prepare-e2e-build.py`. The runner already emits total and phase durations to stderr and per-case durations to `bridge-tests.log`; the retained case logs alone do not contain phase durations. The supplied progress/ledger did not expose timestamps for research, edits, reviewer start/end, repair, communication, or user wait. A timestamped task/tool/review event export would be needed to apportion those intervals; no new repository logging is justified from this audit.
