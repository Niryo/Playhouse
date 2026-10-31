# PR #56: resolve `support-codex` merge conflicts

## Observed timeline

This is a partial timeline. The conversation and supplied verification ledger identify the sequence, but do not expose timestamps for task start, exploration, edits, static reviews, or most suite launches. The final full suite artifact ended at 2026-10-24 20:17:56 +0300; its reported 150-second runtime places its start at approximately 20:15:26 +0300. That start is derived from the rounded runtime, not an independent timestamp. Task end and total wall-clock or active-agent time are not yet recorded.

| Phase | Evidence | Duration |
| --- | --- | ---: |
| Merge preparation, ten-file conflict resolution, and paired test updates | Task conversation and verification ledger | Unknown |
| Static task, UI, and architecture reviews; repair and reapproval | Verification ledger, all approved | Unknown |
| Initial full CLI/XPC run, 67 cases, five failures | Supplied runtime ledger | About 237 s, estimated from reported output |
| Focused six-case retry, two failures | Supplied runtime ledger | About 160 s, estimated from reported output |
| Focused two-case retry, passed | Supplied runtime ledger | About 128 s, estimated from reported output |
| Full CLI/XPC run, 68 passed, no skips | `/tmp/playhouse-bridge.lSK5wk/bridge-tests.log` and runtime ledger | 144 s reported; 140.664 s inside Python |
| Portability repair: replace Pillow logo check with `sips` and standard library; task reapproval | Verification ledger | Unknown |
| Focused logo/bridge-version case, passed | Supplied runtime ledger | About 6 s, estimated from reported output |
| Final full CLI/XPC run, 68 passed, no skips | `/tmp/playhouse-bridge.wsGkea/bridge-tests.log` and runtime ledger | 150 s reported; 146.686 s inside Python |

The six reported suite durations sum to approximately **825 seconds (13 minutes 45 seconds)** of tool/runtime wait. Three full runs account for approximately **531 seconds (64%)** of that observed test time. This is only a lower bound on task elapsed time; editing, reviews, communication, and intervals between tool calls are unmeasured. The two final full-suite log files contain per-case timings; earlier run artifacts were not supplied in the ledger. No visible UI suite ran under the routine verification policy.

The final full run's slowest cases were `test_task_done_preserves_worktree_and_branch` (26.026 s, 17.7% of case time), `test_review_pr_conflicts_probe_and_verify` (14.218 s, 9.7%), and `test_conversation_composer_rejects_blank_and_supports_live_turn_controls` (6.755 s, 4.6%). The first two also led the preceding full run (24.683 s and 14.447 s). Case timings summed to 146.677 s in the final run; the Python wrapper reported 146.686 s, leaving about 3 seconds of its 150-second shell runtime for setup and rounding. The shell script emits static, build, fixture, and cases phase durations, but their output was not preserved in the available artifacts.

## Improvements

1. **Check merged expectations before the first full run.** Five of 67 cases failed on the first full run after the merge, followed by a six-case retry. That first run cost about 237 seconds. For future conflict resolutions, map each edited contract or test expectation to the retained behavior and run the affected case IDs once after static approval, before the required full-suite confirmation. Measure whether this reduces full-suite failures and repeated full runs; keep the repository's required final full confirmation.
2. **Audit new test dependencies before static approval.** The logo assertion initially imported Pillow, then needed a portability repair to use tools available on the macOS runner. The repair led to a focused run (~6 s) and another final full run (150 s), plus unmeasured review time. Add a lightweight check for newly introduced nonstandard Python imports in executable test scripts and confirm how they are installed. Track post-approval dependency repairs and resulting rerun time.
3. **Retain suite phase output with the test artifact.** `scripts/test-e2e.sh` emits static, build, fixture, cases, and total durations to stderr, while the available `bridge-tests.log` stores only Python case output. This prevents attributing the approximately 93-second difference between the first full run (~237 s) and later full runs (144–150 s) to compilation, fixture setup, or another phase. Capture the existing phase lines beside `bridge-tests.log` for each run, then compare phase totals across cache misses and hits before changing build behavior.

## Evidence gaps

Checked the task conversation and supplied ledger, the two retained full-run `bridge-tests.log` files, and the emitting code in `scripts/test-e2e.sh` and `scripts/test-bridge.py`. The provided evidence lacks the original start timestamp, edit and reviewer start/end times, earlier per-case logs, retained shell phase output, and the final commit/push timestamp. Those gaps prevent a complete wall-clock timeline, active-agent calculation, or a reliable build-cost estimate. The script already emits phase timing; the gap is artifact retention in the available record, not absent phase instrumentation.
