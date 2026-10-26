# Model picker knob visibility and same-family version dedupe

Task: F7BA0B0A-B0F5-4B3F-9675-47A0D63B874B, "Add Model Effort Selection" (follow-up turn).
Requests: (1) effort slider knob must always be visible; (2) keep only the newer model per family (gpt-6-luna over gpt-5.6-luna).

Timeline status: **partial**. The follow-up turn's start and end are not recorded. Only the runtime suite has measured wall-clock timestamps. Checked: brief-supplied evidence and a live recomputation of the unstaged diff fingerprint (matches db2604e949699502 at 10:18:37).

## Durations

| Phase | Duration | Basis |
|---|---|---|
| Full CLI/XPC suite (`scripts/test-e2e.sh`) | 293 s (10:13:16 to 10:18:09) | Measured from timestamps |
| Per-case execution inside suite | 160 s (about 55% of suite wall clock) | Measured, reported by suite output |
| Suite overhead (builds, fixtures, teardown) | about 133 s | Derived (293 minus 160); not broken out |
| Static review agent, each | about 85 to 180 s | Measured, agent usage metadata |
| Static round wall clock | not recorded; at most about 180 s | Estimate: agents run in parallel, bounded by the slowest |
| `scripts/run.sh` builds (4 total) | not recorded | Telemetry gap |
| Parity checks (`check-test-parity.py`) | not recorded | Telemetry gap |
| Repair time between rounds | not recorded | Telemetry gap |
| Total follow-up turn elapsed | unknown | No start signal |

The largest measured item is the 293 s suite. Its per-case share is the only reliable breakdown. No per-case ranking beyond the 160 s total is available in the brief.

## Verification ledger

| Fingerprint (git diff sha256) | Phase | Reviewers | Result | Notes |
|---|---|---|---|---|
| abe0916b9a56e5c6 | Static 1 | task, UI, architecture | Task REJECTED; UI REJECTED; architecture APPROVED with concerns | Knob not covered and not visually testable; new case not wired to Codex fixture; neighbor case had the same gap; retained-family asserts missing |
| 99d3d4472ba2078a | Static 2 | task, UI, architecture | Task REJECTED; UI REJECTED; architecture APPROVED with CONCERN (retained) | Crash with a single effort choice; Claude coverage gap; Escape path; pointer step; neighbor fixture |
| cd21046de0e1892f | Static 3 | task, UI (architecture not reported) | Task REJECTED; UI REJECTED | Date rule not exercised; keyboard focus assumption; Escape not covered |
| df0b97461e9763e1 | Static 4 | task, UI (architecture retained with recorded reason) | Task APPROVED; UI APPROVED | Same-version alias/snapshot duplicates documented as non-blocking; UI medium-risk keyboard-focus note |
| db2604e949699502 | Runtime | main agent | 70 of 70 passed, 0 skipped, exit 0, 293 s | Single full run, no focused reruns; UI not run (Tart only); no screenshots |

Build and parity: all 4 `run.sh` builds compiled cleanly. `check-test-parity.py` passed 70 identical cases at every round.

Caveat: the knob's visual result is **unverified**. Runtime and static gates passed, but agents could not capture screen output, and the repo cannot assert knob opacity through XCUI.

## Findings

1. **Knob fix missed.** The first fix (moving stop-marker dots from `.overlay` to `.background`) was reasoned without a visual check. The user still saw a transparent knob. Hypothesis, not proven: the macOS 26 translucent native slider knob, not the marker layering, is the cause. Cost: a user-reported miss after all gates passed; repair time unmeasured.
2. **Static rounds caught real gaps.** Blocking findings were a crash path, an untested visible control, an unexercised date rule, and untested Escape and keyboard-focus paths. Reviewer rejections: round 1 (2), round 2 (2), round 3 (2), round 4 (0). These rounds were worth their cost.
3. **Reviewer date reasoning was wrong twice** before a concrete trace settled it. This drove round 3's rejection.
4. **Parity checker caught annotation spacing drift early**, at low cost.

## Recommendations

1. **Visual check for styling fixes.** Evidence: finding 1, a user-rejected fix that passed static and runtime gates. Action: for visual-only changes, attach a screenshot of the knob region to the paired UI case, so the on-demand `$full-ui-verification` run gives visual evidence. Also check whether agents can be granted screen capture. Verify: the next styling fix has a screenshot artifact reviewed before the user sees it. Benefit: unmeasured; expected to remove this class of miss.
2. **Concrete traces for rule logic.** Evidence: finding 3, two wrong reasoning passes and one extra round. Action: add a table of sample model IDs and dates (for example gpt-5.6-luna vs gpt-6-luna, plus same-version pairs) to the static brief, and require reviewers to trace each row. Verify: rule-logic rejections per task drop from round 3's level.
3. **Pre-review edge checklist.** Evidence: findings 2 (count of 1, Escape, keyboard focus, neighbor fixture) were predictable from the requirement. They took 4 static rounds and 6 rejections to surface. Action: before round 1, check item counts of 0, 1, and many; cancel and Escape paths; keyboard focus; and every neighbor fixture. Verify: rounds to first task approval (this task: 4) and rejections per round.
4. **Measure phases.** Evidence: no per-phase wall clock for builds, parity, static rounds, or repair. Action: first check whether `scripts/run.sh` and `scripts/test-e2e.sh` already write timestamped logs (not checked in this audit). Only if they do not, add a phase log with start and end times. Verify: the next report has measured, not estimated, build and static-round durations.

## Telemetry gaps

- Follow-up turn start and end: missing.
- Build, parity, static round, and repair durations: missing.
- Per-agent durations: measured, but only from usage metadata.
- Suite overhead split (build vs fixture vs teardown): missing.
- UI runtime: not run, so no UI timing exists.
