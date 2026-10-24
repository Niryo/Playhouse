# Display Codex plan items: workflow review

Task: show Codex Plan mode output live and after conversation reload. Date: 2026-10-22 (Asia/Jerusalem).

## Timeline and measured time

The task start and completion timestamps were not preserved in the supplied task record, so the lifecycle timeline is partial. The order below comes from the task handoff and verification results; only the CLI suite has measured duration. Agent work, review time, and the interruption interval cannot be separated from wall-clock time.

| Order | Work | Duration and evidence |
| --- | --- | --- |
| 1 | Investigated the missing Plan mode output and the app-server `plan` item path; changed live delta/completion handling and history conversion. Updated the protocol fixture and paired CLI/UI case. | Unmeasured; task conversation and unstaged diff. |
| 2 | First static review found that the UI case did not prove the first delta was visible before completion. Added a fixture hold/release gate and UI assertions. | Unmeasured; review handoff and unstaged diff. |
| 3 | Task verifier found that the CLI case needed an explicit event-order assertion. Added it, then obtained task, UI, and architecture approval. Parity reported 56 cases; syntax and diff checks passed. | Unmeasured; review and check handoff. |
| 4 | Ran `scripts/test-e2e.sh` once. It passed 56/56 cases with zero skipped. A user interruption occurred during the build, but the running process continued; the relevant input fingerprint matched at the end. UI execution and screenshots were outside routine verification. | **197 s measured** by the script: build 101 s, fixture 2 s, cases 93 s; remaining 1 s is static/setup work or whole-second rounding. |

The observed CLI run accounts for **197 s**. Build was the longest reported operation (101 s, 51% of the run), followed by the cases phase (93 s, 47%) and fixture preparation (2 s, 1%). These are phase totals, not active agent time. No reliable total task duration or phase totals for investigation, implementation, and static review can be calculated. The task artifact at `/tmp/stationai-bridge.ZEi4sP/bridge-tests.log` records all 56 per-case timings; their sum is 92.674 s against the runner's 93 s cases phase. The changed plan case took 0.595 s. The slowest case was `test_task_done_preserves_worktree_and_branch` at 24.218 s. `scripts/test-bridge.py` emits per-case elapsed times and `scripts/test-e2e.sh` prints the artifact path.

## Practical improvements

1. **Preserve suite artifacts in the verification ledger.** The task output included a usable artifact path; pass that path into the workflow report handoff so the per-case timings can be summarized without rediscovery. On the next task, verify that the case durations sum to the suite's reported case execution time and identify the slowest cases. This requires retaining existing output, not adding logging.
2. **Make streamed response ordering explicit in the initial case design.** Two static review findings required separate repairs: the UI lacked a pre-completion visibility check, then the CLI lacked an event-order check. The elapsed review cost is unmeasured; the observable cost was two repair cycles. When changing streamed app-server items, write the paired contract around first delta, completion, and reload, then assert those stages in both suites before static review. Check the next comparable task for fewer review repair cycles while keeping the required reviews.

## Evidence limits

Checked the task conversation and handoff, unstaged diff, `scripts/test-e2e.sh` phase reporting, and the task-specific `bridge-tests.log`. The task record provides no start/end timestamps or review timestamps. The runner emits phase and case timing, so lifecycle timing still needs task progress timestamps or a verification ledger with phase boundaries. No timing is inferred from unrelated `/tmp` bridge runs.
