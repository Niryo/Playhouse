# Fix Chat Jumping to Blank Space After Send

Task: `40E8A7F6-ABD5-47FB-8C2A-557BCADEC801`  
Scope: the chat scroll fix and its paired CLI/UI coverage. Times below are UTC on 2026-10-27.

## Observed timeline

| Interval | Phase | Duration | Evidence and precision |
| --- | --- | ---: | --- |
| 18:13:44–18:14:35 | Task start to first recorded agent event | 51 s | Derived from task metadata and session log. Activity within this interval is unknown. |
| 18:14:35–18:16:10 | Context and repository exploration | 1 m 35 s | Derived from session tool/message timestamps; includes tool runtime and agent work, which cannot be separated reliably. |
| 18:16:10–18:17:09 | Initial implementation and paired assertions | 59 s | Derived from first patch and first reviewer launch timestamps. |
| 18:17:09–18:22:33 | Static reviews, coverage repair, re-review, parity | 5 m 24 s | Derived from reviewer launches and runtime start. Reviews ran concurrently. Task verifier first rejected an assertion placed after the response, since it could miss the immediate post-send jump. The assertion moved to an existing active-turn tool fixture; task/UI reviews then approved and architecture approval was retained. Exact active agent time and review wait are unavailable. |
| 18:22:33–18:28:14 | Full CLI/XPC verification | 5 m 41 s | Measured by `scripts/test-e2e.sh` phase output and `/tmp/stationai-bridge.pAEfOJ/bridge-tests.log`: static/prep about 1 s, build 155 s, fixture 2 s, cases 183 s. All 88 cases passed with no skips; the affected tool-activity case took 0.887 s. The build/run lock reported 0.000 s queue wait. |
| 18:28:14–18:30:31 | Final scope check and handoff/report initiation | 2 m 17 s | Derived from suite log and session timestamps. The parent task's final response is not yet present in the audited record. |

Observed elapsed time through the last audited handoff event is **16 m 47 s**. This is a partial lifecycle timeline: it ends before the parent's final response and this report's completion. Phase intervals sum to the observed span; they are wall-clock intervals, not additive active-agent time. The 51-second initial interval and active-versus-wait split within exploration/review remain unknown.

## Findings and actions

1. **Put timing-sensitive UI assertions at the reported failure moment.** The first static review found that a final-answer visibility check could pass after an immediate post-send blank viewport had recovered. Repair and re-review occupied the 18:18:55–18:22:27 portion of the static phase (about 3 m 32 s wall clock, overlapping agent work and waits). For future send/scroll fixes, inspect available held-turn fixtures during initial test design and assert the sent row is visible while the turn is still active. Verify impact by counting static review rounds and whether the first review accepts the timing coverage. This task's final assertion uses the existing tool-activity hold.

2. **Isolate archive pagination from the Done-worktree case for clearer focused retries.** `test_task_done_preserves_worktree_and_branch` took **29.165 s**, or **16.0%** of the 182.779 s summed case time. It performs 40 filler task create/send/move cycles after its worktree assertions; diagnostics show 219 bridge requests, including 41 `conversation.send` calls totaling 10.050 s of bridge time. Move the archive pagination portion into its own paired CLI/UI case while retaining the real persistence and provider fixture behavior. This would make a failure in either behavior eligible for a narrower focused rerun; measure the focused retry duration and keep the full-suite total visible before claiming a speed gain.

The second slowest case, `test_review_pr_conflicts_probe_and_verify`, took **16.356 s**; two `task.pr.verify` requests took 4.963 s and 4.792 s. Together the two slowest cases account for **24.9%** of case time. The verification retries are part of the asserted behavior, so this record does not support shortening them. The single 155-second build was **45.5%** of the full run; there was no repeated build or lock queue in this task, so it is not evidence of avoidable build work.

## Evidence limits

Checked the task conversation/session timestamps, three reviewer session bounds, changed-file diff, parity/run scripts, full suite per-case log, and per-case bridge diagnostics. The suite emits phase and per-case durations; bridge diagnostics emit request durations. The reviewed record does not expose a reliable active-agent versus tool-wait split for the static phase, and the task metadata does not provide a final-response timestamp yet. Use the task session's timestamped events and the final response event to close that interval; no new logging is justified by this audit.
