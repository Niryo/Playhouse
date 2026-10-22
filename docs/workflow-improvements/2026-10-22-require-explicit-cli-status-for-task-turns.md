# Require explicit CLI status for task turns

Task: `FC456E6F-947A-4D59-8519-8AE8BBB3980E`  
Client date: 2026-10-22

## Observed timeline

All clock times are UTC. Durations marked **measured** come from runner output; the task card time is approximate. The task conversation, supplied verification ledger, runner output, `scripts/test-e2e.sh`, `scripts/test-bridge.py`, and the task's changed-file timestamps were checked. No unrelated task reports were used.

| Phase | Time or duration | Evidence and limit |
| --- | --- | --- |
| Task creation; planning, repository discovery, implementation | Card created about 12:53; first source edit observed by 12:57; elapsed and active time unknown | Task card time supplied by caller; file modification times establish only latest writes, not phase boundaries. |
| Initial static review and revisions | Before first full run; duration unknown | Task/UI approved at `f8911fbf`; architecture approved at `3cf2b6b0`. Earlier review findings drove changes to board assertions, fixture expectations, and turn-scoped outcome staging. Parity covered 56 paired cases and `git diff --check` passed; their durations and reviewer start/end times were not available. |
| First full CLI/XPC run | Cases started 13:26:50; **178 s total**, including **74 s build** and **100.983 s cases** | Runner summary and [first bridge log](/tmp/stationai-bridge.VBYdLh/bridge-tests.log). Command start time was not captured. 56 cases ran; two failed. The remaining roughly 3 s covers fixture/static/setup and rounding. |
| Repair, static refresh, focused retries | Composer failed from 13:32:09 (**2.481 s case**), passed from 13:36:08 (**6.068 s**); progress case failed from 13:36:25 (**1.679 s**), passed from 13:37:13 (**1.875 s**) | Supplied runner timestamps and case durations. Focused command totals, repair time, review time, and gaps between commands are unknown. Subsequent task approvals were recorded at `f1ab0281`, `36e4f2a4`, and `c2d1e4a1`; UI approval was retained where inputs were unchanged. |
| Final full CLI/XPC run | Started 13:37:23; **75 s total**, including **72.594 s cases**; ended about 13:38:38 | Runner summary and [final bridge log](/tmp/stationai-bridge.12xDrw/bridge-tests.log). Cached build reused. All 56 cases passed, none skipped. |
| Handoff | After final run; duration unknown | Source fingerprint `c2d1e4a1`; routine UI runtime and screenshots did not apply. The definitive outcome could not be recorded on the task card: the supplied primary app CLI returned `Unknown task operation 'outcome'`; the linked worktree service correctly rejected the primary app's store, and the primary build identity guard rejected building linked source as `com.stationai.app`. The card may therefore remain In Progress until the primary app/XPC is rebuilt from this source. |

The card-to-final-run span was approximately **46 minutes of wall clock**, but card creation does not establish active agent start. Measured full-suite commands total **253 s**; focused case bodies add **12.103 s**, a lower bound because their setup and command overhead were not supplied. The 74 s first build was 42% of its 178 s command; the final run reused that build. Preparation, implementation, reviews, repairs, and idle gaps cannot be apportioned from the available timestamps.

## Verification ledger

| Phase | Fingerprint / inputs | Decision and evidence |
| --- | --- | --- |
| Static | Final source/test fingerprint `c2d1e4a1afd7b9048c17396b845876eef468158df897bc6e9b67d8f3a20ebdc9`; seven unstaged files listed by `git status --short` | Task verifier **APPROVED**; UI verifier **APPROVED**, retaining its approval after CLI-only fixture/assertion edits; architecture reviewer **APPROVED** on `3cf2b6b0`, with `BridgeCore.swift`, `CodexAppServerClient.swift`, and `StationAICLI.swift` unchanged afterward. Dependencies: implementation and CLI, paired UI/CLI tests, shared contract, and fixture scripts. Parity passed (56 cases); `git diff --check` passed; mock audit found none. |
| Runtime | Same behavioral fingerprint; main agent ran `scripts/test-e2e.sh` | First full run: 56 cases, 54 passed and two failed (`test_conversation_composer_rejects_blank_and_supports_live_turn_controls`, `test_task_progress_reports_publish_persist_and_clear`). Focused retries passed for composer/live controls (1/1, 6.068 s) and progress/outcome context (1/1, 1.875 s); an earlier retry of each exposed and led to repair of the queued-turn fixture and stale instruction expectation. Final full run: 56 passed, 0 skipped, 0 failed in 72.594 s case time / 75 s total. No UI suite or screenshots were run. |

Focused behavior case IDs reviewed and/or retried: `test_task_progress_reports_publish_persist_and_clear`, `test_task_progress_reports_clear_on_failed_turns_and_questions`, `test_task_store_serializes_cross_process_writes`, `test_task_status_transitions_and_rejects_unknown_status`, `test_conversation_serializes_concurrent_sends`, `test_conversation_composer_rejects_blank_and_supports_live_turn_controls`, `test_codex_questions_can_be_answered_over_cli_xpc`, `test_codex_nonblocking_question_keeps_task_in_progress`, `test_codex_empty_question_request_is_rejected`, and `test_codex_interrupted_turn_blocks_with_reason_and_can_retry`. The full runtime command executed all 56 contract case IDs exactly once; [the shared contract](/Users/niryo/.stationAI/worktrees/StationAI-fecfdf7df3d92662/726571756972652d6578706c696369742d636c692d7374617475732d666f722d7461736b2d7475726e73/StationAI/BridgeTests/BridgeTestContracts.json) is the authoritative full list.

Slowest named cases, measured in seconds (descending within each run):

| Rank | First full run | Final full run |
| --- | --- | --- |
| 1 | Composer/live turn controls 31.900 | Composer/live turn controls 5.756 |
| 2 | PR conflict detection 3.505 | PR conflict detection 3.905 |
| 3 | Dirty repository removal 3.219 | Task deletion 3.228 |
| 4 | Task deletion 3.219 | Done archive PR link 3.205 |
| 5 | Progress clearing on failed/question turns 3.084 | CLI/XPC question answers 2.650 |

## Findings and actions

1. **Make fixture outcome handoff identify each turn.** The first composer case took **31.900 s**, or 32% of its suite's 100.983 s of case time, and failed when its queued follow-up did not receive an outcome. The final version took **5.756 s** after the helper was changed to report an outcome for each observed turn. Give fixture turn markers a monotonically increasing turn identifier and have the helper acknowledge one outcome for each identifier before releasing it. This would make a missed queued turn fail at its handoff instead of after a long wait. Verify with the composer case's first-attempt result and duration on the next change to queued turns.

2. **Audit turn-state expectations before the first full run.** The initial full run found the queued fixture failure above and an “inactive” outcome assertion issued while a turn was still active. A later focused progress run found an outdated assertion about per-turn instructions. These required four focused case runs (**12.103 s of measured case time**) and a **75 s** final full run after repair. For changes to end-of-turn routing or developer instructions, add a static review step that inspects every affected CLI/UI case for initial, resumed, queued, active, and finished turns, including searches for status and `developerInstructions` assertions. Verify the next such task reaches its first full suite without fixture or expectation failures. This supplements the required parity and reviews; it does not change the verification gate.

## Timing gaps

The bridge logs emit individual case durations and the runner emits phase totals, so no new case timer is needed. The supplied task card and verification ledger do not expose the start/end of planning, edits, static reviewer work, or repair cycles; they also do not retain focused command totals. Obtain the conversation/tool timeline and complete runner transcripts for those exact intervals in the next workflow audit before proposing new logging. The observed command and case totals do not measure active agent time or user waiting.

The final task-outcome handoff also exposed an environment gap: the task board's supplied primary CLI predates this change, while the source worktree is linked and its XPC service isolates another app's task store. The repository build guard prevents producing the primary bundle identity from this linked source. Future task automation should route the final outcome through a CLI/XPC instance built with the same task-store profile as the active board card.

## Follow-up: thread-scoped instructions

The user questioned whether task guidance should be repeated on every turn. The implementation moved it from `turn/start` to `thread/start` for new threads and `thread/resume` for existing ones. A first-turn fallback on `turn/start` was tried, then removed after the full CLI/XPC suite showed that a fresh client per send caused it to repeat on later turns. The final paired case verifies both thread-level payloads and confirms no task instructions appear in any `turn/start` request.

| Phase | Fingerprint / inputs | Decision and evidence |
| --- | --- | --- |
| Static | `341e5a9c28363385243eefd7d782cac667fc08f816e9d278f19ed2f2b9dbab7b`; seven changed tracked source/test/contract files plus untracked report | Task verifier **APPROVED**; UI verifier **APPROVED** for `test_task_progress_reports_publish_persist_and_clear`; architecture reviewer **CONCERN**. Inputs included `BridgeCore.swift`, `CodexAppServerClient.swift`, `StationAICLI.swift`, shared contract, paired CLI/UI case, and fixture. Parity passed: 56 matching cases and expectations. `git diff --check` passed; mock audit found none. |
| Runtime | Same behavioral fingerprint; main agent ran focused and full `scripts/test-e2e.sh` | An intermediate full run with the fallback failed because later turns received it again. After removing it and refreshing static reviews, focused case passed (1/1, 2.546 s case time; 88 s total including an 83 s build). Final full suite passed 56/56 with zero skips or failures (75.421 s case time; 78 s total, cached build reused). No UI suite or screenshots were run. |

The architecture reviewer approved thread start/resume as the right API boundary but recorded a compatibility concern: `conversation.send` creates a fresh client, so each cold send reissues `thread/resume`; an upstream Codex report also describes a resume override missing from the first resumed model turn. A persistent per-thread client/context may be needed to avoid repeated resume payloads and guarantee first-turn visibility. The current change keeps the instructions out of every `turn/start` request and carries them in thread setup requests.
