# AFC28347 — Render Active Runs as Single-Line Truncated Text

## Observed timeline

The available task record has no task-start or task-end timestamp. These phases are in observed order; intervals without a duration are **unknown**, not zero. The implementation changed the compact active-process row in `TaskConversationView.swift`, then extended the paired bridge/UI contract and a long-command fixture.

| Phase | Evidence | Elapsed | Time type |
| --- | --- | ---: | --- |
| Planning, repository inspection, implementation | Task progress summary and unstaged diff | Unknown | Active work and gaps cannot be separated |
| Initial parity/static review | Task progress summary: parity passed; static review rejected the inadequate long-command fixture | Unknown | Review and repair time unavailable |
| Fixture/UI revision and static approval | Task progress summary: revised fixture and UI assertions approved after correcting the legacy-row versus command-row assertion | Unknown | Active work and review wait unavailable |
| First full CLI/XPC run | Supplied verification ledger: failed on reused fixture item ID | **340 s** | Measured wall time; build **151 s** included |
| Fixture repair and focused retry | Supplied verification ledger: failed on legacy dynamic duration assumption | **158 s** | Measured wall time; cache-miss build approximately **154–157 s** included |
| Duration repair and focused retry | Supplied verification ledger: passed with reused build | **4 s** | Measured wall time |
| Final full CLI/XPC run | Supplied verification ledger: **86/86 passed** with reused build | **184 s** | Measured wall time |
| Reporting/handoff | No timestamped completion signal supplied | Unknown | Elapsed unavailable |

**Observed CLI/XPC wall time:** 686 s (11 min 26 s). The two failed runs account for 498 s (73%); the final full run accounts for 184 s (27%). The two reported builds account for approximately 305–308 s (44–45%) of observed run time, and are included in run totals. This is a **partial lifecycle timeline**: total task duration, phase totals outside CLI/XPC runs, active agent time, review waits, and gaps cannot be reconciled without task-start/end and operation timestamps. No per-case output was supplied, so the slowest named case cannot be ranked; the slowest observed operation is the first full run (340 s), followed by the final full run (184 s).

## Improvements

1. **Remove runtime-only fixture files from the Xcode build key after validating inputs.** The first build took 151 s; a changed fixture/test tree caused another approximately 154–157 s build before the 158 s focused retry, although the failed assertion was in a Python fixture/runtime test. `scripts/prepare-e2e-build.py` hashes tracked files broadly; it already excludes `scripts/test-bridge.py`, but includes `scripts/fixtures/codex-app-server-fixture.py`. Confirm that the fixture is absent from Xcode build inputs, then exclude that exact runtime fixture path from the build fingerprint while retaining its runtime execution from the current tree. Verify by editing only the fixture in a disposable task tree and checking that the build key stays stable, the runner reports a cache hit, and the focused case observes the edited fixture. This could save roughly 2.5 minutes per fixture-only retry in a warm cache; UI test Swift changes still require a build.

2. **Check fixture event identity and timing consistency during static verification.** The first full run failed after 340 s because the new command reused a fixture ID; the next focused run failed after 158 s because an older dynamic call's duration assumption no longer held. The static review had already found inadequate long-command data and one incorrect UI row assertion, so this fixture was being revised across several related expectations. Add a small fixture validation step to the existing parity/static check that detects duplicate started item IDs, completion references to missing starts, and explicit duration expectations lacking matching completion data for this fixture. Verify it rejects the two recorded fixture defects before a build and accepts the corrected fixture. The observed failed-run cost was 498 s; the share preventable by the check is unmeasured because repair and build-cache effects overlap.

## Evidence and telemetry gap

Checked the supplied task progress/verification ledger, current unstaged diff, `scripts/test-e2e.sh`, `scripts/test-bridge.py`, and `scripts/prepare-e2e-build.py`. The runner already emits phase totals, total time, and per-case durations; the build helper emits cache-hit/miss and lock wait. The task record did not retain those full command outputs, and no task-specific local log was supplied, so per-case ranking, exact phase breakdown, and lock wait are **inaccessible for this task**. Preserve the existing runner output with the task verification ledger before adding new timing instrumentation. Task activity and review timestamps would be needed to distinguish active work from waiting and to calculate end-to-end elapsed time.
