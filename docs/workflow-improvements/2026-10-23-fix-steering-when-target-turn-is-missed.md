# Fix steering when the target turn is missed

Task: `F741EF98-25C3-436C-8EBE-2112389F144C`  
Client date: 2026-10-23 (Asia/Jerusalem)

## Observed timeline

| Phase | Evidence and timing |
| --- | --- |
| Investigate “Add Durable Goals to Tasks,” trace stale `turn/steer` handling and queue dispatch, implement the fallback and paired CLI/UI assertions | Sequence from the task conversation; start, end, and active work duration unavailable. |
| Static review and repair | Task and UI verifiers and architecture reviewer approved the final source inputs; parity reached 59 paired cases. Review rounds and repair intervals have no retained durations in the supplied ledger. |
| Initial full CLI/XPC run and first focused retry | Full run failed one steering case on a positional queue assertion; the focused retry then exposed a queued record marked `needsAction` after cross-process overlap. The initial full runner duration is unavailable. Retained case logs show the steering case took **2.260 s** in the failed full run and **18.472 s** in the failed focused run; log files span 12:03:24–12:05:12 and 12:06:12–12:06:31 local time, respectively. Those file timestamps cover case logging, not the complete commands. |
| Repair and targeted retries | Queue ownership and synchronous drain repairs followed. Later focused runs exposed fixture thread IDs and missing fixture environment on two calls; those were repaired. The task handoff records two distinct cache-miss focused invocations of **106 s** and **90 s** and two cached failed invocations of **8 s** and **7 s**. These are measured command wall times, with no reliable active-agent breakdown. Other retained failed focused case durations are **19.619 s**, **3.841 s**, **3.793 s**, and **3.790 s**; their commands cannot all be matched unambiguously to the four handoff totals. |
| Passing focused retry | **8 s** command wall time; steering case **4.358 s**. Retained case log spans 12:29:06–12:29:11 local time. |
| Final full CLI/XPC suite | **110 s** command wall time; 59/59 passed, zero skipped. The 59 case timers sum to **107.587 s**; the runner's whole-second phase counter reported 107 s for cases. The retained case log spans 12:29:19–12:31:06 local time. UI execution and screenshots did not apply to routine verification. |

This is a **partial task timeline**. The first task activity and completion/handoff timestamps are unavailable, so total task wall time and active agent time cannot be calculated. The first retained task-specific runtime log starts at 12:03:24; the final case log ends at 12:31:06, a **27 min 42 s** observed span containing repairs, review, command setup, and unknown gaps. The six handoff-timed later commands total **329 s** (106 + 90 + 8 + 7 + 8 + 110), but the earlier full run, first focused retry, other observed retries, and all non-command work prevent reconciliation to a task total. Command time is tool/runtime wait, not a measure of active agent work.

The final suite's slowest named cases were `test_task_done_preserves_worktree_and_branch` **23.428 s** (21.8% of summed case time), `test_review_pr_conflicts_probe_and_verify` **14.028 s** (13.0%), `test_conversation_composer_rejects_blank_and_supports_live_turn_controls` **5.792 s** (5.4%), and the steering case **4.734 s** (4.4%). These are case durations from the retained final `bridge-tests.log`; the 110 s runner total has whole-second resolution.

## Practical improvements

1. **Validate steering fixture prerequisites before the expensive build.** Fixture-only defects in synthetic thread IDs and missing executable environment caused focused retry failures after implementation repair. Two cache-miss focused commands cost **196 s combined**; the fraction spent before the cases is not separately retained. Add a cheap pre-build check in `scripts/test-e2e.sh` that verifies the steering fixture's thread ID shape and the fixture executable/environment contract for every invocation path used by the paired case. Verify impact by making each invalid fixture fail before `prepare-e2e-build.py` and confirming the normal focused case still passes.
2. **Preserve runner phase output with the case artifact.** `scripts/test-e2e.sh` writes per-case logs to `bridge-tests.log`, while its `E2E phase=...` and total lines are only streamed to stderr. This left the initial failed full run and some focused command costs unrecoverable from the artifacts, despite retained case timings. Tee the runner's phase and total lines into a task-local timing file inside the same artifact directory, including wall timestamps and the selected case IDs. Verify by reconstructing static, build, fixture, cases, and total times for a failed focused run and a passing full run from artifacts alone.

## Evidence limits

Checked the task conversation/handoff and verification ledger, retained `/tmp/playhouse-bridge.*/bridge-tests.log` files for this task, `scripts/test-e2e.sh` phase counters, `scripts/test-bridge.py` per-case timer, and the task's current source diff. The runner emits case durations and whole-second phase totals, but the available artifact does not retain the outer phase stream. The task-progress and review events available in this handoff do not provide start/end timestamps. The next investigation for task-wide wall and active time is to obtain timestamped task-progress/reviewer events for this task, if retained, and align them with the runner artifacts. No system-wide telemetry absence is inferred.
