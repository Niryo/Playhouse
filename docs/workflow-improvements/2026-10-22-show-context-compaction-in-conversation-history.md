# Show Context Compaction in Conversation History — workflow review

Task: `065372C9-A7DE-430E-A1CC-3E3497F31259`
Client date: 2026-10-22 (Asia/Jerusalem)

## Observed timeline

| Phase | Time or duration | Basis |
| --- | --- | --- |
| Task created | 2026-10-21 07:23:11 UTC | Supplied task record; work start is unknown. |
| Discovery and implementation | Before first task-specific runtime run on 2026-10-22 | Supplied progress: traced parser, UI, history and fixture; installed `codex-cli 0.162.1` schema confirmed `contextCompaction` item and lifecycle notifications. No operation timestamps or active-work duration retained. |
| Static review and repairs | Before runtime, repeated after relevant changes | Supplied progress: reviewers found lifecycle, ordering, old-history and paired-coverage gaps. Review durations and handoff gaps are unavailable. |
| First full verification attempt | Build failed after ~10 s; no case ran | Supplied runtime ledger: Swift function-reference mismatch. Start/end unavailable. |
| Second full verification attempt | Build ~86 s; 56 cases 91.114 s, 55 passed, one failed | Supplied runtime ledger and `/tmp/playhouse-bridge.8UV0Qt/bridge-tests.log`; case phase began 17:42:14 UTC. Completion was asserted while the fixture still held the turn active. |
| Focused repair cycle | 0.793 s failed case, then 0.624 s failed case | `/tmp/playhouse-bridge.XRminM/bridge-tests.log` at 17:44:06 UTC and `/tmp/playhouse-bridge.FBd2fw/bridge-tests.log` at 17:45:03 UTC. History reload lacked fixture environment, then activity projection omitted existing subagent rows. These case times exclude build, fixture setup and repair. |
| Focused confirmation | Rebuild ~84 s; case passed in 1.415 s | Supplied runtime ledger and `/tmp/playhouse-bridge.2JQOS8/bridge-tests.log`; phase end around 17:47 UTC. |
| Final full verification | 56/56 passed, 0 skipped; case runtime 88.776 s, command ~91 s | `/tmp/playhouse-bridge.nKwzGr/bridge-tests.log`; case phase began 17:47:20 UTC and ended 17:48:49 UTC. Build cache was reused. No UI run or screenshots in the routine gate. |

The task record to final runtime result spans **34 h 25 m 38 s**; this is a calendar bound and includes an unobserved interval across dates, not agent work. The task-specific runtime sequence from 17:42:14 to 17:48:49 UTC spans **6 m 35 s**, including repairs and setup. The supplied phase durations above sum to approximately **6 m 05 s** across the failed build, two builds, two full case runs, and three focused cases. Rounded timings, unrecorded static/setup phases, and intervals between commands prevent a precise reconciliation or active-agent total. Build waits and case execution are tool/runtime time; repair and review time cannot be separated from gaps using the available record.

In the final suite, the slowest cases were `test_task_done_preserves_worktree_and_branch` (**22.944 s, 25.8%** of case time), `test_conversation_composer_rejects_blank_and_supports_live_turn_controls` (**6.290 s, 7.1%**), and `test_task_delete_removes_task_and_later_lookup_is_not_found` (**3.192 s, 3.6%**). The task's paired conversation case took **0.973 s**. These are suite-wide costs, not evidence that the slow cases caused this task's retries.

## Actions for later tasks

1. **Keep fixture environment across all calls in one bridge case.** The first focused retry failed in 0.793 s because its history reload call omitted the fixture environment; it required another repair and focused run. Add a case-scoped CLI environment helper in `scripts/test-bridge.py`, then verify a reload call in a fixture-backed case succeeds without passing the environment again.
2. **Assert lifecycle states at their actual fixture boundaries.** A completed-state assertion during the active hold caused the 91.114 s full suite to fail. Put active and completed assertions immediately after their respective fixture transitions; verify that the paired case fails only when the corresponding lifecycle state is wrong. This preserves the required full gate while making its first result more useful.
3. **Make repair impact visible before rebuilding.** A repair accidentally dropped existing `latestTurnItems` subagent activity, producing a 0.624 s focused failure and an approximately 84 s rebuild before confirmation. Add a targeted static projection check for compaction plus existing activity in the same turn, and report whether it catches the omitted activity before the build. This is a hypothesis for avoiding a repeat, not a measured saving.

## Evidence gaps

Checked the supplied progress/verification ledger, task conversation available to this agent, task-specific bridge logs, and `scripts/test-e2e.sh` timing output. The bridge logs retain per-case durations and lock acquisition times; the runner prints phase totals to the calling terminal, but those complete outputs were unavailable here. The exact missing intervals are discovery/implementation, static review and handoff, each repair, and setup between command invocation and the first case. Capture the existing runner phase lines and command start/end timestamps in the per-task verification ledger before proposing new telemetry; no evidence shows the runner lacks those measurements.
