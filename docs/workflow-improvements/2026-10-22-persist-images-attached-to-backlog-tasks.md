# Persist images attached to backlog tasks

Task ID: `3C5813BD-7A66-40FA-A75A-CE2F229FF8CB`  
Client date: 2026-10-22 (Asia/Jerusalem)

## Timeline and measured cost

This is a partial timeline. The task progress supplied the operation order and final verification totals, but no start/end timestamps for investigation, editing, static review, or handoff.

| Sequence | Operation | Duration | Evidence |
| --- | --- | ---: | --- |
| 1 | Investigated disappearance and traced it to view-only `pendingImages` state | Unknown | Task progress report; no timestamp |
| 2 | Added SwiftData image payload and optional-column repair, CLI/XPC save and validation, UI restore/removal, board-list payload exclusion, and paired image case | Unknown | Task progress report and seven changed source/contract files; no timestamp |
| 3 | Static parity and three parallel reviews | Unknown | Parity 56/56; task, UI, and architecture reviewers approved; no review timestamps |
| 4 | One full `scripts/test-e2e.sh` run: build, fixture, 56 cases | **189 s** total | Supplied phase record; whole-second phase timing |
| 5 | Reporting/handoff | Unknown | No completion timestamp supplied |

The run's reported phases were build **87 s** (46%), fixtures **2 s** (1%), and cases **100 s** (53%). They sum to the reported **189 s** at whole-second resolution; static checks and runner overhead cannot be separated within that resolution. The full task's wall-clock and active agent time remain unknown; no user-wait or agent-work duration can be inferred for the unobserved phases. There was no recorded failed run, retry, UI runtime run, or screenshot for this task.

The slowest named cases cannot be ranked from the supplied verification summary. The runner prints per-case durations, but this task's artifact path was not included in that summary.

## Practical improvements

1. **Retain the existing verification artifact path in the task ledger.** The handoff preserved the 189 s phase summary but omitted the bridge log path, although `scripts/test-e2e.sh` prints it and `scripts/test-bridge.py` already records every case duration. Record that path and the build cache hit/miss and lock-wait lines with future full-run results. Verify by generating the slowest-case ranking and cache state directly from the next task ledger. This closes an evidence access gap; it does not require new test logging.

2. **Investigate the 87 s build phase before changing the suite.** It used 46% of the observed run. The build helper already prints cache hit/miss and lock wait, but those lines were not available in the supplied progress record; the phase alone cannot identify compilation, a cache miss, or waiting as the cause. Preserve those existing lines on the next source-change run and compare build duration with cache state. A repeated 87 s cache hit would justify profiling the helper; a miss would establish the baseline cost of rebuilding changed inputs.

## Evidence limits

Checked the supplied task progress and verification record, changed-file scope, `scripts/test-e2e.sh`, `scripts/test-bridge.py`, and repository files for a task progress ledger. The runner emits phase and per-case timing and the build helper emits cache status and lock wait. No task-specific review timestamps, implementation timestamps, exact build cache result, artifact path, or complete command transcript were supplied. The observed 189 s covers runtime verification only; it cannot be reconciled to a full task duration without task start and completion timestamps.

## Verification ledger

- **Unstaged source/test fingerprint:** `739392684472681febb5a9a04e7bcdfad2353ef9ce997c86aab9b175b0c24c7a` (unchanged at runtime start/end). The task-specific workflow report is documentation only and was added after runtime verification.
- **Static phase:** `scripts/check-test-parity.py` passed with 56 matching CLI/UI cases; `git diff --check` passed. `task_verifier` and `ui_verifier` approved; `architecture_reviewer` approved after confirming image payloads are excluded from list records. Review inputs covered the seven unstaged source, test, and contract files; no staged-only or untracked files were in scope at review time.
- **Runtime phase:** One full `scripts/test-e2e.sh` run passed all 56 CLI/XPC cases, with 0 failures, skips, or incomplete cases. Build: 87 s; fixtures: 2 s; cases: 100 s; total: 189 s. The new paired case was `test_conversation_sends_image_attachments`.
- **UI workflows:** No UI runtime suite, direct app session, or screenshot was used. The UI verifier statically approved the visible attachment, persistence, rejection, and reopen assertions.
- **Mock audit:** No new mocks, stubs, fakes, or simulated implementations were added.
