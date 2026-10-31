# Workflow Improvement Report — Ghost "Deleted" Entry Fix

Task: "Redesign Sidebar Changes as Viewed and Unviewed" (F543169F-AC84-4A27-A7C7-6FF0FE87E1DF)
Scope: this turn only — fixing a permanent phantom "deleted" Viewed row for a file that was created fresh, marked viewed, then renamed via two filesystem operations (delete + create, not `git mv`), leaving a zero-net-change path stuck forever under Viewed.

This is a partial timeline: only the activity visible in this turn's conversation and the measurements explicitly supplied are covered. No task-start/end timestamps for this specific turn were retained beyond the ledger below, so wall-clock totals are reconciled only where measured durations were given.

## Timeline (measured where stated, estimated where flagged)

| Phase | Duration | Source | Confidence |
|---|---|---|---|
| Root-cause diagnosis (hand-tracing code logic to infer the user's actual click sequence from an incomplete bug report) | Not measured | Conversation narrative only | Gap — see below |
| Fix implementation (guard condition in `WorkspaceChangeScanner.inventorySynchronously`) | Not measured | Conversation narrative only | Gap |
| Test extension (CLI case in `scripts/test-bridge.py` + paired UI case, ephemeral.txt scenario) | Not measured | Conversation narrative only | Gap |
| Static round 1 — task_verifier (background) | Not retained | Supplied ledger explicitly flags this as ungathered | Confirmed gap |
| Static round 1 — architecture_reviewer (foreground/sequential) | ~94s | Supplied ledger | Measured |
| Static round 1 — ui_verifier (background, against pre-fix code) | ~210s | Supplied ledger | Measured |
| Repair (add missing `|| snapshot.isPresent` disjunct) | Not measured | Conversation narrative only | Gap |
| Static round 2 — task_verifier re-review | ~85s | Supplied ledger | Measured |
| Runtime — focused case | 8.5s cases / 174s total (incl. build) | Supplied ledger | Measured |
| Runtime — full suite | 232s cases / 236s total | Supplied ledger | Measured |

Total measured runtime+review wall time from the figures given: roughly 94 + 210 (parallel, so wall time is max(94,210)=210, not sum) + 85 + 174 + 236 ≈ 705s for everything after implementation was ready. The pre-implementation diagnosis and coding phases have no timing data at all — this is a genuine blind spot, not an assumed zero.

## Findings

### 1. task_verifier's static-round-1 duration was not retained, even though it produced the turn's single most consequential finding
Evidence: the ledger explicitly states "(~? measure not retained — note as gap)" for the review that caught the first guard draft (`baseBytes != nil || fileExists`, missing `snapshot.isPresent`) would have suppressed a not-yet-reviewed pending deletion — a regression in the fix itself, not a style nit. The two reviews running in parallel with it (architecture_reviewer, ui_verifier) both have timings; task_verifier does not.
Likely cause: duration for the review that triggers a repair round seems to not get written back into the ledger at the same point its verdict does, while reviews that return APPROVED get both verdict and timing recorded together in the same message.
Action: when a static reviewer rejects, capture its elapsed time in the same ledger update as its verdict, not only when it approves. Verify by checking the next rejection round's ledger entry has both a verdict and a duration recorded in one place.

### 2. A reviewer nearly produced a false rejection from a stale/truncated diff view, not from the actual defect
Evidence: ui_verifier initially misread a truncated diff hunk as "fix missing" during static round 1, then self-corrected by re-reading the live file before returning APPROVED (~210s). The self-correction worked this time, but it was not guaranteed — the review runs against a diff snapshot rather than guaranteeing a live-file read when the diff is ambiguous or truncated.
Likely cause: the diff passed to this reviewer is generated once at dispatch time and may be truncated for large or multi-hunk files; the reviewer's fallback to the live file is self-initiated, not a required step.
Action: when a review's input diff is truncated or a hunk boundary is ambiguous, require the reviewer to read the live file for that path before returning a verdict, rather than relying on the reviewer noticing the discrepancy on its own. Verify by re-running a static review with a deliberately truncated diff and confirming it reads the live file rather than returning a verdict directly from the truncated hunk.

### 3. Diagnosing this bug required inferring the user's click sequence purely from code-logic constraints, with no timing or confirmation step captured
Evidence: per the conversation, the user's own description of the repro steps was incomplete/ambiguous, and the actual sequence (mark-viewed clicked twice — once while the file was present, once after it became a pending deletion) was inferred by hand-tracing what the screenshot's badge values implied about the stored snapshot state, without a round-trip to confirm with the user.
Likely cause: no existing source captures user click sequences or UI interaction order outside of what the user manually reports; this is not a logging gap in Playhouse's own event pipeline so much as an absence of any interaction trace to cross-check against. This cost is real but currently unquantifiable from any available telemetry — it is not a case of looking in the wrong place, it's that no source among the conversation, verification ledger, or repository telemetry emits UI click-order events today.
Action: no new telemetry is proposed here since no concrete producing component was identified or verified for this specific signal (this would require a UI-side interaction logger, which is out of scope for a single bug fix and not confirmed absent from every possible source). Flag this as a recurring diagnostic cost worth tracking across tasks: when future bug reports in this same Viewed/Unviewed area recur with ambiguous repro steps, that recurrence itself would be the evidence needed to justify adding a lightweight interaction-order log for this feature area specifically.

## Cross-task pattern (observed again this turn, not new)
Per the supplied ledger, this is the second time in this task that a static reviewer caught a real implementation defect in a fix meant to address an earlier reviewer's or user's finding (the first guard draft missing `snapshot.isPresent`). Combined with similar notes in this task's earlier reports, fixes-to-fixes in this feature area appear to have a higher defect rate than first-pass implementations. This is consistent with findings 1 and 2 above: the repair round is exactly where ledger timing is thinnest and where a reviewer's diff view is most likely to be stale relative to the just-edited file.
