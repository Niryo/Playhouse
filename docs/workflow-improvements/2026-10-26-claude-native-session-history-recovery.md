# Claude native-session history recovery: workflow audit

Task `6E790274-0DC1-4517-BC7B-D6EAD0B2510F` — Investigate Claude Conversation History Loss After Restart. Client date: 2026-10-26.

## Timeline and coverage

This is a **partial timeline**. The supplied task conversation and verification ledger establish order but contain no task-start timestamp, implementation timestamps, review durations, or task-end timestamp. Durations below are approximate unless noted; no interval without a timestamp is counted as zero or as agent work.

| Order | Operation | Observed duration and source |
| --- | --- | --- |
| 1 | Read-only diagnosis of missing Claude `--resume` fallback; user requested a fix and approved the protocol fixture and Claude-only scope | Duration unknown; task conversation. Gaps between user replies are unmeasured user wait, not agent work. |
| 2 | Implement transcript recovery, paired CLI/UI case, and protocol fixture; parity passed 73 case contracts | Duration unknown; task ledger and current task diff. |
| 3 | Static review: task verifier approved; UI verifier rejected a missing assertion for the second old answer; UI assertion was added and approved; architecture recorded the image-context concern | Duration unknown; task ledger. Task review was retained because its implementation/CLI/contract inputs were unchanged. |
| 4 | First full `scripts/test-e2e.sh`: fresh build, then 73-case run failed only the new recovery case | Build about 136 s; cases about 164 s; task ledger. Failure came from the fixture matching `story` in replayed history before matching the final prompt. |
| 5 | Fixture response routing corrected; focused recovery case rerun | Fresh build about 131 s; case 2.297 s, 1/1 passed; task ledger. Other setup and static-check time are not separately recorded. |
| 6 | Final full CLI/XPC suite | Cached build; cases about 163 s, 73/73 passed with no skips; task ledger. Parity and `git diff --check` passed. No UI execution, screenshot, or live-provider run was part of routine verification. |
| 7 | Final handoff and post-task analysis | Duration unknown; task-end signal absent from available evidence. |

The five timed build/case segments sum to **about 596 s (9 min 56 s)** of observed runtime across three invocations: builds about 267 s (45%), full-case runs about 327 s (55%), and the focused case 2.297 s (<1%). These are rounded ledger values, not a full task duration. Static checks, fixture preparation, lock waits, implementation, review, communication, and gaps between turns are outside that subtotal. No per-case durations from the two full runs were supplied; among named cases, the focused recovery case is the only measured case at 2.297 s. The longest measured operations are the first full case run (~164 s), final full case run (~163 s), first build (~136 s), and retry build (~131 s).

Evidence audit: checked the supplied task conversation and verification ledger, current task diff, `scripts/test-e2e.sh` phase/total reporting, `scripts/prepare-e2e-build.py` cache fingerprint and lock timing, `scripts/with-file-lock.py`, and the local bridge-artifact location. The task's command output and per-case logs were not retained in the supplied record or available task artifacts. The scripts already emit phase totals and lock waits; the missing data is the **task-specific output record**, not proof that those events are never logged.

## Actionable improvements

1. **Keep protocol-fixture edits out of the app build key when they are not build inputs.** The fixture-only repair caused a fresh ~131 s build before a 2.297 s focused case. `scripts/prepare-e2e-build.py` hashes tracked files except an explicit exclusion set; `scripts/fixtures/claude-code-fixture.py` is hashed, while the Xcode project does not reference that fixture. Add this fixture path to the excluded test-runtime inputs after confirming it is not copied by another build phase. Verify with `--fingerprint-only` before/after a fixture-only edit and show a subsequent focused run reuses the app build while executing the changed fixture. The observed upper bound on avoidable cost in this retry is about 131 s.

2. **Route fixture responses by the latest user request when replay context is present.** The first full suite failed because the recovered prompt contained an earlier `story` and the fixture selected that branch ahead of the new `What happened earlier?` request. The correction put the final-request branch first; that failure required a fixture edit, focused retry, and final full run. Make the fixture parse the current request after the handoff-context delimiter before choosing its response, and add a cheap fixture-level assertion for a replayed `story` plus a different current request. Verify that the fixture returns the current-request response without a full suite failure. The observed retry path cost at least ~296 s of timed build/case work (131 s build, 2.297 s focused case, ~163 s final full cases); only the portion avoided in a future incident can be established by comparison.

3. **Retain task-scoped timing output at verification handoff.** The ledger preserves coarse build and suite times, but lacks the emitted `E2E phase=...` lines, `E2E total_seconds`, lock-wait lines, and per-case full-suite durations. Capture the three invocation outputs or artifact paths in the per-task verification ledger, plus timestamped phase start/end for implementation and reviews where available. Verify that a future report can reconcile each invocation total to phase totals and rank full-suite cases without searching unrelated runs. This targets a specific missing measurement; the shell runner already emits phase and total times, so new runner logging is not the first step.
