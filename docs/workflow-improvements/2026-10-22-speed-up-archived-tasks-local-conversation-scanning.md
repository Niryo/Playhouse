# Speed Up Archived Tasks: Local Conversation Scanning

Task: `D94D5E06-04C7-4FDA-9F61-339BE164471B`  
Date: 2026-10-22 (Asia/Jerusalem)  
Scope: the task's local conversation-file scanning continuation.

## Timeline and measured cost

| Sequence | Duration and evidence |
| --- | --- |
| Search and repository inspection identified the local conversation files and existing archive behavior | Start/end timestamps unavailable in the supplied continuation record; duration unknown |
| Implementation added Done-only SwiftData reads, local JSONL search with cancellation, CLI operation, and paired assertions | Duration unknown; current unstaged diff confirms six source/contract files changed |
| Initial static reviews found a need for a unique JSONL-only test marker, cancellation propagation for detached scans, and a Done-only query; repairs and affected re-reviews followed | Duration unknown; supplied review ledger records the findings but no timestamps |
| Final static gate | Task APPROVED, UI APPROVED with stated retained-approval rationale, architecture APPROVED at fingerprint `ae13a024b7ca71cfd6119cf70ecb38b91b6671c22a7604df888007e4dedb92a9` |
| Parity check | 56/56 passed; duration unavailable |
| One full CLI/XPC run | **164 s measured**: build 77 s, 56-case execution 85.074 s, about 1.9 s other runner phases; 56/56 passed, zero skipped, exit 0 |
| Handoff | Exact task completion time unavailable; runtime input fingerprint matched at start and end |

The **only measured elapsed total is 164 s** for runtime verification. Build is about 47% and the case phase about 52% of that run. The parent task's full wall-clock duration and active agent time cannot be computed: this continuation has no task-specific start/end timestamps or timed records for search, implementation, static review, or handoff. These intervals must not be treated as zero. The slowest *reported* operation is the 85.074 s aggregate case phase, followed by the 77 s build; individual case times were not supplied, so no slowest named-case ranking is supported. This continuation had no failed runtime run or retry.

## Improvements

1. **Retain existing per-case output with the verification ledger.** The full run spent 85.074 s across 56 cases, but the supplied ledger does not identify which cases dominated it. `scripts/test-bridge.py` already emits `E2E case=... elapsed_seconds=...` for each case, and `scripts/test-e2e.sh` writes those lines to a temporary bridge log. Record that artifact path and the five slowest case lines in the task ledger. Verify the next report can rank cases and attribute the case-phase time without another run.

2. **Measure archive performance at the affected boundary.** This performance task verified functional behavior with more than 40 Done records and local JSONL search, but supplied verification has no archive-open, page-fetch, or search latency measurement, so improvement size cannot be quantified. Bridge requests and SwiftData task-list reads already record `durationMilliseconds`; inspect those diagnostics first for archive search. The visible `loadNextArchivePage()` fetch has no duration event in the inspected source, so add a focused duration/count diagnostic there only if existing UI instrumentation cannot provide the interval. Verify with the same sized archive fixture before and after a future change, recording first-page and search latency separately.

3. **Preserve review and repair timestamps.** Three actionable static findings caused a repair cycle, but its time share is unknown because the supplied review ledger has outcomes without start/end times. Capture UTC timestamps for review-ready, each reviewer result, repair start/end, runtime start, and handoff from the existing conversation/tool timeline where accessible. Verify the next analysis can reconcile those phases with the task window and distinguish active work from waits.

## Evidence limits

Checked the supplied continuation ledger, current unstaged diff, `scripts/test-e2e.sh`, `scripts/test-bridge.py`, the relevant app search/page code, and accessible `/tmp` bridge-artifact paths. The full parent tool timeline and per-case output were unavailable to this optimizer; no task-specific `bridge-tests.log` was found in the accessible `/tmp` search. This is an accessibility gap for this report, not a claim that the runner omits timing. Routine verification did not run the visible UI suite; UI coverage received static approval.
