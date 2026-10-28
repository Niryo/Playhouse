# Workflow analysis: fix `test_task_pr_create_reports_real_gh_failure` UI case

- Date: 2026-10-27
- Task ID/title: `fix test_task_pr_create_reports_real_gh_failure UI case`
- Scope: post-task analysis of the single UI-case repair
- Evidence checked: supplied verification ledger and review outcomes, `docs/ui-test-status.md`, the final UI helper, and worktree status/diff metadata

## Partial timeline

| UTC start | Operation | Duration | Evidence |
| --- | --- | ---: | --- |
| 20:06:36 | Initial focused Tart run passed | 33.650s case time; enclosing shell unavailable | Measured, run `20261027T200636Z-99122` |
| Unknown | First native-help implementation and review | Unavailable | Static UI review rejected the screenshot assertion because it conflated hover styling with delayed native help |
| 20:12:15 | First native-help focused Tart attempt passed | 43.405s case; 111.865s shell | Measured, run `20261027T201215Z-3164`; 68.460s shell overhead |
| Unknown, after review | Helper repair | Unavailable | Changed comparison to `XCUIScreen` at 0.25s after hover versus 1.5s later |
| 20:15:39 | Final focused Tart run passed | 44.543s case; 212.132s shell | Measured, run `20261027T201539Z-6345`; 167.589s shell overhead |
| Unknown | Parity and final static reviews | Unavailable | 67 named cases passed parity; task/UI/architecture approved fingerprint `60f1b2499afee4aa1ad55ade19b53d56d8234376ab5a1ec2c9aefc5f43c8f321` |
| Unknown | Full CLI/XPC suite attempt stopped before cases | 1.781s | Measured; unrelated pre-existing button-feedback lint failures in `KanbanBoardView.swift`, `StationAIApp.swift`, and `TaskConversationView.swift` |

The three focused cases consumed 121.598s of measured case runtime. The two runs with complete shell timing consumed 323.997s, including 87.948s of case runtime and 236.049s of setup/build/teardown overhead. Total directly observed execution is at least 359.428s: the latter two shells, the initial case time as a lower bound, and the failed full-suite attempt. This is not the task wall-clock duration because implementation, review, parity, initial-run shell overhead, and intervals between events lack timestamps.

## Findings and actions

### Make delayed-help assertions isolate the delayed effect

The first native-help attempt was green in 43.405s but failed static review because its screenshot delta could be caused by immediate hover styling. The repair required another focused run costing 212.132s wall time. Keep the final two-snapshot helper contract: establish the hovered baseline after 0.25s, then compare it with the screen after the 1.5s native-help delay. A future assertion should be accepted only if its baseline already includes immediate hover state. Verify this by static UI review before starting Tart; the expected benefit is avoiding one focused retry, measured here as 212.132s.

### Capture and reduce Tart shell overhead separately

For the two fully measured focused runs, non-case shell time was 236.049s, 72.9% of their combined 323.997s. The overhead also increased from 68.460s to 167.589s, but available evidence does not identify build, VM startup, lock wait, test teardown, or artifact-copy shares. Preserve per-phase timestamps in `scripts/test-ui-tart.sh` output for VM acquisition, synchronization/build, XCTest launch, XCTest completion, and artifact export. Verify the change by comparing phase totals with shell elapsed time on a focused case and requiring the unreconciled remainder to be small; then optimize only the measured dominant phase.

### Pin shell operations to the intended worktree

An earlier command accidentally targeted the main checkout because the persisted shell retained its prior current directory. This analysis reproduced the hazard: a shell request carrying the worktree as its working directory still reported the main checkout as its persistent cwd, while explicit `git -C /Users/niryo/.cursor/worktrees/StationAI/fx7v` returned the intended tree. Use explicit absolute `git -C` and either an explicit `cd` in each repository command or scripts that accept a worktree root; add a preflight that prints and validates the resolved repository root before task-scoped inspection or mutation. Verify that a shell persisted from another checkout fails the preflight rather than acting on that checkout.

### Classify pre-existing lint blockers before the full runtime gate

The full CLI/XPC attempt spent only 1.781s before correctly stopping on unrelated, pre-existing lint failures, so runtime waste was small. The process gap is that the known one-test scope reached the full-suite command before these blockers were recorded as out of scope. Run the same lint/preflight command before the runtime gate and compare its findings against the task fingerprint and scoped diff. Verify that unchanged pre-existing violations are reported as external blockers without launching the suite, while task-introduced violations still fail the task.

## Telemetry gaps

- No task-start, implementation, repair, review-start/end, parity, or handoff timestamps were available; those intervals cannot be estimated safely.
- The initial focused run has case time but no enclosing shell duration.
- Static review outcomes expose decisions and the final fingerprint, but not review elapsed time.
- Tart shell totals do not expose internal phase timings, preventing attribution of 236.049s of measured overhead.
- The available sources establish a partial execution timeline only; they do not support active-agent-time or complete task wall-clock calculations.
