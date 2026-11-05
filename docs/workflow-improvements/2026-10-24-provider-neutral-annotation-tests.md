# Provider-neutral annotation tests: workflow record

Task: use a provider-neutral annotation marker, remove redundant provider coverage, and update provider parity rules and reviewer agents. Date: 2026-10-24 (Asia/Jerusalem).

## Observed timeline

| Phase | Evidence | Duration |
| --- | --- | --- |
| Explore and edit the annotation path, paired tests, fixtures, rules, skill, and reviewer definitions | Task conversation and working-tree file list | Unknown: no phase timestamps retained in the available task record |
| Cheap parity and syntax checks | Task handoff: 67 paired cases; Swift and Python syntax and diff checks passed | Unknown |
| First parallel static review | Task handoff: task and UI reviewers rejected fingerprint `02e50559…`; architecture approved | Unknown |
| Repair and repeat affected reviews | Task handoff: the existing Codex pair gained an actual comment-only send/request/reply; task and UI reviewers approved `919d1fcf…`; architecture approval retained | Unknown |
| Full headless CLI/XPC run | `scripts/test-e2e.sh` output in task handoff and `/tmp/playhouse-bridge.63D77h/bridge-tests.log` | 271 seconds measured by runner; build cache miss about 127 seconds from handoff; 67 cases 142.222 seconds measured by test log |
| Runtime UI and screenshots | Task handoff | Not performed under routine verification |

The observed timed portion is **271 seconds**. Build and case execution account for about 269 seconds; about 2 seconds remain for static checks, fixture setup, and runner overhead, with rounding uncertainty. The full task elapsed time and active agent time cannot be calculated: the available conversation handoff has no task start/end timestamps or durations for editing and reviews. The bridge log starts at the run-lock acquisition (`2026-10-24T17:39:59Z`), after the build, so it cannot supply the run start time. The run-lock wait was 0.000 seconds. These are evidence limits, not zero-duration phases.

Slowest cases in the bridge log: `test_task_done_preserves_worktree_and_branch` 25.616 seconds (18.0% of case time), `test_review_pr_conflicts_probe_and_verify` 14.501 seconds (10.2%), and `test_conversation_composer_rejects_blank_and_supports_live_turn_controls` 6.388 seconds (4.5%). The changed annotation case, `test_conversation_adds_ordered_text_annotations`, took 1.574 seconds. All 67 cases passed; there was one full runtime run and no runtime retry.

## Practical findings

1. **Preserve the review catch as an explicit interaction trace.** The first static pass found that the retained representative case did not submit a comment-only turn. This caused one repair and one repeat of the affected static reviews; their elapsed cost was not captured. For future provider-agnostic behavior changes, include the concrete UI and CLI action-to-assertion trace in the reviewer handoff (for this feature: add comment → submit comment-only turn → inspect provider request → verify saved reply). Check impact by counting coverage rejections for missing interaction steps in later tasks. This supplements the new provider-path rules without adding duplicate provider cases.
2. **Investigate the two longest existing cases before changing them.** Together they consumed 40.117 seconds, 28.2% of the measured case time, on this full run. Inspect their internal waits and Git/PR fixture operations to determine whether that duration is required; change only a proven avoidable wait or setup step. Compare the same case timings across later full runs. The current log gives total case durations but does not explain their internal costs.

## Evidence and telemetry gaps

Checked the task handoff, runner output summary, `/tmp/playhouse-bridge.63D77h/bridge-tests.log`, and `scripts/test-e2e.sh`. The runner emits phase elapsed seconds, but those phase lines were available only as the summarized handoff, not as a retained artifact alongside `bridge-tests.log`; the log itself emits named-case durations. Task activity and static-review timing are unavailable in the provided task record. To measure the full workflow in a later task, retain the command output containing `E2E phase=` lines and record review start/end timestamps in the task verification ledger before proposing new telemetry.
