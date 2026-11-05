# Model picker alias and slider follow-up

Task: `F7BA0B0A-B0F5-4B3F-9675-47A0D63B874B` (Add Model Effort Selection). Client date: 2026-10-25. This is a **partial timeline**: the supplied handoff records operation durations but no task start/end timestamps, review timestamps, or retained per-case output. Earlier turns of the same task are visible as requests and summaries without usable timing.

## Timeline and measured time

| Order | Operation and result | Duration | Evidence |
| --- | --- | ---: | --- |
| 1 | User requested newest concrete models only, removal of Default and aliases, and the original wide, borderless effort meter with an opaque knob. Implementation and paired assertions were changed. | Unknown | Conversation and handoff; no start/end timestamps |
| 2 | First static review: task and UI reviews rejected missing alias-only Claude UI coverage and visible focus-outline coverage. Changes were repaired; all three reviews later approved fingerprint `1bad8f…`. | Unknown | Supplied verification handoff; review waits not timed |
| 3 | First full CLI/XPC run: build, then 70 cases; model-list case failed because the alias-only fixture setting did not reach metadata calls. | 130 s build + 153 s cases = **283 s** | Supplied command outcome; measured phase durations |
| 4 | Fixture mode changed to use the copied executable name. Task and UI reviews refreshed and approved final fingerprint `34f530…`; architecture approval was retained because production files did not change. | Unknown | Supplied verification handoff |
| 5 | Focused failed-case retry: build and one passing case. | 129 s build + 3 s cases = **132 s** | Supplied command outcome; measured phase durations |
| 6 | Final full suite: cached build, 70 passing cases, no skips. | **155 s** cases; build/cache check time unreported | Supplied command outcome; measured case duration |
| 7 | Worktree app relaunched and PID 98178 confirmed. Routine UI tests and screenshots were not run. | Unknown | Supplied handoff |

The **observed measured command time is 570 s (9 min 30 s)**: builds 259 s (45%) and case execution 311 s (55%). This is a lower bound on the visible follow-up's wall-clock time, not a full task total. Static checks, code work, review waits, fixture repair, final app build/launch, communication, and gaps between operations are unmeasured. The slowest individually measured operations were the two builds (130 s and 129 s), then the final and initial full case runs (155 s and 153 s); the focused case took 3 s. Per-case timings beyond that focused case cannot be ranked from the retained evidence.

## Improvements

1. **Validate fixture variants during fixture preparation.** The alias-only Claude variant failed only after a 130 s build and 153 s full run. The setting was passed as an environment mode, but metadata calls did not observe it. In `scripts/prepare-e2e-fixture.py` or the suite's fixture setup, invoke each copied provider fixture through the same path used by metadata discovery and assert its expected model-list variant before the full cases begin. Keep the required full suite. Measure whether a broken fixture variant is then reported during setup rather than after the 70-case run.
2. **Retain existing per-case timing output with the task verification record.** `scripts/test-bridge.py` emits `E2E case=… elapsed_seconds=…`, and `scripts/test-e2e.sh` writes `bridge-tests.log` under a temporary artifact path. The current workspace has no retained logs from these runs, so the slowest of the 70 cases and review-to-runtime gaps cannot be reconstructed. Record the artifact path and copy the case timing lines plus `E2E phase` lines into the task verification ledger before the temporary environment disappears. On the next source task, verify that a report can rank individual cases and distinguish static, build, fixture, and case phases without adding new runtime logging.

Evidence checked: the supplied task conversation and verification handoff, repository status/diff, `scripts/test-e2e.sh`, `scripts/test-bridge.py`, `scripts/prepare-e2e-build.py`, repository progress model, and temporary artifact paths. The progress model stores the current report fields rather than a timestamped history; no task verification ledger or run logs were accessible in this workspace. These gaps describe the available task evidence, not a claim that the wider system never records the events.
