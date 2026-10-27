# Fix one red visible UI case: `test_new_task_failure_diagnostics`

Date: 2026-10-27

## Outcome

The visible UI case was repaired by matching the accessibility structure actually emitted by SwiftUI: an AX sheet, an exact alert title, and a stable message prefix. Focused Tart verification passed 1/1, parity passed for all 67 cases, all three static reviews approved, and the authoritative ledger moved from 46 passing / 21 red to 47 passing / 20 red. The full UI suite was correctly not run because the ledger directs focused red-only reruns while 20 cases remain known red.

## Partial timeline and durations

| Phase | Evidence and result | Duration |
| --- | --- | --- |
| Initial case investigation | Multiple hypotheses for `test_thread_goal_lifecycle_persists_through_cli_xpc` were tried and reverted; the case remained red. | Unknown; no attempt timestamps, counts, or command durations were supplied. |
| Artifact-led rotation | Existing artifacts showed the alert was an AX Sheet with child StaticTexts and OK, so work rotated to `test_new_task_failure_diagnostics`. | Unknown; no timestamp for artifact inspection or selector editing. |
| Focused baseline | Failed. | 13.917s measured |
| First selector repair | Advanced beyond the original failure, then failed because the message match was over-specific. | 5.030s measured |
| Final selector repair | Queried the sheet, exact title, and stable message prefix. Tart run `20261027T183650Z-90600` passed 1/1. | 5.257s measured |
| Parity and static review | 67 cases matched; task, UI, and architecture reviews approved. | Unknown; no command or review start/end timestamps. |
| Ledger update | 46/21 became 47/20. No full-suite run by design. | Unknown |

Measured focused-test runtime totals 24.204s. The baseline was the slowest measured operation at 13.917s (57.5% of measured runtime), followed by the final pass at 5.257s (21.7%) and the intermediate failure at 5.030s (20.8%). No defensible estimate exists for active editing, the abandoned-case investigation, reviews, parity, or total task wall time, so estimated phase and total durations are intentionally not fabricated.

## Improvements

### Inspect the AX hierarchy before changing visible-alert selectors

Evidence: artifact inspection identified an AX Sheet containing StaticTexts and OK. Using that structure produced the passing selector. The earlier over-specific message match consumed one additional 5.030s test run, plus unmeasured edit and review time.

Action: for the next visible-alert failure, inspect the failed-run accessibility artifact first and record the element type, exact stable title, and stable message boundary before editing the selector. Prefer exact matching for invariant titles and prefix matching for messages containing variable diagnostics.

Verify: track whether the first selector-only repair reaches the intended alert assertion and compare selector-repair rerun counts; the target is one focused rerun after baseline rather than the two used here.

### Record hypothesis-cycle timing before rotating cases

Evidence: the initial lifecycle case involved multiple unsuccessful hypotheses and complete reversions, but the evidence does not retain attempt count, per-attempt duration, or the point at which rotation became preferable. Its cost and share of task time therefore cannot be evaluated.

Action: add a compact task-ledger entry for each red-case hypothesis with case ID, hypothesis, run ID, measured command duration, result, and whether the change was reverted. Record the timestamp and reason when rotating to another red case.

Verify: the next red-case repair report should reconcile every attempt from first run through pass or rotation and quantify the time spent on reverted paths without reconstructing it from prose.

## Telemetry gaps

Checked sources were the supplied task conversation facts, focused-run IDs and durations, parity result, static-review outcomes, and ledger transition. The following data was unavailable in those sources:

- task start/end timestamps and total wall-clock duration;
- active editing versus tool/runtime wait;
- number and duration of lifecycle-case hypothesis cycles and reversions;
- artifact-inspection and selector-edit durations;
- parity-check and static-review durations;
- ledger-update duration.

The focused test runner emits usable per-run durations. The remaining gaps require task progress timestamps and hypothesis/review ledger entries; this evidence does not establish whether those events are emitted elsewhere but inaccessible here or are not retained.
