# Workflow report: Claude Code protocol fixture and paired test

- Task: Add a deterministic Claude Code stand-in fixture and paired test (follow-up; the user explicitly authorized a fake Claude program)
- Date: 2026-10-24
- Paired case: `test_claude_answer_stays_final_around_outcome_report`
- Evidence checked: the caller's verification ledger, `/tmp/stationai-qa/claude-case.log`, `/tmp/stationai-qa/mutant.log`, `/tmp/stationai-qa/e2e3.log` (file mtimes and lock timestamps), `scripts/prepare-e2e-build.py`, and `StationAI/StationAIUITests/StationAIUITests.swift`. The conversation transcript was not available to this analysis.

## Timeline (partial)

Times are UTC. Start times are derived by subtracting the logged phase durations from the `.bridge-run.lock` `queued_at` timestamps; end times come from log mtimes (local time is UTC+3).

| Phase | Window | Duration | Basis |
|---|---|---|---|
| Context gathering | before 14:57 | unknown | No timestamps in the ledger |
| Implementation (including one failed atomic insertion and one malformed no-op shell command) | before 14:57 | unknown | No timestamps |
| Focused CLI smoke (`claude-case.log`) | ~14:57:24–14:59:23 | 119 s (static 1, build 113, fixture 2, case 2.9) | Measured |
| Applying the mutation | ~14:59:23–14:59:32 | ~9 s | Derived from timestamps |
| Mutation run (`mutant.log`, failed as expected) | ~14:59:32–15:01:26 | 114 s (build 110, case 1.6) | Measured |
| Source restore, static round 1, UI-test repair, static round 2 | ~15:01:26–15:04:40 | ~194 s wall-clock | Derived from timestamps; see inconsistency below |
| Static round 1 | — | architecture ~30 s (CONCERN), task ~44 s (APPROVED), UI ~103 s (REJECTED) | Ledger-reported, approximate |
| Static round 2 | — | task ~17 s (APPROVED), UI ~165 s (APPROVED) | Ledger-reported, approximate |
| Full CLI/XPC suite (`e2e3.log`) | ~15:04:40–15:08:40 | 241 s (static 0, build 111, fixture 1, cases 129) | Measured; 65/65 passed, 0 skipped |
| Reporting and handoff | after 15:08:40 | unknown | No timestamps |

Observed window: about 676 s (~11.3 min), from the start of the smoke run to the end of the full suite. The task's full duration is unknown because neither implementation nor reporting has timestamps.

Unresolved inconsistency: the ledger's sequential reviewer durations (103 s + 165 s = 268 s for the slowest reviewer in each round), plus the repair edits, exceed the ~194 s gap between the end of the mutation run and the start of the full-suite build. Either round 1 overlapped the mutation run, or the reported durations are approximate or measured differently. Overlap would be a concern: reviewers would have read the mutated `ClaudeCodeClient.swift`. The evidence available here cannot tell which explanation is correct.

### Time shares within the observed window (measured)

- E2E builds: 334 s (113 + 110 + 111), about 49%. All three were cache misses.
- Case execution: 2.9 + 1.6 + 128.0 ≈ 132.5 s, about 20%.
- Review, repair and restore: about 194 s wall-clock, about 29% (derived).

### Slowest cases in the full run (measured; 65 cases, 127.98 s in total)

1. `test_task_done_preserves_worktree_and_branch`: 24.8 s
2. `test_review_pr_conflicts_probe_and_verify`: 14.3 s
3. `test_conversation_composer_rejects_blank_and_supports_live_turn_controls`: 6.0 s
4. `test_conversation_steers_and_queues_active_turn`: 4.8 s
5. `test_codex_interrupted_turn_blocks_with_reason_and_can_retry`: 3.6 s

The first two cases take 39.1 s, about 31% of case time. The new case took 2.9 s in the focused run and 1.9 s in the full run, so it added very little.

## Recommendations

### 1. UI-test-only edits invalidate the headless E2E build cache

- Evidence: the UI repair between the smoke run and the final run changed only `StationAIUITests.swift`. The final run still logged `Building E2E cache miss eddc27c08240c042` and spent 111 s building. `scripts/prepare-e2e-build.py` `source_fingerprint()` hashes every tracked or untracked file outside a short exclusion list, and that list does not exclude `StationAI/StationAIUITests/`. The build also runs `xcodebuild build-for-testing -only-testing:StationAIUITests/StationAIUITests`, even though neither `scripts/test-e2e.sh` nor `scripts/test-bridge.py` refers to the UI test bundle. The build also compiles UI tests, which is where the two UI-test warnings in every log come from. `scripts/fixtures/*.py` are hashed too, although `test-bridge.py` reads them at runtime from the repository.
- Cost: 111 s per UI-test-only repair cycle on the headless suite, measured once in this task.
- Action: check whether the app or CLI target embeds anything from `StationAI/StationAIUITests/` or `scripts/fixtures/`. If it does not, exclude those paths from `source_fingerprint()`. Then decide whether the headless build can use the app scheme's `build` instead of UI `build-for-testing`, keeping the UI runner's own build separate.
- Verify: change only the UI test file, run `scripts/test-e2e.sh --case <id>`, and expect `Reusing matching E2E build` with `phase=build` close to 0 s.

### 2. Every E2E cache miss is a clean build, about 110 s

- Evidence: three misses took 113, 110 and 111 s. The mutation run changed one branch in one Swift file and still took 110 s, because each fingerprint gets a new `cache_root/<root>-<fingerprint>/DerivedData` directory.
- Cost: about 334 s, roughly half of the observed window.
- Hypothesis: seeding a new miss's DerivedData from the newest same-worktree cache entry, for example with an APFS clone (`cp -c -R`), would let xcodebuild build incrementally. The post-build `source_fingerprint() != fingerprint` guard and the manifest still protect cache integrity.
- Verify: compare `E2E phase=build elapsed_seconds` for a one-file Swift change before and after the change.

### 3. Fixture launch environment is duplicated across UI launch paths

- Evidence: `STATIONAI_E2E_CLAUDE_EXECUTABLE` is injected separately at four sites in `StationAIUITests.swift`: `app.launchEnvironment`, two `environment[...]` dictionaries, and `opener --env`. The Codex variable is likewise set at many individual call sites. The ledger records that one scripted insertion failed because its anchor env block occurred twice.
- Cost: one failed edit plus a retry. The duration is unknown because there are no timestamps.
- Action: build provider-fixture launch environment in a single helper that all four launch paths consume, so the next provider or override needs one edit.
- Verify: adding a new fixture variable touches one site.

### 4. The UI review was rejected for content that collapses after a turn settles

- Evidence: static round 1 UI review was REJECTED after about 103 s. Its visibility checks raced the post-turn commentary collapse, and a relaunch check could not detect demotion. That led to static round 2 (UI about 165 s) and a UI-test repair. The repair added `waitForSettledTurn()` as a function nested inside this one case (line ~3932), not as a shared helper.
- Cost: one extra UI review round of about 165 s, plus repair time (unknown).
- Action: promote the settled-turn wait and the "expand disclosure, then assert" positive control into shared UI-test helpers. Then have `scripts/check-test-parity.py`, or the UI coverage checklist, flag conversation-content visibility assertions that do not use them.
- Verify: count UI-review rejections citing collapse or settle races in later conversation-rendering tasks.

## Telemetry gaps

- No timestamps exist for context gathering, implementation, the failed or no-op tool calls, reviewer start and end, or reporting, so active agent time cannot be separated from wait time. The source that would need to provide them is the agent conversation/tool timeline, which was not available to this analysis.
- Reviewer durations are ledger approximations with no start times. Overlap with the mutation run cannot be confirmed or ruled out. Recording reviewer start and end times next to the change fingerprint in the verification ledger would resolve this.
- The E2E logs report per-phase and per-case durations but not the build's start wall-clock time. Here it was derived from the lock `queued_at` timestamp minus the phase durations.
