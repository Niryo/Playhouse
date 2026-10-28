# Question routing and task repair workflow

Task: `752C1184-D363-4C62-B2A6-BF3697C8DDC8` · Client date: 2026-10-27

## Observed timeline

This is a **partial timeline**. The supplied conversation and verification ledger describe investigation, implementation, and three static-review revisions before 20:47:59 UTC, but do not timestamp their start or individual review cycles. The first measured task operation is the initial full CLI/XPC run. The incident log at 19:50 UTC describes product behavior, not the start of agent work.

| UTC interval | Operation and evidence | Duration |
| --- | --- | ---: |
| Before 20:47:59 | Log investigation, code/test changes, user approval for fixture extension, and static review/repair cycles; conversation and task ledger | Unknown |
| 20:47:59–20:53:49 | First full CLI/XPC run: 90/91 passed; separate CLI processes failed to exercise one shared Codex client; `/tmp/stationai-question-routing-e2e.log` | 350 s measured: build 170, cases 178, static/fixture 2 |
| 20:53:49–21:03:50 | Corrected test harness, source/UI adjustment, and affected static re-review; ledger plus run timestamps | 601 s derived gap; active work versus waiting unknown |
| 21:03:50–21:06:51 | Focused CLI/XPC run: 2/2 passed; `/tmp/stationai-question-routing-focused.log` | 181 s measured: build 154, cases 24, static/fixture 3 |
| 21:06:51–21:07:04 | Transition to final run | 13 s derived gap; activity unknown |
| 21:07:04–21:10:38 | Final CLI/XPC run: 91/91 passed; `/tmp/stationai-question-routing-final.log` | 214 s measured: reused build 1, cases 210, static/fixture 3 |
| 21:10:38–21:15:01 | Live question recovery at 21:11:48, checks, and handoff; verification ledger | 263 s derived gap; operations not individually timed |

From the first timed run to the recorded finish: **1,622 s (27 min 2 s)**. The three runs account for **745 s**: builds 325 s (44%), cases 412 s (55%), static/fixture 8 s (1%). The remaining **877 s** comprises the three gaps above; it cannot be classified as agent work or idle time from available evidence. Total task duration is longer because its start was not timestamped in the evidence available here. UI coverage received static approval; no UI runtime or screenshots were requested or run.

Slowest final-run cases were `test_task_done_preserves_worktree_and_branch` (27.122 s), `test_codex_questions_can_be_answered_over_cli_xpc` (21.735 s), and `test_review_pr_conflicts_probe_and_verify` (17.663 s). The first two together consumed 48.857 s, or 23% of the 210.148 s case runtime. No lock contention was reported; each build-cache wait was 0.000 s.

## Improvements

1. **Trace the process boundary when reviewing concurrent-client coverage.** The initial test launched two standalone CLI processes and asserted that they shared one Codex client; the full run failed after 350 s, followed by a 181 s focused run and required 214 s final run. The corrected case now uses a probe compiled from unchanged production core to exercise one in-process client, while CLI/XPC creates tasks and checks durable results. For future concurrency cases, have static review identify the exact object and process shared by the overlapping operations and confirm the assertion would fail if callbacks cross task boundaries. Verify by finding this ownership trace in the review record before the mandatory first full run. This targets a demonstrated test-design error without reducing required verification.

2. **Timestamp review and repair transitions in the existing task ledger.** The test scripts already emit phase and per-case durations, but the available ledger does not time the earlier three review revisions or the 601 s post-failure interval; the final 263 s also mixes live recovery and reporting. Record start/end timestamps for implementation ready, each static review request/result, each repair, and live recovery in that ledger. Verify that a later report can partition those 877 s of currently unclassified observed time without treating waits as active work. The conversation/tool timeline for the early work was unavailable after compaction; this report does not infer that the system never retained it.

Evidence checked: current-task conversation summary, task verification ledger, three command logs with per-case output, and `scripts/test-e2e.sh` timing implementation. The task-progress CLI exposes publish/clear operations but no historical progress read; no separate progress-history export was supplied.
