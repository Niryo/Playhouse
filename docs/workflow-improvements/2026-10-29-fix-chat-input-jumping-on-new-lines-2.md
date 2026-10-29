# Fix chat input jumping on new lines: follow-up

Task: `597740E9-2F83-4890-B224-75F813813F72`  
Follow-up unstaged source fingerprint: `0a2f97919f209916ca3948f5c096d22022fa6a195d2056f54125fa3737e7df3a`

## Observed timeline and cost

| Phase | Time or duration | Evidence and precision |
| --- | --- | --- |
| First implementation verified; user then reported the jump again | First full run ended about 06:54:15 UTC, 29 Oct | Earlier supplied run start and 363 s total. The time of the user's follow-up report is unavailable; this is not an active-work interval. |
| Investigate recurrence and app instance | Between first run and follow-up source edit | Task handoff reports the running GUI executable came from the primary `StationAI-DerivedData` build. This task worktree uses a separate build and bundle ID, `com.stationai.app.worktree.wb4dadd315ae6dead`. Exact inspection times are unavailable. No visible test was run on the user's instance. |
| Repair editor height measurement | By 07:21:29 UTC | `TaskConversationView.swift` modification time, a latest-write bound. The change measures the live `NSTextView` layout manager's `usedRect` and `extraLineFragmentRect`, in addition to replacing the 100 ms layout debounce. The previous `boundingRect` used the full width and omitted the live container's line-fragment padding, so it could undercount a newly wrapped line. |
| Static review | Before the second full run | Task, UI, and architecture reviews all approved per handoff. Review start/end times and any repair rounds are unavailable. |
| Second full CLI/XPC run | About 07:23:09–07:29:16 UTC; **367 s measured** | Temporary run directory creation and bridge-log modification times bound the run; supplied runner total is 367 s. Build 142 s, fixture 3 s, cases 221 s; the remaining 1 s is phase rounding or static checks. `92/92` cases passed with no skips. |

The task creation at 06:34:35 UTC to the second runtime end at about 07:29:16 UTC spans **about 54 min 41 s**. The two measured full runs total **730 s (12 min 10 s)**. The other **about 42 min 31 s** includes implementation, static reviews, investigation, user-response time, communication, and gaps; it cannot be assigned to active agent work. The follow-up window from the first runtime end to the second is about 35 min 1 s, but its actual start is unknown. The later handoff time is also unknown.

In the follow-up bridge log (`/private/tmp/stationai-bridge.oxamb8/bridge-tests.log`), the slowest cases were `test_task_done_preserves_worktree_and_branch` (29.053 s), `test_codex_questions_can_be_answered_over_cli_xpc` (27.528 s), and `test_review_pr_conflicts_probe_and_verify` (16.135 s). Together they took 72.716 s, about 33% of the 220.898 s measured case time. The paired composer CLI case took 8.139 s. The 142 s build was 39% of the full 367 s run. One follow-up full run gives no evidence that the required build was repeated unnecessarily.

## Improvements supported by the follow-up

1. **Check the GUI profile before asking for a manual recheck.** The running app belonged to the primary build while the fix and CLI/XPC verification belonged to this worktree's separate bundle. That mismatch is a plausible explanation for why the user still saw the old behavior, though it does not prove what the user saw. Use the existing `stationai_profile_processes` check in `scripts/app-profile.sh` and report the executable path, bundle ID, and worktree window title when handing off a GUI fix for visual confirmation. Verify impact by confirming the process path matches the tested worktree before the next user recheck; track whether an app-instance mismatch causes another avoidable repair cycle. This follow-up required an additional 367 s full CLI/XPC run, plus unmeasured investigation and repair time.
2. **Use TextKit's live layout geometry for wrap-sensitive editor fixes.** The first implementation updated scroll timing, but the height calculation still used an independent `boundingRect` width that did not match the editor's line-fragment padding. The user report triggered a production correction and another required full run (367 s); the independent contribution of this measurement error versus the app mismatch cannot be isolated. In future `NSTextView` wrap fixes, inspect `layoutManager.usedRect`, `extraLineFragmentRect`, and the live text container before accepting a height calculation. Verify at the first few characters of successive wrapped lines in the paired visible UI assertion; retain the same CLI/XPC contract coverage.

## Evidence limits

Checked the supplied task continuation, current unstaged source diff and modification times, retained per-case bridge log, `scripts/test-e2e.sh`, and the existing profile process helper and worktree launch instructions. The available records measure suite phases and cases but do not timestamp the user's recurrence report, app-process inspection, review operations, active-agent periods, or final handoff. A timestamped task conversation/progress record would be needed to separate those intervals. The GUI process path supports a profile mismatch; it is not evidence that the corrected UI was exercised in that process.
