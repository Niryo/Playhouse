# Make Questions Nonblocking Across Conversations

Task: `BD1B15FA-4F04-490E-B701-E295B5F90C7F`
Client date: 2026-10-26

## Observed timeline

This is a partial timeline. The task start, implementation intervals, static review start/end times, user response wait, and handoff time were not captured in the supplied task record. Their durations are unknown; the known command times below are tool/runtime wall time, not active agent time. The order comes from the task conversation and verification ledger supplied by the implementation agent.

| Order | Operation | Observed wall time | Evidence |
| --- | --- | ---: | --- |
| 1 | Initial implementation and static review; reviewers identified missing Claude coverage and fixture validation; user authorized a deterministic Claude protocol fixture | Unknown | Task conversation and review summary |
| 2 | Fixture and paired coverage added; next static review identified malformed response handling and missing Claude failure coverage; repairs followed | Unknown | Review summary |
| 3 | Full CLI/XPC run: 74 cases, two Claude failures because the fixture emitted success before `control_response` | ~330 s total; ~150 s build, ~177 s cases, ~3 s other | Captured `scripts/test-e2e.sh` phase and result summary; components are rounded |
| 4 | Fixture lifecycle repair and affected static reviews, all cleared | Unknown | Review summary |
| 5 | Focused Claude answer case passed | ~146 s total; ~141 s build, ~2 s case, ~3 s other | Captured runner phase summary; components are rounded |
| 6 | Focused empty-question case passed | ~4 s total | Captured runner summary |
| 7 | Final full CLI/XPC suite passed: 74/74 cases, zero skipped; parity, Python compile, Swift parse, and diff checks passed | ~168 s total for full suite; separate static-check times unknown | Captured verification summary |

The four timed suite invocations account for about **648 s (10 min 48 s)** of observed runtime. At least ~291 s was build time (45% of that observed runtime), from the failed full run and first focused retry. The known case phases account for ~179 s; the other focused run and final full run lack a phase breakdown in the supplied record. Total task wall time and active agent time cannot be reconciled to 648 s because the other intervals have no timestamps. No UI suite ran in routine verification, as required by this repository's gate.

The slowest observed operations were the failed full run (~330 s), final full run (~168 s), first focused retry (~146 s), and second focused retry (~4 s). Named case timings cannot be ranked from the retained summary. `scripts/test-bridge.py` emits per-case `E2E case=... elapsed_seconds=...` records and `scripts/test-e2e.sh` saves them to its printed `bridge-tests.log` artifact path, but the complete artifact path and log were not retained in the supplied task record. The repository runner therefore produces this measurement; its absence here is an evidence-retention gap.

## Improvements

1. **Preserve the existing case timing artifact in the task verification ledger.** The 74-case failed run cost ~330 s, but the retained summary cannot identify the slowest case or separate the final run's build and case phases. Record each run's printed artifact path, `E2E phase` lines, and the slowest `E2E case` lines in the ledger before the temporary path is lost. Verify on the next source task that every full or focused run can be ranked by named case and its phase totals reconciled to `E2E total_seconds`. This uses the runner's existing telemetry; no new emitter is needed.

2. **Check the fixture's response boundary before the first full suite.** The fixture sent terminal success before Claude's `control_response`, causing two failures after ~330 s of full-suite runtime. Add a focused protocol assertion for the fixture path that verifies no terminal result is emitted until the response arrives, and run that assertion after fixture edits while preserving the required static-review barrier and final full-suite gate. Verify impact by confirming the next fixture lifecycle error is caught in the focused path; the potential saving for a repeat of this failure is the ~330 s failed full run. The fixture protocol error is observed; whether the proposed assertion would catch every similar error needs validation.

3. **Expose build-cache cause in the verification ledger.** A single focused retry took ~141 s to build and ~2 s to execute. `scripts/prepare-e2e-build.py` fingerprints source and toolchain inputs and reports cache hit or miss, but the retained summary does not include that result. Record its cache hit/miss line with the build fingerprint alongside each suite's phase times. Verify the next retry explains whether a source change required its rebuild and whether later retries reuse the matched build. This makes the large build share diagnosable without changing the mandatory build or test gate.

## Evidence checked and limits

Checked the supplied task conversation and review/verification summary, current unstaged file scope, `scripts/test-e2e.sh` phase/artifact output paths, `scripts/test-bridge.py` per-case timer, and `scripts/prepare-e2e-build.py` cache fingerprint path. The complete command transcripts, per-case logs, task progress event timestamps, and static reviewer start/end timestamps were unavailable to this report. The repository scripts do emit the test timings; the report makes no claim that the system lacks them. No earlier workflow reports were read.
