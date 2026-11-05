# Render and answer async Codex questions — workflow review

Task: render `request_user_input_async` as inline answer cards and route replies through Playhouse's shared conversation manager. Date: 2026-10-23 (client local date). This is a **partial timeline**: the task's first exploration/implementation timestamp and final handoff timestamp were not retained in the available record.

## Observed timeline

| Phase | Time or duration | Basis |
| --- | ---: | --- |
| Explore Codex session/schema, implement parser, manager, bridge, CLI, UI, fixture, and paired tests | Unknown | Task conversation and changed-file list; no start/end timestamps or active-work timer. |
| Static checks and three-agent review; repair active-turn coverage and shared-manager routing | Unknown | Task conversation; approvals and architecture concern were reported, but review durations were not captured. |
| First `test-e2e.sh` static prerequisite failure (`.help` hints), then repair | Unknown | Task conversation; this invocation stopped before build/cases and has no retained command timing. |
| First full CLI/XPC suite | 19:09:00–19:12:37, **217 s** | `/tmp/playhouse-bridge.eCAQpv` filesystem times and command summary. About 99 s before case log creation, including the reported ~95 s build; 62 cases took 118.440 s. One new case failed because the test expected CLI exit 1 instead of 2. |
| First focused retry | 19:13:11–19:13:16, about **5 s** | `/tmp/playhouse-bridge.3r7NAV`; case took 1.125 s and failed on expecting `options: null` where JSON omitted `options`. |
| Second focused retry | 19:13:52–19:13:58, about **6 s** | `/tmp/playhouse-bridge.EfyrZ8`; case passed in 1.601 s. |
| Final full CLI/XPC suite | 19:14:03–19:16:07, **124 s** | `/tmp/playhouse-bridge.1bgwdv` and command summary; cached build, 62/62 cases passed in 119.143 s. |

The observed interval from the first full run to the final full log is **427 s**. Four measured invocations account for about **352 s**; the remaining **75 s** comprises three gaps between runs (34 s, 36 s, 5 s), including repair and preparation whose active-work portions are unknown. The overall task duration and phase totals before 19:09 are unknown. No UI runtime or screenshots were part of routine verification.

In the final suite, the slowest cases were `test_task_done_preserves_worktree_and_branch` (24.548 s, 20.6% of case time), `test_review_pr_conflicts_probe_and_verify` (14.283 s, 12.0%), and `test_conversation_composer_rejects_blank_and_supports_live_turn_controls` (6.132 s, 5.1%). The new async-question case took 1.600 s in its passing focused run. These other cases did not cause this task's failures, so their duration alone does not justify changing them here.

## Improvements supported by this task

1. **Run the complete cheap static prerequisite set before static review.** The first runtime invocation stopped at `check-button-feedback.py` after prior parity/syntax checks, causing a repair and another review cycle; its exact cost was not retained. Add `check-button-feedback.py` and `check-e2e-locking.py` to the task's pre-review static command alongside parity and parsing. Verify on the next source task that all three checks pass before reviewers start and that no first runtime invocation stops on a static prerequisite.
2. **Use the CLI response contract when writing failure assertions.** The new case's wrong expected exit code forced a 217 s failed full run, and the wrong optional-field shape forced another focused retry (~5 s). Update the async-question test-writing checklist or nearby test helper examples to show `expected_status=2` for `invalid_argument` and omitted optional JSON fields. Verify that a later CLI case introducing validation and nullable/optional data reaches its first runtime run without assertion-only corrections. The two mistakes are evidenced by the retained failure logs; no production defect was indicated by those failures.

## Evidence and telemetry gaps

Checked the task conversation/verification summary, `test-e2e.sh` phase-printing code, `test-bridge.py` per-case timer, four retained bridge logs, and their filesystem timestamps. Per-case timing exists in `bridge-tests.log`; suite phase and total timings are printed by `test-e2e.sh` but are not in that file. The first prerequisite failure's output and duration, review durations, implementation start/end, and active agent time were unavailable in the supplied task record. The next investigation is to retain the existing command stderr/phase lines with the task ledger before adding new logging; that would separate build, fixture, and case costs for every attempt without changing test instrumentation.
