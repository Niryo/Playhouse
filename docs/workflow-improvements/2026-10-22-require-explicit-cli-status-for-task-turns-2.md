# Require explicit CLI status for task turns: thread-scoped instruction follow-up

Task: `FC456E6F-947A-4D59-8519-8AE8BBB3980E`

Client date: 2026-10-22

## Observed timeline

This report covers only the follow-up request to keep progress and outcome instructions on the Codex thread. Times are UTC. Evidence checked: the supplied task conversation and verification ledger, the three task-specific bridge logs, `scripts/test-e2e.sh`, `scripts/prepare-e2e-build.py`, the current send/client path, and the live integration script. The earlier report was not read.

| Operation | Time or duration | Evidence and limit |
| --- | --- | --- |
| Request, discovery, implementation, static review | Start/end and active duration unknown | The first version passed instructions through `thread/resume` with a one-time `turn/start` fallback. Fingerprint `364c5399…` reached runtime. The conversation and ledger do not expose phase timestamps. |
| First full CLI/XPC run | **154 s command**, **69.778 s cases**; bridge lock acquired 14:18:31.696 | [First log](/tmp/playhouse-bridge.AstXoF/bridge-tests.log); 56 cases ran and `test_task_progress_reports_publish_persist_and_clear` failed (1.877 s). The remaining 84.222 s includes build/setup/overhead, but its components were not supplied. Lock wait was 0.000 s. Lock acquisition is not command start. |
| Repair and renewed static review | Duration unknown | The fallback was removed after a later turn repeated instructions. Final fingerprint `341e5a9c…`; task/UI reviewers approved; architecture recorded a concern about fresh clients and resume compatibility. Parity passed 56/56. Reviewer and edit timestamps were not retained in the supplied ledger. |
| Focused retry | **88 s command**, including **83 s build** and **2.546 s case**; bridge lock acquired 14:27:57.266 | [Focused log](/tmp/playhouse-bridge.tgNe6t/bridge-tests.log); 1/1 passed. The new source fingerprint caused a build cache miss; the remaining roughly 2.5 s is setup/overhead and rounding. Lock wait was 0.000 s. |
| Final full CLI/XPC run | **78 s command**, **75.421 s cases**; bridge lock acquired 14:28:09.750 | [Final log](/tmp/playhouse-bridge.Nc6Duk/bridge-tests.log); cached build reused, 56/56 passed, 0 skipped or failed. Remaining roughly 2.6 s is setup/overhead and rounding. Lock wait was 0.000 s. |
| Handoff | End time and duration unknown | No UI runtime or screenshot was part of routine verification. |

The three measured command totals sum to **320 s** of verification wall time, including **147.745 s** of case time. At least **83 s** was build time. This is not the follow-up's total wall-clock span or active agent time: exact command starts/ends, edit/review intervals, and gaps between operations are unavailable. The task's first and final timestamps are also unavailable.

Slowest named cases (seconds, descending within each full run):

| Rank | First full run | Final full run |
| --- | --- | --- |
| 1 | Composer/live turn controls 5.878 | PR conflict detection 7.545 |
| 2 | PR conflict detection 3.331 | Composer/live turn controls 5.809 |
| 3 | Task deletion 3.206 | Lifecycle rollout 3.515 |
| 4 | Done archive PR link 2.762 | PR creation failure 3.250 |
| 5 | CLI/XPC question answers 2.726 | Task deletion 2.850 |

## Findings and actions

1. **Check client lifetime before adding one-time protocol fallbacks.** `BridgeCore.swift` creates a new `CodexAppServerClient` for each `conversation.send`; `sendMessage` resumes the thread on that client. The fallback therefore treated a later send as another first send, and the first 154 s full run failed because the third turn carried developer instructions. Add an explicit client-lifetime check to the static review of thread/turn context changes, using the `conversation.send` construction site and `resumeThreadIfNeeded` call path. Verify on the next such change that an initial, resumed, and later resumed turn all satisfy the intended instruction placement on the first full run. The 83 s rebuild and extra full sweep in this repair cycle show the cost of discovering that lifecycle only at runtime.

2. **Resolve the remaining real-server resume uncertainty.** The final fixture and paired tests verify request placement, but the architecture review retained a concern about whether a fresh app-server process applies `developerInstructions` supplied to `thread/resume` as intended. `scripts/test-codex-integration.py` has live Codex coverage but no assertion for this protocol behavior. Add a narrow opt-in live integration assertion for a new thread and a resumed turn through fresh clients, checking that the instructions are effective without repeating them in `turn/start`. Verify against the installed Codex app-server and record the observed protocol result. This targets an unmeasured compatibility risk, not a demonstrated runtime failure.

## Timing gaps

The runner already emits phase totals and per-case durations; the bridge lock logs provide acquisition timestamps. The supplied conversation/ledger does not retain exact command start/end, planning/edit/review boundaries, or user-wait intervals. Retrieve the complete task tool timeline and reviewer decision records for these intervals in a future audit before adding timing instrumentation. Do not infer active work from the 320 s command total or from gaps between lock timestamps.
