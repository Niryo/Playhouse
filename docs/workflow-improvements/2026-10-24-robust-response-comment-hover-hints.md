# Robust response comment hover hints

Task: `4955B4B9-2A17-48E8-800D-88912CB4DA71`  
Client date: 2026-10-24

## Observed timeline

| Phase | Time (Asia/Jerusalem) | Evidence and duration |
| --- | --- | --- |
| First visible focused UI attempt | Oct 23, 13:38–14:45 | `/tmp/comment-hover-focused.log` file birth/last write: 67 min wall time; the named XCTest itself failed after 18.346 s. Its last timestamped Xcode event is 13:45, so the remaining interval is **unattributed**. |
| Unobserved interval | Oct 23, 14:45–23:25 | 8 h 40 min between task log records. No evidence here distinguishes agent work, waiting, or user time. |
| Hover diagnosis, implementation, and focused UI retries | Oct 23, 23:25–Oct 24, 02:34 | 3 h 9 min wall time, derived from first/last `/tmp/hover-*.log` file timestamps. 41 focused Tart invocations consumed 8,230 s (2 h 17 min) of recorded command wall time: 30 test failures, 10 builds with no case run, then 1 pass. The remaining ~52 min includes edits, inspection, screenshots, static reviews, and gaps; their individual durations are not recorded. |
| Final focused UI and screenshot inspection | Oct 24, 02:28–02:35 | Final VM run passed 1/1 in 374 s wall time; the named case took 158.519 s. Screenshot export followed; screenshots were visually inspected for top alignment and wrapped-marker centering. |
| Final CLI/XPC verification | Oct 24, 02:35–02:38 | `/tmp/hover-cli-full.log`: 57/57 cases passed; 90.189 s summed case time, 174 s total command time. |

The first visible log to final CLI completion spans about **13 h 1 min**, but 8 h 40 min is an unobserved gap and must not be counted as active work. The continuous late session spans about **3 h 13 min**. Static task, UI, and architecture reviewers approved the final source/test inputs; the available summary does not timestamp those reviews. No full UI suite ran.

## Practical improvements

1. **Give hover behavior its own focused UI case and setup.** The existing `test_conversation_adds_ordered_text_annotations` covers creation, submission, restart, legacy history, and hover in one long path. Of 41 late-session focused runs, 31 reached XCTest and spent 2,475 s inside that single case; final hover verification alone took 158.519 s. Add a paired CLI/UI hover case with deterministic real conversation history containing two comment links, including a wrapped link, while leaving send/persistence coverage in the current case. Verify improvement by comparing median named-case duration and whether a hover failure can be reproduced without redoing submission/restart steps. Preserve the repository's named-case parity requirement.

2. **Handle corrupted VM build state at the runner boundary.** Ten of 41 late-session invocations never ran the case (1,090 s command wall time). Logs include `XCBuildData/build.db` “no more rows available” and “database disk image is malformed”; a full VM DerivedData reset preceded the final successful build. A temporary `-jobs 1` experiment did not resolve it and was reverted. In the VM UI runner, detect this specific build-database failure and perform one scoped DerivedData reset/rebuild before returning a failed test result. Measure the number and duration of no-case UI invocations on future tasks. Do not interpret a build failure as a product test failure.

3. **Make pointer targets observable before testing delays.** Several retries adjusted normalized XCTest coordinates and scroll positions before the recording and pixel evidence showed whether the pointer was on the rendered marker. The successful case used screenshot-derived glyph bounds and explicit pointer polling. Keep a reusable helper that records the target text view frame, glyph bounds, pointer position, and hint frame when a hover assertion fails. Verify it by checking that the first failure artifact alone identifies whether the pointer missed the marker, the hint timer failed, or the popover was misplaced.

## Measurement limits

Sources checked: task conversation summary and progress details, focused Tart logs and per-case XCTest lines, final CLI/XPC log and per-case times, screenshot-export logs, and the current UI test source. File birth/modify times measure command-output file lifetime, not pure build time or agent effort. The runner logs do not timestamp each setup, build, VM teardown, screenshot inspection, edit, or reviewer phase; a per-phase runner event log or shell start/end records would be needed to apportion the 8,230 s more precisely. The early 67-minute log has an unexplained interval after Xcode finished; inspect the corresponding Tart runner/teardown log before attributing that interval to VM shutdown.

Slowest measured named cases: UI `test_conversation_adds_ordered_text_annotations` 158.519 s (final pass); CLI `test_task_done_preserves_worktree_and_branch` 22.718 s; CLI comment-related coverage is included in the 57-case total. The final CLI's 83.811 s outside named cases is setup/build/runner overhead by subtraction, not a measured single operation.
