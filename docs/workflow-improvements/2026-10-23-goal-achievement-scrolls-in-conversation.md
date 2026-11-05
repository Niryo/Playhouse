# Goal achievement scrolls in the conversation

Task `16B9117F-8308-4B7A-B1C8-ECE45ED805F6` · Client date 2026-10-23 (Asia/Jerusalem)

## Observed timeline

| Phase | Time and evidence | Measurement limit |
| --- | --- | --- |
| Implement the scrolling Goal event and paired contract/UI assertions; run parity checks | Before final review; task conversation and parent progress summary | Start/end timestamps and active edit time unavailable. |
| First static review | Reviewers identified missing ordering checks after the completing assistant turn and in the Done archive; task conversation | Review duration unavailable. |
| Repair and second review | Added both ordering checks and coverage for a second Goal generation; task conversation. Task, UI, and architecture reviewers returned STATIC APPROVED at fingerprint `a78363df258e40f72872f1e9e13b0c26d7715d6c8db40e6a14282efce7a24edd` | Repair and review durations unavailable. |
| Final `scripts/test-e2e.sh` | 191 s reported by the runner; build 87 s, 57 CLI/XPC cases 100.332 s, about 3.7 s other runner work (derived by subtraction). Bridge log acquired its run lock at 2026-10-23 09:48:48 UTC with 0 s queue wait. All 57 cases passed. | Runner phases are measured to whole seconds; per-case durations are measured to milliseconds. |
| Relaunch updated worktree app | About 63 s across invocation and polling; parent tool observation. Process PID 65387 confirmed running from the worktree build. | Estimate; internal build and launch durations unavailable. |

The visible lifecycle spans **at least about 254 s** of final verification and relaunch (191 s measured plus about 63 s estimated). Preparation, implementation, static review, and gaps between tool calls have no reliable timestamps, so a full task duration or active-agent total cannot be reconciled. The test runner accounts for 87 s build (45.5%), 100.332 s cases (52.5%), and about 3.7 s other work (2.0%) of its 191 s wall time.

The slowest case was `test_task_done_preserves_worktree_and_branch` at 24.377 s (24.3% of case time); it includes creation, completion, and archiving of 40 filler tasks. Next were `test_conversation_composer_rejects_blank_and_supports_live_turn_controls` at 6.423 s and the changed Goal lifecycle case at 3.715 s. The case log contains 57 per-case durations totaling 100.331 s, consistent with the suite's 100.332 s rounded total.

## Improvements

1. **Separate archive pagination setup from task completion coverage.** The 24.377 s case covers both Done transition behavior and archive pagination; its 40 filler tasks are visible in `scripts/test-bridge.py`, but their individual cost is not measured. Move pagination into its own named CLI/UI contract case with isolated data and retain the Done transition assertions in the existing case. Verify that focused Done transition reruns no longer create 40 filler tasks, and compare both resulting case durations with the 24.377 s baseline. This primarily improves diagnosis and focused reruns; full-suite savings are unproven.
2. **Check conversation event ordering before the first static review.** The first review found two missing ordering assertions, leading to a repair and review cycle whose elapsed cost was not recorded. For future timeline events, require the paired UI case to assert position after the completing turn, position before a later user message, and the same order after archive reopen; include a second event generation when repeated events are supported. Verify that the next timeline change reaches static approval without these coverage findings.

## Evidence and telemetry limits

Checked the task conversation and parent progress/verification summary, final `/tmp/playhouse-bridge.Z6ivAk/bridge-tests.log`, and `scripts/test-e2e.sh`/`scripts/test-bridge.py` timing output. The runner emits phase and per-case durations, but the available case output has no per-step durations for the 40-task archive setup. The review and relaunch summaries available to this audit lack precise start/end timestamps. Before adding logging, first capture existing timestamped tool-call and progress events for one future task; if they still omit review or relaunch boundaries, instrument those specific operations.
