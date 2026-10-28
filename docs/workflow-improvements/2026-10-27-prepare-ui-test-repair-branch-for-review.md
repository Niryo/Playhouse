# Workflow analysis: prepare UI test repair branch for review

- Task: `prepare-ui-test-repair-branch-for-review`
- Date: 2026-10-27
- Scope: branch review preparation, repair verification, status-ledger retention, and PR readiness
- Evidence checked: task transcript, supplied verification ledger, current unstaged diff, `AGENTS.md`, and workflow-optimizer configuration

## Partial timeline and durations

The transcript records the task request at 22:23 UTC+02:00 but does not retain the subsequent task-specific tool timeline or a completion timestamp. Implementation, review, Git, and PR phase durations therefore cannot be reconstructed. The verification runs below are measured from the supplied runner telemetry; ordering is known, but their wall-clock start times and gaps between runs are unavailable.

| Phase | Result | Total | Cases | Non-case time |
|---|---:|---:|---:|---:|
| Initial full headless suite | 88/90 | 353.182s | 197.414s | 155.768s |
| Focused restart case | pass | 167.484s | 5.938s | 161.546s |
| Composer attempt 1 | fail | 12.218s | 7.802s | 4.416s |
| Composer attempt 2 | fail | 172.051s | 8.208s | 163.843s |
| Composer attempt 3 | fail | 172.782s | 17.130s | 155.652s |
| Composer attempt 4 | pass | 167.766s | 9.361s | 158.405s |
| Final full headless suite | 90/90 | 188.757s | 184.495s | 4.262s |

Observed verification wall time was 1,234.240s (20m 34.240s): 430.348s in cases and 803.892s outside cases. Focused retries accounted for 680.301s, of which only 48.439s was case execution. Static parity covered 90 cases. Routine UI execution was intentionally omitted under policy.

No task estimate was recorded in the checked evidence, so estimated-versus-measured variance is unavailable. The final warm full-suite run (188.757s) is a measured baseline, not a retroactive estimate.

## Improvements

### Expose and reuse focused-run setup state

Four focused passes with normal setup spent 155.652–163.843s outside their cases; together they consumed 687.865s for 40.637s of case execution. One composer attempt and the final full suite had only 4.416s and 4.262s outside cases, showing that a warm path already exists.

Record cache/build identity, cache hit or miss, lock wait, app/service startup, fixture setup, and teardown durations in `scripts/test-e2e.sh` output. Then make focused retries explicitly reuse a content-matched build/service when the relevant fingerprint is unchanged. Verify the change by comparing median non-case time across a failed case plus three focused retries; target the observed warm-path range without weakening fixture isolation or required final full-suite verification.

### Print a run summary suitable for the verification ledger

The supplied evidence preserves total and case durations but not timestamps, commands, fingerprints, failure assertions, or setup-stage breakdowns. That prevents reconstruction of review latency and makes it unclear why composer attempt 1 was warm while attempts 2–4 paid full setup cost.

Have the headless runner emit one machine-readable summary per invocation containing start/end timestamps, selected case IDs, relevant-input fingerprint, result, case duration, and setup-stage durations. Verify that a future optimizer can reconcile all run time and retry causes from those summaries without terminal transcripts.

### Capture task phase timing at handoff

The retained transcript stops at the request, so time spent on ignore decisions, diff review, repairs, static review, status-document integration, commit/push, and PR creation is unknown. Add start/end timestamps and outcomes for these phases to the task verification ledger already required by policy. Verify that the next branch-preparation report can separate active work, external/tool wait, and unobserved gaps and compare each phase with an explicit estimate.

## Telemetry gaps

- No implementation, static-review, Git, PR, or completion timestamps were retained in the available task transcript.
- No phase estimates were recorded; measured-versus-estimated variance cannot be calculated.
- Headless totals do not break non-case time into build/cache, lock, startup, fixture, and teardown stages.
- Per-case timings for the two full suites beyond aggregate case time were not supplied, so individual slow cases cannot be ranked.
- Inter-run gaps and active-agent time are unknown.
- UI suite duration is not missing telemetry: routine UI execution was intentionally not run.
