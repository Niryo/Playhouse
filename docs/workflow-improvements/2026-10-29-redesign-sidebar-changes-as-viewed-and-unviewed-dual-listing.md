# Redesign Sidebar Changes as Viewed and Unviewed — dual-listing turn

- Task: Redesign Sidebar Changes as Viewed and Unviewed (`F543169F-AC84-4A27-A7C7-6FF0FE87E1DF`)
- Date: 2026-10-29
- Scope: this turn only — the requirement change from "edited viewed file returns to pending" to permanent dual listing (pinned Viewed row at branch base -> snapshot, plus a re-listed row in the renamed "Changes" section at snapshot -> worktree).
- Changed files at report time (`git diff --stat`, unstaged): 9 files, 638 insertions / 317 deletions, concentrated in `Playhouse/App/WorkspaceChanges.swift` (339), `Playhouse/PlayhouseUITests/PlayhouseUITests.swift` (232), `scripts/test-bridge.py` (204), `Playhouse/App/TaskConversationView.swift` (99), `Playhouse/App/BridgeCore.swift` (53).

## Timeline

Only the verification phases carry measured durations (supplied verification ledger). Implementation, repair, and user-wait intervals have no retained timestamps and are marked unknown; they are not estimated here.

| Phase | Measured | Basis |
| --- | --- | --- |
| Requirement change intake, design, implementation | unknown | no per-phase timestamps retained |
| Static round 1 (parallel) | task_verifier 136s APPROVED; ui_verifier 96s REJECTED; architecture_reviewer 211s CONCERN (7 findings) | ledger per-agent durations |
| Repair cycle 1 (6 repairs) | unknown | no timestamps |
| Static round 2 (parallel) | architecture 94s CONCERN (4 repairs accepted, 3 deferred); ui_verifier 138s REJECTED; task_verifier re-review lost to session restart | ledger |
| Relaunch of lost task_verifier | ~157s (the round-3 run) | ledger |
| Repair cycle 2 | unknown | no timestamps |
| Static round 3 (parallel) | ui_verifier 170s APPROVED; task_verifier 157s APPROVED | ledger |
| Runtime: full CLI/XPC suite | 402s total, 237s of cases, 92/92 first run, no focused rerun | suite output |
| Parity | green at 92 cases throughout | `scripts/check-test-parity.py` |
| UI suite | not run — routine verification does not run UI tests | AGENTS.md verification scope |

Totals: reviewer agent time summed across the three rounds is 1002s. Because rounds ran in parallel, wall-clock review time is bounded by the slowest agent per round: ~211s + ~138s + ~170s = ~519s. Verification wall clock including runtime is therefore ~921s. Task wall clock is not reconcilable against this — the implementation and repair intervals between rounds are unobserved, so the timeline is **partial**: it has no measured start signal and no measured implementation span.

Slowest single operations: full CLI/XPC suite 402s (build included; 165s of that is build/setup, derived as 402 - 237), architecture_reviewer round 1 at 211s, ui_verifier round 3 at 170s.

## Findings and recommendations

### 1. A repair made for one reviewer's finding opened a coverage gap for another, costing a full extra static round

Evidence: round 2's ui_verifier rejection (138s) was not about the originally reviewed behavior. It was caused by a repair introduced in round 1 in response to the architecture reviewer — adding `porcelainCode(for:)` so snapshot rows badge their own status. That repair added a CLI assertion for the new pinned-status behavior with no paired visible assertion. Measured cost: the 138s rejection plus the entire round 3 (170s + 157s reviewer time, ~170s wall) plus an unmeasured second repair cycle.

Action: when a repair in response to any reviewer adds or changes a user-visible string, badge, status, or CLI assertion, record that in the repair note and reopen `ui_verifier` in the *same* round rather than treating its prior rejection-or-approval state as scoped to the original fingerprint. The existing rule already allows retaining approvals only with a recorded explanation that inputs are unchanged; the gap here is that a repair touching the visible surface was not recognized as changing `ui_verifier`'s inputs. Verify by checking, on the next multi-reviewer task, that no `ui_verifier` rejection cites behavior introduced by a repair from the preceding round.

### 2. Both UI rejections were vacuous assertions, not missing behavior — these are detectable mechanically

Evidence: round 1's rejection found two assertions that passed without exercising anything — a section-title lookup that collided with the sidebar pane header, and a filename identifier that matched two rows once dual listing made one path appear in both sections. Both are identifier-resolution defects created by the model change (`WorkspaceChangeEntry.id` now includes the group, so a bare filename is no longer unique). Measured cost: 96s + the repair cycle; the class recurred in round 2. The repairs were group-scoped filename identifiers and section-title identifiers.

Action: make UI element lookup helpers in `Playhouse/PlayhouseUITests/PlayhouseUITests.swift` assert a unique match — require exactly one matching element before acting or asserting, and fail with the match count otherwise. A duplicate or shadowed identifier then fails as a test failure at authoring time instead of surfacing as reviewer prose two static rounds later. Verify by deliberately asserting on a bare filename that now exists in both sections and confirming the helper fails rather than passing on the first row.

### 3. Second session restart in this task lost an in-flight background static review

Evidence: the round-2 `task_verifier` re-review was lost to a mid-task session restart and had to be relaunched, costing ~157s of reviewer time plus the serialization of round 3. This is the second occurrence within this task; a prior report in this task already recommended persisting review fingerprints at launch, so this turn is repeat evidence that the gap is unaddressed rather than a new finding.

Action (smallest next step): at the moment a static reviewer is launched, write the per-task verification ledger entry — unstaged change fingerprint, phase, reviewer name, launch time — to a file under the task's worktree, before the agent runs. On restart, read it back to learn which reviews were in flight and relaunch only those. This does not change what must be reviewed; it removes the need to reconstruct in-flight state from conversation memory that a restart discards. Verify by restarting mid-round on a future task and confirming the relaunch set is derived from the file.

### 4. Reviewer durations are retained but start timestamps are not, so parallel wall clock has to be inferred

Evidence: this report could compute per-agent durations (136/96/211/94/138/170/157s) from the ledger but had to *infer* wall clock per round as max-of-agents, because no launch or completion timestamps are retained. That inference is unverifiable — it assumes the agents in a round actually started together. The same gap makes it impossible to measure the repair cycles between rounds, which are the only unmeasured intervals in the whole verification sequence.

Action: record epoch start and end alongside each reviewer duration in the per-task verification ledger (same write as recommendation 3). That single addition makes both round wall clock and inter-round repair time measurable without any new instrumentation elsewhere. Verify by confirming the next task's report can state repair-cycle duration as measured rather than unknown.

## Telemetry gaps

- No task start/end signal and no implementation-phase timestamps: the timeline above is partial and cannot be reconciled against task wall clock.
- No repair-cycle timing: the two repair cycles in this turn are entirely unobserved.
- No per-case durations were supplied for the 92-case CLI/XPC suite; only the 237s case total and 402s overall were available, so the slowest *case* cannot be named. The 165s build/setup figure is derived by subtraction, not measured directly.
- The lost round-2 `task_verifier` run left no record of how far it had progressed before the restart, so its wasted time is a lower bound, not a measurement.

## Worth preserving

The runtime phase was clean: 92/92 on the first full run with no focused rerun and parity green at 92 cases throughout, despite a mid-task requirement change that rewrote the entry-identity model. The cost in this turn was concentrated entirely in static review rounds, not in test execution.
