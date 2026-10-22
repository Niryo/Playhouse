# Hide the PR button on Backlog tasks

Task: `8B68E628-8040-4636-817C-AB10930AC3F1`  
Date: 2026-10-22 (Asia/Jerusalem)

## Observed timeline

This is a **partial timeline**. The available task conversation and supplied verification record establish order, but have no reliable timestamps for the request, implementation, review rounds, or completion. Those intervals, including agent work, reviewer wait, and handoff, remain unknown; they are not counted as zero.

| Order | Activity and evidence | Elapsed time |
| --- | --- | --- |
| 1 | Request and repository exploration identified the shared `TaskCardView` overlay in `StationAI/App/KanbanBoardView.swift` (task progress record and working diff). | Unknown |
| 2 | Added the Backlog visibility condition and extended the paired CLI/UI PR case and shared contract (working diff). | Unknown |
| 3 | Static review at fingerprint `fe3b63d64c61cc0dfcc86b5d1997823217e115ec5100b0ac9107c8fdd28a8257`: two CLI assertion repair rounds and one UI assertion repair round, then task/UI/architecture approval (supplied verification record). Static parity reported 56 cases; parity and `git diff --check` passed. | Unknown; three repair rounds measured as a count |
| 4 | One full `scripts/test-e2e.sh` run passed 56/56 CLI/XPC cases with no skips (supplied command output). The reviewed fingerprint stayed stable across the run. | **146 s measured** |
| 5 | Completion and handoff; routine verification did not execute UI tests or take screenshots (supplied verification record). | Unknown |

The measured full-run phases sum to 146 s: static checks **1 s**, initial build **77 s**, fixture setup **2 s**, and cases **66 s**. The build was **53%** of measured runtime. The 56 case durations in `/tmp/stationai-bridge.jmPCog/bridge-tests.log` sum to **66.133 s**. The slowest cases were `test_conversation_composer_rejects_blank_and_supports_live_turn_controls` (**5.980 s**), `test_task_pr_conflicts_detect_without_mutation` (**3.171 s**), and `test_done_archive_displays_existing_pull_request_link` (**3.078 s**); together they were **18.5%** of case time. The changed case, `test_task_pr_create_reports_real_gh_failure`, took **1.914 s** (**2.9%** of case time). Build was the slowest measured operation. No task-wide wall-clock or active-agent total can be reconciled without start/end and review timestamps; the 146 s covers only the runtime command.

## Improvements

1. **Check the paired state transition before static review.** Three assertion repair rounds were needed for one existing PR case: two in CLI coverage and one in UI coverage; their time cost is unknown. Before submitting a similar visibility change, walk the paired case through persisted Backlog state, rendered card and absent control, then active state and present control against the contract. Record reviewer rounds on the next comparable task; success is fewer coverage repair rounds while preserving the required reviewers.
2. **Record review and task boundary times in the verification ledger.** The runtime artifact provided all 56 case durations, while review rounds and task start/end have no reliable elapsed times in the supplied record. `scripts/test-e2e.sh` already prints phase times and an artifact path; `scripts/test-bridge.py` already prints every case duration, and `scripts/prepare-e2e-build.py` prints cache-lock wait and reuse/miss information. Record review start/end and task start/end alongside the existing artifact path. Verify that the next report can separate reviewer wait from active work and reconcile runtime with full task wall-clock time.

Evidence checked: supplied task conversation/progress and verification summary; working diff; `/tmp/stationai-bridge.jmPCog/bridge-tests.log`; `scripts/test-e2e.sh`, `scripts/test-bridge.py`, and `scripts/prepare-e2e-build.py`. The missing review and task-boundary intervals are unavailable in the supplied ledger; the runtime scripts do emit phase and case durations.
