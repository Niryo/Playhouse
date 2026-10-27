# Persist the Last Selected Model

Task: `622F9AEC-71C2-4E79-9AC9-B56855EA77DC`  
Client date: 2026-10-26 (Asia/Jerusalem)

## Observed timeline

This is a partial timeline. The task request and completion were reported, but their timestamps were not retained in the supplied record. The verification ledger, conversation summary, runner source, and repository search supplied the events below. File modification times were inspected but do not establish the start, end, or active duration of editing.

| Phase | Duration | Basis |
| --- | ---: | --- |
| Request, context gathering, implementation, and paired CLI/UI coverage | Unknown | Task report describes SwiftData task state, XPC/CLI model get/set, UI restoration and commit, provider-specific storage, and two paired cases; no phase timestamps. |
| Initial static parity and reviews | Unknown | Parity passed 72 cases; task and UI reviewers approved; architecture approved. Review start/end and wait times were not supplied. |
| First full runtime attempt | About 20 s, estimate | Supplied verification ledger; build stopped before any case because `ConversationManager.isValidModelID` was inaccessible. No cases ran. |
| Repair and affected reviews | Unknown | Helper visibility was repaired and shared; task and architecture reviews were reopened and approved. UI approval was retained because its inputs were unchanged. No repair or review timestamps. |
| Final `scripts/test-e2e.sh`: build | 130 s, runner phase total | Full run output supplied in ledger. |
| Final `scripts/test-e2e.sh`: cases | 160.170 s, reported case runtime | 72/72 inner CLI/XPC cases passed, with zero skipped. This aggregate may differ slightly from the runner's integer `cases` phase because it sums per-case durations. |
| Final `scripts/test-e2e.sh`: other time | About 2.83 s, derived | 293 s total less 130 s build and 160.170 s case runtime; includes static checks, fixture preparation, runner overhead, rounding, and any lock wait that the supplied totals cannot separate. |
| Reporting and handoff | Unknown | No timestamps supplied. Routine verification did not execute UI tests or take screenshots. |

The final full run took 293 s measured: build accounts for about 44.4%, cases for about 54.7%, and the derived remainder for about 1.0%. The two observed runtime attempts total about 313 s, using the estimated first attempt. Total task wall-clock time and active agent time cannot be reconciled because request, editing, review, retry, and completion timestamps are unavailable. Tool/runtime wait is measured only for the final run; user or agent gaps are not counted as active work.

The runner prints `E2E phase=... elapsed_seconds=...`, `E2E total_seconds=...`, and a per-case `elapsed_seconds` line. Only partial per-case lines were retained in the supplied evidence, so individual cases cannot be ranked. The slowest supported operations are the 160.170 s aggregate case execution and 130 s build; neither is an individual case.

## Practical improvements

1. **Capture the existing per-case output with the verification ledger.** The final suite spent 160.170 s in cases, but the partial retained output prevents identifying which cases dominate or whether any setup repeats disproportionately. Save the task-specific `bridge-tests.log` artifact path and its full per-case timing lines in the ledger for future runs. Verify by checking that every executed case has one retained duration and that their sum can be compared with the runner's cases phase. This uses timing already emitted by `scripts/test-bridge.py` and `scripts/test-e2e.sh`; no new instrumentation is needed.
2. **Check Swift access control at the static review boundary when sharing a helper across types.** The first build stopped before tests on the visibility of `ConversationManager.isValidModelID`, costing about 20 s of runtime plus unmeasured repair and repeat review time. Add an explicit cross-type visibility check to the relevant static review for such edits. Verify over later tasks by counting build attempts that fail on access-control diagnostics; the target is zero. This addresses the observed failure without changing the required full runtime gate.

## Evidence limits

- Checked the supplied task conversation summary and verification ledger, repository source for both runners, repository search for a task-specific ledger or log, and current file metadata. No complete task-specific test log or progress timestamp series was available here. This does not imply the system never emitted them: the runner visibly emits both phase and per-case timing, and writes a `bridge-tests.log` under its temporary artifact directory.
- The exact unobserved intervals are request to first build, static review and queue waits, repair and reopened reviews, and final run to handoff. A task-specific progress timeline or timestamped verification ledger would be needed to measure them. The case ranking requires the complete `bridge-tests.log` from this run.
- Final reviewed unstaged fingerprint: `3816ee2e4bc96db30bb9bc68e72dac7da51ac2aa44fda4dd311335923956d1f9`; the ledger reports it unchanged before and after runtime.
