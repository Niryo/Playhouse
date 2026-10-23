# Add Durable Goals to Tasks — workflow findings

Task `16B9117F-8308-4B7A-B1C8-ECE45ED805F6` · Client date 2026-10-23 (Asia/Jerusalem)

## Timeline and measured time

| Sequence | Activity | Observed duration | Evidence and limit |
| --- | --- | ---: | --- |
| Oct 22 | Official Goal/app-server research, implementation, parity work, multiple static review and repair rounds | Unknown | Task conversation establishes sequence; no start/end event times. |
| Oct 22 | E2E preflight failure, build failure, failed 57-case run, two focused retries, passing 57-case run | **436 s runner total**; **191.204 s cases** | Prior task-specific runner output and bridge case logs. The preflight failure, repairs, and reviews are additional unmeasured time. |
| Oct 22–23 | Further source/test work, passing full CLI/XPC suite (57/57), real Codex integration run | **99 s** for CLI/XPC; integration duration unknown | Task verification handoff. Integration reached an existing concurrency case, then failed on task status (expected Review/Backlog; got Waiting Response/In Progress). No integration wall time was retained. |
| Oct 23 | First live Goal Tart run failed because the opt-in environment was absent in XCTest; marker fallback repair and static review | **179 s** to host result artifact; **12.188 s** XCTest case | `20261023T075151Z-73193` Tart artifacts; duration derived from runner ID and result-file mtime, so it excludes later cleanup. Repair/review time unknown. |
| Oct 23 | Live Goal retry reached the guest-auth precondition; guest lacked `~/.codex/auth.json` | **153 s** to artifact; **0.761 s** case | `20261023T075815Z-75362` Tart artifacts. Host auth was present but was not transferred to the guest. |
| Oct 23 | Default focused Goal UI retries: empty accessibility labels, label/value assertion repair, concurrent CLI active-writer reads, then persistence flow repair | **141, 154, 156, 156, 164 s** to artifacts; **13.013, 12.709, 12.585, 17.627, 28.856 s** cases | Tart runs `080138Z`, `080537Z`, `080914Z`, `081331Z`, `081757Z`; order and failure points from each `ui-test.log`. Editing, review, and gaps between invocations cannot be separated. |
| Oct 23 | Final focused Goal UI case passed after app close/relaunch verified persistence and clear | **153 s** to artifact; **23.072 s** case; 1/1 passed | `20261023T082200Z-91079` Tart artifact and XCTest output. Final task/UI static approvals were reported for fingerprint `6b7ccb2924f0408283f9ac7e92055c297913d62e44f00fd5afa4f3b86bf13b8f`; prior architecture approval remained applicable. |
| Oct 23 | App launch and handoff | Unknown | App process was reported present from this worktree. Progress reporting was rejected because the board task was Waiting Response; no completion timestamp supplied. |

The **eight Oct 23 Tart runs total at least 1,256 s (20 min 56 s)** from run markers to result artifacts. Their eight XCTest cases total **120.811 s (9.6%)**; the remaining **at least 1,135 s** is VM, snapshot, build, Xcode/session, artifact, and other runner time, which the existing logs do not divide. From the first run marker at 10:51:51 IDT to the last result artifact at 11:24:32 IDT is **32 min 41 s**; approximately **11 min 45 s** lies between those measured run-to-artifact spans and includes unknown repair, review, cleanup, and wait time. Across both task turns, the supported runner-time lower bound is **1,791 s (29 min 51 s)**: 436 s earlier E2E, 99 s later CLI/XPC, and 1,256 s Tart. It is not the task's total wall-clock or active agent time.

The slowest Oct 23 Goal case was the fifth default retry at **28.856 s**; the final passing case took **23.072 s**. Across the measured UI workflow, runner setup dominates case execution, but the logs cannot identify which setup operation dominates.

## Improvements

1. **Fail live Tart runs at a guest authentication preflight before Xcode starts.** The unauthenticated live retry occupied **153 s** to its result artifact, while the case found the missing auth file in **0.761 s**. Add a guest-side check in `scripts/test-ui-tart.sh` for an authenticated Codex CLI before invoking `scripts/test-ui.sh`, reporting the guest login requirement. Verify an unauthenticated `--live-codex` attempt exits before `xcodebuild`, and an authenticated guest proceeds to the case. The exact savings depend on when the preflight runs within VM setup.

2. **Measure Tart runner phases before optimizing its setup.** Eight focused invocations spent **at least 1,135 s outside XCTest**, but `scripts/test-ui-tart.sh` records neither total nor phase elapsed time. Add monotonic timings for VM launch/lock wait, snapshot, guest build/Xcode, artifact copy, and shutdown to the host and guest logs. Verify a subsequent focused run's phase durations reconcile with its runner total; then target the largest measured phase. Existing XCTest per-case times do not answer this question.

## Evidence gaps

Checked task conversation/progress and review handoff, the task's eight Oct 23 Tart `ui-test.log` and `exit-status.txt` artifacts, prior task-specific CLI/XPC output, and timing producers in `scripts/test-ui-tart.sh` and `scripts/test-ui.sh`. The UI logs retain per-case time and results; the Tart runner does not emit phase timings. The live Codex integration invocation's wall time and the research, edit, review, repair, communication, and user-wait intervals are unavailable in the supplied record. A timestamped task/tool/review event export and the integration runner output would be needed to reconcile full task wall time; no precise duration is inferred from those gaps.
