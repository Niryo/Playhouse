# New Task diagnostics workflow

Task: add correlated New Task UI start, success, and failure diagnostics with paired CLI/UI coverage. Date: 2026-10-22.

## Observed timeline

This is a partial timeline. The available conversation and handoff identify the sequence but do not expose task start/end timestamps, implementation duration, review duration, or idle gaps. Those intervals cannot be counted as agent work or included in a task-wide elapsed total.

| Order | Activity | Duration and evidence |
| --- | --- | --- |
| 1 | Added nonblocking `ui.new_task.started`, `succeeded`, and `failed` events; extended the existing paired case and added `test_new_task_failure_diagnostics` using the real store write-lock failure path. | Unknown; task handoff. |
| 2 | First parallel static reviews identified success ordering and synchronous flush concerns. Implementation moved success after lookup/selection and made diagnostics nonblocking. | Unknown; task handoff. |
| 3 | UI review identified nullable attempt-ID assertions. Assertions were changed to require a nonempty ID. Final task, UI, and architecture reviews approved; architecture approval was retained because production input was unchanged. | Unknown; task handoff. |
| 4 | Final parity check passed with 55 paired cases. | Duration unknown; task handoff. |
| 5 | One full `scripts/test-e2e.sh` run passed all 55 CLI/XPC cases with zero skips. | **163 s measured total:** build cache miss 95 s, fixture 2 s, cases 65.871 s; task handoff and suite phase output. |
| 6 | No UI execution or screenshots were part of routine verification. | Task handoff. |

The build was the slowest measured operation (about 58% of the full run), followed by the case phase (about 40%). Fixture setup took about 1%. Phase totals nearly equal the rounded 163-second run total. The suite emits individual `E2E case=... elapsed_seconds=...` records, but the completed run's case output was not supplied or retained in the accessible task evidence, so no individual case ranking is supportable. The overall task elapsed time and phase totals outside runtime remain unknown.

## Improvements

1. **Keep task-wide timing in the verification ledger.** Two static review rounds and two repairs are observable, but their wall time, agent work time, and waiting time are not. Record timestamped implementation-ready, review-request, review-result, repair-complete, runtime-start, and runtime-end entries for the next source task. Compare review and repair elapsed time against runtime after one task; this will show whether review coordination or code repair is the larger cost.
2. **Retain the final suite artifact path and case timing summary in the ledger.** The 65.871-second case phase is measured, and `scripts/test-bridge.py` already prints per-case durations, but the run output was unavailable for this audit. Save the existing `bridge-tests.log` path plus the slowest cases and their durations when verification completes. A later report can then rank cases and distinguish consistently slow cases from one-off setup without adding new instrumentation.
3. **Record why a build cache missed alongside its measured cost.** This run spent 95 seconds building, and `scripts/prepare-e2e-build.py` already prints cache-miss and lock-wait diagnostics. Preserve those existing lines with the run result, including the fingerprint and wait time. Across future tasks, compare cache misses with source changes and cache hits before proposing a build change; this task alone does not establish avoidable rebuild work.

Evidence audited: current task handoff and conversation, repository status, `scripts/test-e2e.sh` phase reporting, `scripts/test-bridge.py` case-duration reporting, and `scripts/prepare-e2e-build.py` cache diagnostics. No task progress file or verification ledger was available in the repository. Existing unrelated staged and unstaged edits were excluded from this task's review.
