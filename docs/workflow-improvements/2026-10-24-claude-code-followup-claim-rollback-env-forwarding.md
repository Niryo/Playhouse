# Claude Code follow-up: claim-status rollback, bridge-environment forwarding, foreground-execution instruction, live provider suite docs

Task: continuation of phase 1 commit 67c0927 (plan /Users/niryo/Downloads/PLAN.md, state in handoff.md). No task ID supplied.
Final fingerprint a420ec0033d7 (static round 1: 641e6f7d2032). Timeline is PARTIAL.

## Evidence sources checked
- Session transcript `bad7e338-...jsonl` (per-record timestamps on 3222 records, 2026-10-24T06:21:17Z to 08:57:20Z; about 2h36m wall clock, includes pre-follow-up work in the same session).
- Verification ledger supplied by the caller (subagent durations, E2E results).
- Tool-call timestamps for Bash/Agent launches. Tool results carry no durations except `time`/suite totals reported by the scripts.

## Timeline (wall clock from tool-call timestamps unless stated)
| Phase | Interval | Basis |
|---|---|---|
| Exploration (2 Explore agents) | launched 06:31:47-06:31:54 | derived; end not recorded |
| Implementation + first CLI runs | 06:32 to ~07:27 | derived, mixes editing and waiting on a full suite started 06:59:27 |
| Focused CLI reruns (new provider cases) | 07:27:45, 07:32:42 | derived start only |
| Live suite authoring and Claude/Codex live runs | 07:38 to 08:05 (Claude auto-branch/stop scenarios needed 4 harness-fix reruns 07:53-07:59) | derived |
| Full deterministic CLI/XPC suite | started 08:05:31 | derived |
| handoff.md update | 08:09:30; next recorded action 08:40:29 | 31 min gap, activity unknown |
| Static round 1 (parallel) | launched 08:41:28-08:41:44; ledger: task 223059 ms, ui 104725 ms, arch 142901 ms | measured by subagent; critical path about 3.7 min |
| Repairs | ~08:42 to ~08:51 (about 9 min) | derived |
| Static round 2 | task 84466 ms, ui 70006 ms, arch 72338 ms; critical path about 1.4 min | measured |
| Runtime: first full run | 08:51:03 to 08:53:05, aborted at build after 115 s | measured |
| Runtime: rerun | 08:53:05 to ~08:57, 234 s, total=64 passed=64 skipped=0 | measured |
| Optimizer report | 08:57:14 | derived |

Reconciliation: task-specific measured time is only the static (about 5.1 min critical path across both rounds) and runtime (115 s + 234 s) segments, about 11.5 min. The rest of the 2h36m session is derived from launch timestamps and cannot be split into active agent work, tool wait, and user wait. Per-case durations of the 64-case suite were not in the supplied evidence; not analyzed.

## Findings and recommendations

1. Wasted full-suite build from concurrent edits (115 s lost, plus one rerun).
   Observed: first runtime run aborted with "source tree changed while the E2E app was building; refusing to cache a mixed build" because handoff.md/docs were edited by a Python script during the build. Cause is partly a fingerprint mismatch: the build guard hashes a wider tree than the `git diff -- StationAI scripts` fingerprint used for the ledger (cause confirmed by the ledger, exact guard scope not verified here).
   Action: do not run any file-writing command while a build/suite is in flight (start the suite only after the docs/handoff edits are final; edit docs before, not during). Check whether the guard needs to ignore documentation paths; if so scope it in the build script, since AGENTS.md says docs-only changes do not invalidate behavioral evidence. Verify: zero "mixed build" aborts in next tasks.

2. Static round 1 rejected all three reviewers; round 1 cost about 3.7 min critical path plus about 9 min repair plus round 2 about 1.4 min.
   Finding classes a pre-review checklist (self-review before launching reviewers) would have caught:
   - Exit-code expectation: test asserted CLI exit 1 but the real code is 2 (would fail at runtime). Checklist: run `scripts/stationai.sh` once by hand for each new failure assertion, or grep the CLI's exit-code table, before writing the expectation.
   - Process identity GUI vs XPC: GUI-started provider turns received the app bundle id as bridge service name (found only by the architecture reviewer). Checklist: for any new environment/identity forwarded to a child process, enumerate every launch path (GUI composer, XPC manager) and confirm the value source in each.
   - Composer vs manager ownership: the composer pre-saves In Progress before the manager runs, so rollback restored the wrong status (UI reviewer; the architecture reviewer later still recorded a CONCERN about the composer owning part of the send pipeline). Checklist: when a manager rolls back state, trace which caller mutates that state first. The submission-token refactor is recorded in handoff.md as follow-up.
   - Missing deterministic coverage for env forwarding. Checklist: each new behavior needs a deterministic CLI case, not only a live-suite assertion.
   Verify: next task's round 1 has fewer rejection classes; track rounds-to-approval in the ledger.

3. Live provider assertion unexecuted after final change.
   Observed: the loser-Backlog assertion in scripts/test-live-integration.py was restored at 08:40:56, after the last live runs (Claude 07:59, Codex 08:01, handoff 08:04). Not run afterward.
   Action: for the next change touching live harness assertions, run the single affected scenario (the auto-branch scenario was runnable individually at 07:55-07:57 in about 2 min) before declaring done, or record it as an explicit unexecuted gap in the final report. Verify: ledger lists the live scenario as executed.

4. Harness fix loop on live auto-branch/stop scenarios (07:53 to 07:59, 4 edit+rerun cycles, about 6 min).
   Observed: stdout ownership, cleanup block, and stop token fixed one at a time, each followed by a live run of about 1-2 min.
   Action: dry-run the harness's setup/cleanup paths without a live provider (python `--help`/syntax and fixture-only mode) before live runs. Verify: fewer harness-only reruns.

## Telemetry gaps
- 31 min interval 08:09:30 to 08:40:29 (between handoff update and static review start): activity not captured in tool timestamps; cause unknown (agent thinking, user wait, or untimestamped work). The transcript has tool-call timestamps but no per-turn wait/active split.
- No end timestamps for background full-suite runs started 06:59:27 and 07:38:52; completion notification times are not extracted here.
- Implementation and repair phases have no measured duration; only launch-time bounds.
- Per-case durations for the 64-case suite and live scenarios were not in the supplied evidence.
- UI cases in Tart not run (AGENTS.md: on demand), so no UI timing exists.
