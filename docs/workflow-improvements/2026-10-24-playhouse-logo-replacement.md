# Playhouse logo replacement — workflow review

Task: replace the Dock icon and board header logo with `playhouse-Photoroom.png`, preserving the artwork over solid `#2C2F36`. Client date: 2026-10-24. Reviewed unstaged task fingerprint: `befb9c3f9678bc913da623f0d65377fb12e9c06461470539e66e73ba322ee954`.

## Observed timeline

| Phase | Duration | Evidence and limit |
| --- | ---: | --- |
| Source inspection, image preview, deterministic asset composition, paired assertions, and static reviews | Unknown | Conversation and verification ledger describe the sequence but provide no start/end timestamps. One generated preview was discarded because it changed the requested colors/artwork. Task and UI reviews approved the final fingerprint; architecture approval was retained because its asset/view inputs did not change after its review. |
| First full CLI/XPC run | 235 s | Runner output: build 98 s; 62 cases 133.273 s; roughly 4 s for static checks/fixture/wrapper by subtraction. One case failed. |
| Focused retry, `test_task_prompt_draft_persists_after_back` | 5 s | Runner output: case 1.282 s; roughly 4 s setup/wrapper. Passed. |
| Required final full CLI/XPC run | 120 s | Runner output: cached build 0 s; 62 cases 117.031 s; roughly 3 s setup/wrapper. Passed, no skips. |
| Reporting/handoff | Unknown | No task-specific timestamped start/end record was supplied. |

The **observed sequential verification commands total 360 s**. Their case execution totals 251.586 s; the first build accounts for 98 s; the remaining roughly 10.4 s is setup and wrapper time, subject to whole-second command timing. Total task wall time and active agent time cannot be reconciled because planning, implementation, review, and handoff timestamps are unavailable in the supplied conversation/ledger. The three command durations include tool/runtime wait and should not be counted as active agent work.

The first failure spent 15.781 s in `test_task_prompt_draft_persists_after_back`, reaching the fixture's 15-second readiness deadline. The same case passed in 1.282 s on focused retry and 1.304 s in the final suite. In the final suite, `test_task_done_preserves_worktree_and_branch` took 24.699 s and `test_review_pr_conflicts_probe_and_verify` took 13.967 s; together they were 38.666 s, or 33.0% of the 117.031-second case run. These are timing observations, not evidence that either case is unnecessary.

## Improvements supported by this task

1. **Investigate the delayed-title fixture readiness race.** The failure waited the full 15 seconds for `.resolve-ready`, while the CLI send completed successfully and both retries passed. This triggered a focused run and a required 120-second full rerun; the observed extra verification after the failed run was 125 seconds. Inspect this run's app diagnostics and fixture events in `/tmp/playhouse-bridge.ESk0wK` to determine why readiness was absent before changing the wait. Verify a fix by repeating this case under normal suite load and recording whether the readiness timeout recurs.
2. **Use deterministic composition for exact branded assets from the start.** One generated preview was discarded because it altered the specified background/artwork; its duration was not recorded. The final CoreGraphics path produced the exact `#2C2F36` background and kept source alpha artwork. For future exact-color icon swaps, compose from source pixels, then check corner RGB, dimensions, and alpha handling before review. Track the number of discarded previews as the impact measure.

## Telemetry checked and gaps

Checked the supplied conversation and verification ledger, the retained per-case bridge logs in `/tmp/playhouse-bridge.{ESk0wK,fVmBcx,zP1QBA}/bridge-tests.log`, and `scripts/test-e2e.sh`, which emits phase and total seconds. The available task record does not expose timestamps for asset work, review dispatch/completion, or user-facing handoff. A timestamped task progress record for those events would permit wall-clock and active-work reconciliation; this report does not assume the test runner lacks such data beyond the reviewed output.
