# Fix red UI case `test_task_pr_conflicts_detect_without_mutation`

## Outcome

- Repaired the UI test's obsolete `app.alerts` title lookup with a selector/assertion matching the observed accessibility hierarchy.
- Focused Tart verification changed from failing to passing; parity passed all 67 cases.
- The authoritative ledger moved from 47 green / 20 red to 48 green / 19 red. The full suite was intentionally not run because this workflow calls for focused reruns of known-red cases.
- Task, UI, and architecture static reviews approved the test-only change.

## Evidence-based timeline

This is a partial timeline. The supplied run identifiers provide exact run starts and measured test durations, but no task-start timestamp, edit timestamps, review timestamps, parity duration, or final handoff timestamp.

| Phase | Timing | Classification | Evidence |
|---|---:|---|---|
| Baseline focused Tart case | 2026-10-27 18:55:50Z; 30.567s | Measured | Run `20261027T185550Z-14236`; failed at the old `app.alerts` title lookup |
| AX artifact inspection and test-only repair | Within the 3m45.433s gap between the baseline ending and retest starting | Derived outer bound; active/wait split unknown | Artifact showed `Sheet` → title `StaticText` → guidance `StaticText` → `OK`; no finer timestamps retained |
| Focused Tart retest | 2026-10-27 19:00:06Z; 21.418s | Measured | Run `20261027T190006Z-21381`; passed 1/1 |
| Parity check | Duration unknown | Unmeasured | Passed 67 cases |
| Static reviews | Duration unknown | Unmeasured | Task, UI, and architecture reviews approved |

The observed baseline-start-to-retest-end window was 4m37.418s, derived from the two run timestamps and durations. Test runtime accounted for 51.985s (18.7%) of that window. The remaining 3m45.433s (81.3%) contains artifact inspection, diagnosis, editing, and unobserved tool/runtime gaps and cannot be separated with the available evidence.

No estimated duration is reported: the evidence supports measured test durations and a derived outer bound, but not a defensible estimate for active repair work or the later review/parity phases.

## Slowest observed operations

1. Failed focused Tart case: 30.567s.
2. Passing focused Tart case: 21.418s.

The failed run cost 9.149s more than the passing run. The evidence does not identify whether that difference came from lookup timeout behavior, setup variance, or both.

## Practical findings

### Audit sibling alert selectors when accessibility semantics change

Evidence: this failure repeated the same obsolete `app.alerts` assumption as the recently repaired new-task alert. The failed case consumed 30.567s, and discovery occurred only after it became the next known-red case.

Action: when an AX artifact proves that an alert-like presentation is exposed as a `Sheet` with descendant static text, search the paired UI suite for the same legacy selector pattern and update directly related alert assertions in the same repair batch. Keep each affected case's authoritative focused rerun requirement unchanged.

Verification: record how many sibling selectors were found during the first repair and compare subsequent ledger entries for failures with the same lookup signature. Success means no later known-red case fails solely on the already-diagnosed `app.alerts` assumption.

### Preserve AX hierarchy in UI failure evidence

Evidence: the artifact exposed the exact visible structure and text needed to distinguish a selector mismatch from a product failure. The available timeline does not retain when artifact inspection began or ended, so its diagnostic cost cannot be measured separately.

Action: add structured failure metadata to the UI-run ledger or artifact summary for locator failures: failed selector, matched presentation role, relevant descendant labels, and artifact-inspection start/end timestamps.

Verification: on the next locator failure, the report should attribute diagnosis time separately from editing and rerun time and identify the replacement selector without manually reconstructing the hierarchy from an unindexed artifact.

## Telemetry gaps

Sources checked were the supplied task facts, focused run identifiers and per-case durations, parity result, static-review outcomes, and authoritative ledger transition.

- No task-level start/end timestamps were supplied, so total lifecycle wall time is unknown.
- No command-level timestamps or durations were supplied for AX inspection, editing, parity, or static reviews.
- The 3m45.433s between runs cannot be split into active work, tool runtime, or idle gaps.
- Focused run output did not provide setup/build versus case-body timing, so the 9.149s runtime difference is not attributable.
- No measured estimate existed before execution, so estimated-versus-actual variance cannot be calculated. The only supported comparison is that both measured focused runs are exact while all other phase durations remain unknown.
