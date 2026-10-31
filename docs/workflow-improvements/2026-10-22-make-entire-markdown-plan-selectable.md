# Make the Entire Markdown Plan Selectable

Task: `1167F04A-8E23-4EB6-9D60-8BB6B611DA9B`  
Date: 2026-10-22 (Asia/Jerusalem)

## Observed timeline

| Phase | Timing | Evidence |
| --- | --- | --- |
| Inspection and progress publication | Start and duration unknown | Task handoff; no timestamped task-start record available |
| Implementation | Duration unknown; changed files last modified at 22:27:54–22:29:55 local | Working-tree file metadata and diff; modification times do not measure active work |
| First static review and repair | Duration unknown; UI coverage rejected because copied-text checks covered only the beginning and end, and the target used a test-only identifier. A middle-plan assertion and accessibility-label target were added. | Task handoff; no per-review start/end times retained |
| Repeat static review | Duration unknown; task, UI, and architecture reviews approved | Task handoff; no per-review timing retained |
| Final CLI/XPC run | 171 s measured; approximately 22:30:38–22:33:29 local from artifact timestamps and runner total | `scripts/test-e2e.sh` phase output supplied in task handoff; `/tmp/playhouse-bridge.Nefazg/bridge-tests.log` |
| Reporting/handoff | Duration unknown | Task handoff; no completion timestamp for the source task |

The observed runner time divides into build 79 s (46.2%), cases 89 s (52.0%), and approximately 3 s (1.8%) for static checks and fixture/setup combined. The full task duration and active agent time cannot be reconciled because the task start, review spans, implementation span, and source-task completion time were not recorded in the available evidence. The final run passed 56 named cases with zero skips; parity checked 56 cases and the diff check was clean. No focused retry is reported for this task.

## Slowest measured cases

| Case | Duration | Share of 89 s case phase |
| --- | ---: | ---: |
| `test_task_done_preserves_worktree_and_branch` | 24.106 s | 27.1% |
| `test_conversation_composer_rejects_blank_and_supports_live_turn_controls` | 5.441 s | 6.1% |
| `test_task_pr_conflicts_detect_without_mutation` | 3.652 s | 4.1% |
| `test_task_delete_removes_task_and_later_lookup_is_not_found` | 3.052 s | 3.4% |
| `test_codex_questions_can_be_answered_over_cli_xpc` | 2.698 s | 3.0% |

The changed plan case, `test_plan_mode_renders_markdown_in_conversation`, took 0.612 s (0.7% of the case phase). Case timings come from the final run log; they do not establish that a slow case is avoidable.

## Improvements

1. **Make selection coverage explicit before static review.** This task needed one UI review repair cycle because the first copy assertion checked only the plan's beginning and end, and relied on an identifier introduced solely for the test. The cycle's duration is unmeasured. For future whole-document selection changes, put beginning, middle, and end copy assertions and a user-visible accessibility target in the paired UI test before requesting review. Measure whether similar changes pass UI coverage review on the first submission.
2. **Carry the final run artifact path into the task verification ledger.** `scripts/test-e2e.sh` already emits the artifact directory and `scripts/test-bridge.py` already emits per-case durations; the task handoff retained only phase totals. Record the emitted path alongside the run's input fingerprint and phase totals. Verify that a later task report can identify its exact slowest cases directly from the ledger without searching other `/tmp` runs. This requires no new runner logging.

## Evidence limits

Checked the current task handoff, working-tree diff and file metadata, `scripts/test-e2e.sh`, `scripts/test-bridge.py`, and the matching final bridge log. No task-specific progress record or verification ledger with start/end times was supplied or found in the repository. The exact unobserved intervals are inspection through first review, review and repair through approval, and source-task completion through handoff. A timestamped task progress/verification record would be needed to quantify those intervals; file modification times are only point observations. Other `/tmp` bridge runs were excluded because their association with this task is unsupported.
