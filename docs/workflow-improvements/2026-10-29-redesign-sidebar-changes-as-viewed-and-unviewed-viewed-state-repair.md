# Workflow report: Redesign Sidebar Changes as Viewed and Unviewed — viewed-state repair turn

- Task: Redesign Sidebar Changes as Viewed and Unviewed (Playhouse task `F543169F-AC84-4A27-A7C7-6FF0FE87E1DF`)
- Date: 2026-10-29
- Scope: this turn only (the untracked-file re-edit regression and its repair). Two earlier reports dated 2026-10-29 cover prior turns of the same task and are untouched.

## What this turn changed

Working-tree delta at report time (`git diff --stat`, measured): 9 files, 541 insertions / 328 deletions, concentrated in `Playhouse/App/WorkspaceChanges.swift` (306 lines changed), `Playhouse/PlayhouseUITests/PlayhouseUITests.swift` (210), and `scripts/test-bridge.py` (183).

Behavior: `WorkspaceChangeScanner.inventorySynchronously` now compares each entry against its saved snapshot (bytes plus existence) and returns re-edited files to Unviewed; `WorkspaceChangeEntry.hasViewedSnapshot` drives the diff baseline label; `diffSynchronously` prefers the saved snapshot baseline; `captureViewedChange` stages via `git add --all` at the user's explicit request.

## Timeline (measured where the ledger recorded a duration; otherwise marked)

| Phase | Duration | Source |
| --- | --- | --- |
| Context gathering, diagnosis, implementation | not measured | no per-step timestamps retained; see telemetry gaps |
| Static phase 1 (3 reviews in parallel) | ~207s task_verifier APPROVED, ~100s ui_verifier REJECTED (3 findings), ~130s architecture_reviewer CONCERN — wall clock ≈ 207s | verification ledger (measured per-agent) |
| Repairs for UI findings | not measured | — |
| ui_verifier re-review | ~206s APPROVED | ledger |
| Runtime run 1 (full CLI/XPC suite) | 391s total, 234s of cases, 91/92 | ledger / suite output |
| Diagnosis + repair of the XPC trap | not measured | — |
| Static re-reviews (task + architecture) | ~206s APPROVED, ~100s CONCERN — wall clock ≈ 206s | ledger |
| Runtime run 2 (focused case) | 162s total, 4s of cases, green | ledger |
| Runtime run 3 (final full suite) | 231s total, 228s of cases, 92/92 | ledger |

Measured review + runtime total: ≈ 207 + 206 + 391 + 206 + 162 + 231 ≈ **1403s (~23 min)** of gated wall clock, of which **466s (~33%)** is CLI/XPC case execution and **~310s (~22%)** is build/setup overhead inside the three runtime invocations (391−234, 162−4, 231−228). Implementation and diagnosis time is not included because no timestamps exist for it; the timeline is therefore **partial** — no task-start or task-end signal is recoverable, and the gap between phases is unknown rather than zero.

A session restart mid-task killed one in-flight background static review, which had to be rerun at ~207s. That 207s is measured rework, not progress.

## Slowest observed operations

1. Full CLI/XPC suite, two runs: 391s + 231s = 622s (44% of measured gated time).
2. Static reviews, five agent invocations: ~849s of agent time, ~513s of wall clock after parallelism, including the 207s restart-lost rerun.
3. Build/setup inside runtime invocations: ~310s across three runs; the focused 4s case cost 162s because 158s of it was build.

## Findings and recommendations

### 1. The runtime failure class was not reachable by any static review, and the cheapest detector was a 4s case

Observed: three static reviews (~440s of agent time before the first runtime run) all passed the change, then the full suite failed at `test_task_workspace_changes_group_staged_and_unstaged_diffs` with `service_unavailable`. Cause: `git status --porcelain=v1 -z --untracked-files=all` emitted two records for one path (staged deletion followed by untracked recreation), and `Dictionary(uniqueKeysWithValues:)` traps on the duplicate key. Cost: 391s to surface a defect that the focused case reproduces in 4s of case time. The same crash shape existed in two files (`WorkspaceChanges.swift` and `BridgeCore.swift`), so it was a pattern, not a one-off.

Action: when a change touches `git status --porcelain` parsing or any `Dictionary(uniqueKeysWithValues:)` / `Set` construction over path keys, run the directly affected workspace-changes cases with `scripts/test-e2e.sh --case <id>` before launching the static review batch. The repository already permits cheap checks during implementation ("The main agent may run cheap parity/static checks during source implementation"); a focused case on the file you just rewrote is the same class of check. Verify impact: the next workspace-changes task should show its first full-suite run green, with any trap-class failure appearing in a focused run that costs ~160s instead of ~390s.

Secondary, in the same root cause: `uniqueKeysWithValues` over parsed Git output is a latent trap wherever it appears. A one-line grep gate (`grep -rn 'uniqueKeysWithValues' Playhouse/App`) in the pre-review checklist would have flagged both sites in under a second. This is cheaper than asking a reviewer agent to notice it, and reviewers demonstrably did not.

### 2. Build overhead dominates focused reruns

Observed: the focused rerun spent 158s of 162s on build and 4s on the case. Across the three runtime invocations, ~310s (~22% of measured gated time) was build/setup. The repository already caches builds per worktree and content/toolchain hash, so this was a genuine rebuild after a source repair, not a cache miss to fix.

Action: none that changes the rule — the rebuild is required. The useful change is sequencing: batch all repairs from one runtime failure into a single edit before rerunning, so each ~158s build amortizes over every fix. This turn already did that (both `uniqueKeysWithValues` sites plus the `deleted`→`modified` correction plus the new assertion landed in one pass), which is why only one focused rerun was needed. Recording it here so the pattern is explicit rather than incidental.

### 3. Background static reviews are lost on session restart with no resume path

Observed: one in-flight static review was lost when the session restarted mid-task and was rerun at ~207s — measured, fully avoidable rework and ~15% of the turn's gated wall clock.

Action: record the review's input fingerprint and start time in the per-task verification ledger at launch, not only at completion. On restart, a ledger entry showing a launched-but-unfinished review with an unchanged fingerprint tells the main agent exactly which single review to relaunch, instead of relaunching on uncertainty. This does not weaken the static barrier; it makes the retained-approval rule in `AGENTS.md` ("retain other approvals only with a recorded explanation that their relevant inputs are unchanged") applicable after a crash, which it currently is not because the fingerprint is only written on completion.

### 4. Telemetry gaps (sources checked)

Checked: `scripts/test-e2e.sh`, `scripts/test-bridge.py`, `/tmp` artifact directories, the working-tree diff, and the supplied verification ledger.

- Per-case durations **are** emitted: `scripts/test-bridge.py:6293` prints `E2E case=<name> elapsed_seconds=<n>` and `scripts/test-e2e.sh` prints `E2E phase=` and `E2E total_seconds=`. The gap is retention, not production — both go to stderr, and the artifact directory is a fresh `mktemp -d /tmp/playhouse-bridge.XXXXXX` per run with no stable index. Ranking the slowest cases across runs therefore requires scraping a live transcript, which is why this report can only give suite totals and not a per-case ranking for the 92-case runs.
  - Smallest next step: have the `cleanup` trap in `scripts/test-e2e.sh` append one line per run (`timestamp, case count, total_seconds, case_seconds, exit_status`) and the collected `E2E case=` lines to a fixed path such as `/tmp/playhouse-bridge-history.log`. Verify impact: the next workflow report can name the three slowest contract cases with measured numbers instead of declaring the data unavailable.
- Implementation and diagnosis intervals have **no** source at all. Nothing timestamps the boundary between "user reported the bug" and "edit applied". This report labels those intervals unknown rather than estimating them. Resolving it would require the task card or conversation record to carry per-turn start/end timestamps; that producing component was not verified in this turn, so no file or owner is named.

### 5. Architecture CONCERN carried to completion, deliberately

The architecture reviewer flagged (both rounds) that `captureViewedChange` writes the Git index from an otherwise read-only scanner. This was retained as a documented CONCERN because the user explicitly asked for `git add --all` staging. Recording it so a future turn that revisits the scanner's read-only contract finds the rationale rather than re-litigating it; no action proposed for this turn.

## Not recommended

No change to the required static-then-runtime ordering, suite scope, or parity gate is proposed. Parity held at 92 cases throughout, the final full suite was 92/92 with no skips, and no UI tests were run (correct for routine verification).
