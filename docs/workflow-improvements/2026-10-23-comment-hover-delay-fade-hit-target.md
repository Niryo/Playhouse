# Comment hover delay and hit target workflow

Task: `4955B4B9-2A17-48E8-800D-88912CB4DA71` · 2026-10-23 (Asia/Jerusalem)

## Observed timeline

This is a partial timeline. The conversation establishes the request, implementation of the 200 ms delay, 120 ms fade, and 4 × 5 point tracking inset, plus static approvals, but exposes no reliable timestamps for that active work or its reviews. The two focused Tart logs and `scripts/test-ui-tart.sh` provide the timed portion below. Times are UTC; durations are derived from the logged timestamps unless marked approximate.

| Phase | Interval | Duration | Evidence |
| --- | --- | ---: | --- |
| First focused Tart run, artifact creation to exported status | 19:34:06–19:37:00 | ≈174 s | Run ID timestamp and `exit-status.txt` modification time; approximate because neither is an explicit start/end event |
| First guest lock to Xcode test completion | 19:34:47.722–19:36:49.846 | 122.1 s | `20261023T193406Z-56685/ui-test.log`; lock wait 0.000 s |
| First case execution | 19:36:18.960–19:36:46.399 | 27.4 s | XCTest timestamps; hover delay, top alignment, prompt dismissal, and both edge probes reached before failure at `StationAIUITests.swift:3743` while waiting for `comment-input-field` |
| Between observed host artifact end and next run ID | ≈19:37:00–19:37:09 | ≈9 s | Artifact timestamps; activity unknown |
| Second focused Tart run, artifact creation to exported status | 19:37:09–19:39:49 | ≈160 s | Run ID timestamp and `exit-status.txt` modification time; approximate |
| Second guest lock to Xcode test completion | 19:37:48.525–19:39:40.060 | 111.5 s | `20261023T193709Z-57843/ui-test.log`; lock wait 0.000 s |
| Second case execution | 19:39:07.075–19:39:36.443 | 29.4 s | XCTest timestamps; same hover assertions reached, then the same later input-field assertion failed |

Across the two runs, logged guest lock-to-Xcode time was 233.7 s: 169.8 s (73%) before case start, 56.8 s (24%) executing the single case, and 7.1 s (3%) after case end. The approximate artifact-to-status span was 334 s; about 100 s is outside the guest lock-to-Xcode interval and includes VM startup, snapshot/export, and shutdown, but the current logs do not time those stages individually. The first-to-last artifact timestamps span ≈343 s, including the ≈9 s gap. The implementation/review period and final handoff are unmeasured, so this is not the task's total duration. No per-assertion durations are emitted; the only named case in each run lasted 27.4 s and 29.4 s.

## Improvements

1. **Give the hover behavior its own paired case.** The focused command reran a broad annotation case twice (56.8 s of case execution, plus 176.9 s of surrounding guest setup/completion) and both runs passed the hover portion before failing at the same later comment-entry wait. Add a separate, independently meaningful hover case with a matching CLI case and shared contract expectation, reusing fixture helpers while retaining isolated app data. Verify its value by running the new case in Tart and checking that its result reports hover success or failure directly, independent of comment entry.
2. **Time the VM runner stages already present.** The runner visibly snapshots the source, invokes the guest test script, exports artifacts, and stops the VM; neither `tart-run.log` nor the exported guest log records the start/end of each host stage. About 100 s across these two runs falls outside the guest lock-to-Xcode interval. Add monotonic elapsed times for snapshot, VM launch, guest execution, artifact copy, and shutdown in `scripts/test-ui-tart.sh`. Compare stage totals with each run's artifact-to-status span, then investigate whichever stage dominates repeated focused runs.

Evidence checked: current task conversation and supplied review summary; both named Tart `ui-test.log` files, their artifact timestamps and `tart-run.log`; the paired UI case; `scripts/test-ui-tart.sh`. No task progress ledger with operation timestamps was supplied, so implementation, review, and agent idle gaps remain unquantified.
