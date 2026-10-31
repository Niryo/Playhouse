# Standalone chat page classification fallback

Task: `1D69A6C9-61B0-4731-A4A5-FE5E20692E08` — Plan Standalone Chat with Context Pages. Client date: 2026-10-29.

## Observed timeline

The available record starts with implementation and review of the fallback classifier; it does not timestamp the first task activity or final handoff. This is a partial timeline. Phase durations below are unknown unless stated.

| Order | Phase and evidence | Duration |
| --- | --- | --- |
| 1 | Implemented background Haiku/Luna classification, strict result validation, durable pending page/turn state, send guard, UI title/warning, and paired provider cases. Evidence: task conversation and 11 unstaged source/test files. | Unknown; no start/end timestamps available. |
| 2 | Static task, UI, and architecture reviews approved fingerprint `fd71…`. A subsequent UI compile exposed a duplicate composer declaration; it was repaired and affected reviews refreshed at `aedc…`. Evidence: task handoff/review record. | Unknown. |
| 3 | First full E2E invocation stopped on compile errors before any case ran. Evidence: task handoff. | Unknown. |
| 4 | Next full E2E run built and reached the bridge cases; `test_standalone_chat_hidden_task_and_pages_round_trip` failed because the fixture did not stream the helper response. Evidence: task handoff/test output summary. | **330 s measured** for the invocation. |
| 5 | Focused repair and retry cycle: streamed helper response, executable override propagation, fixture releases, distinct turn IDs, status recovery, latest-message matching, and a dedicated hold marker. Evidence: task handoff and current fixture/test changes. | Multiple focused runs; individual count and durations unavailable. |
| 6 | Final focused case passed; final full CLI/XPC suite passed 89/89 with zero skips. Parity check passed 89 identical cases; `git diff --check` was clean. Evidence: task handoff/test output summary. | **8 s measured** focused; **176 s measured** full. |

The three reported suite invocations total **at least 514 s** of observed runtime. The failed 330 s run accounts for about 64% of that measured subset; the successful full run accounts for about 34%. These are not shares of total task time: build failure, other focused retries, implementation, review, and communication have no supplied durations. No UI suite or screenshots were run under the routine verification policy.

## Findings and actions

1. **Exercise the classifier fixture protocol before the full suite.** One full invocation consumed 330 s and failed when the fixture omitted the streamed helper response. The focused case later passed in 8 s after fixture repairs. Add a small fixture protocol check to the existing focused standalone-chat case or its fixture preparation, covering streamed helper output, hold/release, and unique turn IDs. Run that focused case before the next full suite when its fixture protocol changes. Verify impact by recording whether the first full suite reaches and passes this case without fixture-only repairs; do not bypass the required final full suite.
2. **Keep fixture process settings together across every follow-up call.** The repair cycle repeatedly addressed executable override propagation and explicit release/status recovery, indicating that one scenario's related CLI invocations could use different fixture settings. Add a case-local helper that carries the fixture executable and marker paths through send, status, and recovery calls. Verify it by checking that each related invocation uses the same isolated fixture configuration and that the case passes on its first focused retry after a product change.
3. **Catch duplicate UI declarations before review refresh.** A duplicate composer declaration caused a compile failure after static approval and required repair plus renewed review. Before submitting a UI edit for static review, inspect declarations in the edited view scope and run the existing compile-producing build step when the static gate allows it. Verify by tracking compile failures caused by duplicate declarations in subsequent UI changes. The time cost for this incident was not recorded.

## Evidence limits

Checked the supplied task conversation/handoff, current unstaged status, the suite runner (`scripts/test-e2e.sh`), and repository searches for a task ledger or retained test log. The runner emits phase and total seconds and writes `bridge-tests.log` under a temporary artifact directory, but the task-specific log path and per-case duration output were not supplied or found in this worktree. The CLI exposes progress publishing but no progress-read command in `PlayhouseCLI.swift`. To reconstruct the missing intervals, retain the invocation output with its artifact path and timestamped review/progress events in the task record; first check existing bridge log and suite phase lines before adding new timing instrumentation.
