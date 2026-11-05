# Workflow report: provider switch QA and leaked outcome echo

- Date: 2026-10-24
- Task: "Switching Claude ⇄ Codex: live QA with haiku and gpt-6-luna, fix issues" (leaked `playhouse-cli task outcome <id> completed` line at the end of a Codex final answer after a Claude→Codex switch). No task ID.
- Evidence checked: main-agent ledger (supplied); `/tmp/playhouse-qa/run1.log`, `e2e.log`, `e2e2.log`, `focus.log`; file mtimes in `/tmp/playhouse-qa/`; Xcode `LogStoreManifest.plist` in `/tmp/playhouse-qa/dd/Logs/Build`; `/tmp/playhouse-bridge.*` run directories and their `bridge-tests.log`; E2E build cache directory mtimes; `scripts/test-live-integration.{sh,py}`; `scripts/fixtures/codex-app-server-fixture.py`. I did not have the task conversation.
- Times are local (UTC+3). "Measured" means the time came from a log or tool output. "Derived" means it was worked out from file mtimes or log timestamps. "Estimated" means it came from the ledger with no timestamp behind it.

## Timeline (partial)

The task start is not visible. The first artifact is the QA build start at 13:41:07, and the last is the final suite end at 14:23:46, so the observed window is 42m39s (derived). Orientation (ledger step 1) happened before 13:41 and has no recorded duration.

| # | Phase | Window / duration | Basis |
|---|---|---|---|
| 1 | Orientation, rollout inspection (root cause 1) | unknown, "a few minutes" | estimated (ledger) |
| 2 | First QA bundle build (`/tmp/playhouse-qa/dd`) | 13:41:07–13:42:26, 79.6s | measured (Xcode manifest) |
| 2 | QA fixture prepared | 13:42:27 | derived (mtime) |
| 3 | Live QA round 1, 12 provider turns | ends 13:45:42; turns sum to 150s (10–20s each) | measured per turn (run1.log, 1s resolution) |
| 4–7 | Replays ×6, Codex baseline ×6, isolation ×6, two reverted prompt experiments, implementation, 4 QA rebuilds, live QA round 2 | ~13:45:42–14:09:22 (~23.7 min) overall, no per-step breakdown | derived window; contents from ledger |
| 2 | Last retained QA rebuild | 14:04:47–14:05:58, 70.8s | measured (Xcode manifest) |
| 8–10 | Static reviews: round 1 (max 106s), round 2 (max 65s), narrow task re-review (91s) | about 262s of reviewer wall time. The rounds ran one after another; reviewers within a round ran in parallel | measured per reviewer (ledger) |
| 11 | Full E2E #1 | 14:09:22–14:13:15, 233s: build cache miss 106s, fixture 2s, cases 125s; 63/64 | measured (e2e.log) |
| 11 | Focused retry 1 (same failure: empty final) | 14:14:16, case 2.37s | measured (`playhouse-bridge.vkwYRv`) |
| 11 | Focused retry 2 (same failure) | 14:15:27, case 2.21s | measured (`playhouse-bridge.xHOQu9`) |
| 11 | Inspection, manual fixture drive (hung until 120s tool timeout), fixture fix, E2E rebuild `594e1da6` | 14:15:29–14:20:15, ~4.8 min | derived window; 120s hang from ledger |
| 11 | Focused retry 3: new failure, `conversation history` missing `PLAYHOUSE_E2E_CODEX_EXECUTABLE` | 14:20:17, case 3.25s | measured (`playhouse-bridge.MFdTUW`) |
| 11 | Focused retry 4: pass | 14:20:37, total 5s | measured (focus.log) |
| 12 | Static re-review (task 18s, UI 41s, in parallel) | ~14:20:40–14:21:39 | measured per reviewer; window derived |
| 13 | Final full E2E: 64/64, 0 skipped | 14:21:39–14:23:46, 127s (cases 124s, build reused) | measured (e2e2.log) |

Phase totals that are supported by evidence:
- QA builds: 150.4s across the 2 retained logs. The ledger records 5 QA builds, but only 2 have retained logs.
- Round 1 live turns: 150s.
- Static review wall time: ~262s through round 2, plus ~41s for the re-review.
- Runtime verification: 14:09:22–14:23:46 = 14m24s. That splits into full suite #1 (233s), the repair loop (8m24s, from 14:13:15 to 14:21:39), and the final suite (127s).

The ~23.7 min between 13:45:42 and 14:09:22 holds most of the task's discovery and implementation work. It has no per-step evidence, so I cannot split it into experiment, build, implementation and review time.

Slowest measured operations:
1. E2E build cache miss: 106s
2. Full case phase: 125s and 124s
3. First QA xcodebuild: 79.6s
4. Last QA xcodebuild: 70.8s
5. Manual fixture-drive hang: 120s (ledger)

The slowest individual cases were stable across both full runs:
- `test_task_done_preserves_worktree_and_branch`: 24.95s / 24.24s
- `test_review_pr_conflicts_probe_and_verify`: 14.61s / 13.94s
- `test_conversation_composer_rejects_blank_and_supports_live_turn_controls`: 5.86s / 6.85s

Together these are about 36% of the case phase. They are not related to this task's change.

## Recommendations

### 1. Make repeated live runs and control comparisons a built-in runner mode
- **Evidence:** Two prompt-wording experiments were made and then reverted. Each needed a QA rebuild (70.8–79.6s measured per build) and 8 live replays (10–20s per turn, measured in round 1). The isolation experiment run afterwards showed Luna skips the outcome call on the first turn with no switch involved (3/6 skipped on a plain first message, 4/6 on a handoff). That made both experiments unnecessary. The replay, baseline and isolation batches ran from scratch scripts, and their outputs were not kept (only `run1.log` exists). `scripts/test-live-integration.py` accepts `--scenario` but has no repeat or pass-rate option.
- **Cost:** two rebuilds (~2.5 min, estimated from the measured build times) plus 16 live replays (time not retained) were spent on changes that were reverted.
- **Action:** add `--repeat N` (with optional parallelism) to `scripts/test-live-integration.py`. It should print a per-scenario pass rate and per-run durations, and write them to a retained log. For a provider-reliability symptom, run the unmodified control scenario with the same N before editing prompts.
- **Verify:** the next intermittent live failure produces a control rate and a treatment rate from runner output, with no scratch scripts, and prompt-change rebuilds happen only after the control rate is recorded.

### 2. Make the Codex fixture report which branch handled each turn
- **Evidence:** The fixture has two hold-release paths: the marker-file check `Path(argv0 + ".hold-release")` at `scripts/fixtures/codex-app-server-fixture.py:356`, and the mode check `"-hold-release" in mode` at line 829. The echo was added to the wrong one. Focused retries 1 and 2 (14:14:16 and 14:15:27) failed with the identical empty-final assertion. The following ~4.8 min included a manual fixture drive that blocked until the 120s tool timeout (the fixture's hold loops wait up to 30s for release files). The fixture writes no trace of which path served a turn.
- **Cost:** two uninformative focused runs and ~4.8 min (derived) of inspection, about 2 min of which was the hang.
- **Action:** have the fixture append `turn=<n> branch=<name> mode=<mode>` to `<argv0>.trace`, and have `scripts/test-bridge.py` include that file's contents in assertion-failure output for fixture-backed cases.
- **Verify:** the next fixture-routing failure is identified from the first failing run's log, without a manual fixture drive.

### 3. Map each changed behavior to a CLI assertion before requesting static review
- **Evidence:** The task verifier rejected twice, each time for the same reason: a new code path with no test coverage. Round 1 rejected the Claude merge fix. Round 2 rejected the handoff fallback, which was then removed and needed a narrow re-review. That round and its re-review took 65s + 91s of reviewer time, plus repair time that was not recorded.
- **Action:** include a table in the static-review request that pairs each changed product branch with the CLI case ID, the assertion, and the paired UI case. The implementing agent fills it in before starting reviewers, and any branch without a row is either covered or removed before review.
- **Verify:** count task-verifier coverage rejections per source task. The target is zero.

### 4. Measure live-integration build cost before deciding whether to cache it
- **Evidence:** `scripts/test-live-integration.sh` builds into `Playhouse-Live-Integration-<uuid>`, a fresh DerivedData directory on every run, unless `PLAYHOUSE_APP_PATH` is set. It does not print a build duration. Separately, this task built the QA bundle (`/tmp/playhouse-qa/dd`) and the E2E cache (cache miss, 106s), and these builds did not share output. I could not tell whether the step-9 live scenarios rebuilt or reused `PLAYHOUSE_APP_PATH`.
- **Action:** print `live phase=build elapsed_seconds=…` in `test-live-integration.sh`, matching the E2E phase lines. Once it is measured, decide whether a content-keyed DerivedData path is compatible with the per-run bundle identifier the script sets.
- **Verify:** live runs report their build time, and repeated runs on unchanged sources show whether they paid for a cold build.

## Telemetry gaps
- **Task start, orientation and step boundaries:** missing. The ledger did not capture wall-clock times, and I had no conversation timeline.
- **Replay, baseline, isolation and prompt-experiment outputs:** not retained. Only `run1.log` exists, so I cannot measure the counts or durations of the 13:45–14:09 work.
- **QA rebuilds:** the ledger records 5, but `/tmp/playhouse-qa/dd` retains logs for only 2 (79.6s and 70.8s). The other 3 either used another path or were not retained.
- **Live QA round 2 and step-9 live scenarios:** the console output was not saved. Only the cross-provider handoff time (40.0s) is in the ledger.
- **Static reviewer durations:** come only from the ledger. Repair time between review rounds is unknown.
- **Active agent time vs tool wait:** cannot be separated from the available evidence.
