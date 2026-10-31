# Workflow report — investigate claude task progress reporting

- Task: `45DE3465-BE8F-4D10-B097-876ED4E62F5D` — "investigate claude task progress reporting"
- Branch: `investigate-claude-task-progress-reporting`
- Date: 2026-10-27
- Timeline status: **partial**. No conversation transcript was available to this analysis. Phase boundaries come from the supplied verification ledger plus repository evidence; exploration, design, code authoring, and inter-round repair editing carry no timestamps at all.

Evidence sources checked: working-tree `git status --short` / `git diff` (7 files, +940/−606; `ClaudeCodeClient.swift` alone 980 changed lines), `Playhouse/BridgeTests/BridgeTestContracts.json` (87 cases; two renamed from serialization to parallelism, one added), `scripts/test-bridge.py` (renamed/added case functions, `TimedTestResult`), `Playhouse/PlayhouseUITests/PlayhouseUITests.swift` (same three paired case names), `scripts/test-e2e.sh`, `scripts/prepare-e2e-build.py`, `scripts/` inventory, `.codex/agents/workflow-optimizer.toml`, `docs/workflow-improvements/` filenames only.

## Work

Investigation found every Claude turn serialized through one shared `ClaudeCodeClient` behind `ClaudeTurnGate` (in-process queue plus a cross-process flock on `claude-primary-turn.lock`), so a follow-up turn for one task waited silently behind an unrelated task's turn. The change replaces that with a per-session `ClaudeSessionRunner` (one CLI process per conversation), deletes the gate, and moves turn results to per-thread accessors (`wasLastTurnInterrupted(threadID:)`, `lastTurnActivityDurations(threadID:)`, `diagnosticFields(forThread:_:)`, `pendingUserInputRequest(forThread:)`) plus a published `activeThreadIDs`.

## Timeline

| Phase | Duration | Basis |
|---|---|---|
| Exploration / design | unknown | not timed; no evidence source |
| Implementation (6 `xcodebuild build -quiet` runs, private derivedData) | ~6–24 min (est., midpoint ~15 min) | ledger: "roughly 1–4 minutes" each, not individually timed |
| Test authoring (contract + `test-bridge.py` + `PlayhouseUITests.swift`) | unknown | not timed |
| Focused CLI run #1 — failed | ~121 s+ | measured `E2E phase=build elapsed_seconds=121`; build failed on two Swift compile errors in the UI test file (`diagnosticEvents()` is throwing); **zero cases executed** |
| Focused CLI run #1 — 2 cases | 160 s total | measured `E2E total_seconds=160`; `E2E phase=build elapsed_seconds=153`; cases 2.725 s + 1.168 s |
| Focused CLI run #2 — 3 cases | 164 s total | measured `E2E total_seconds=164`; `Ran 3 tests in 5.081s`; build ≈155 s |
| Static review round 1 | 599 s blocked (247 / 397 / 599 aggregate 1243 s) | measured subagent durations; task REJECTED, UI REJECTED, architecture CONCERN |
| Static review round 2 | 348 s blocked (79 / 252 / 348 aggregate 679 s) | measured; all APPROVED |
| Static review round 3 | 82 s blocked (48 / 46 / 82 aggregate 176 s) | measured; all APPROVED after two non-blocking cleanups |
| Full CLI/XPC suite | 336 s total | measured `E2E total_seconds=336`; `Ran 87 tests in 180.398s`, 87 passed / 0 skipped; green on first run, no re-run |
| UI tests | not executed | routine verification reviews UI coverage only |

### Totals and uncertainty

- Measured CLI verification wall clock: **781 s (13.0 min)** = 121 + 160 + 164 + 336.
  - Of that, build phases ≈ **585 s (75 %)**; test execution ≈ **189.4 s (24 %)**.
- Measured static-review blocking wait: **1029 s (17.2 min)** across three rounds; aggregate reviewer compute **2098 s (35 min)**.
- Measured total (verification + review waits): **1810 s ≈ 30.2 min**.
- Unaccounted: exploration, design, implementation builds, code/test authoring, and repair editing between review rounds. Adding only the estimated implementation builds gives a lower bound near 36–54 min; actual task wall clock is unknown and is **not** reconstructable from the available sources.

### Slowest operations

1. Static review round 1 blocking wait — 599 s (longest of three reviewers), ended in two rejections.
2. Full CLI/XPC suite — 336 s (180.4 s cases, ~156 s build).
3. Static review round 2 blocking wait — 348 s.
4. Focused CLI run #2 — 164 s wall clock for 5.081 s of case execution (3.1 % useful).
5. Focused CLI run #1 — 160 s wall clock for 3.893 s of case execution (2.4 % useful).
6. Failed focused build — 121 s with no case executed.

Slowest individual cases: only `test_conversation_runs_concurrent_claude_sends_in_parallel`-era focused timings survived (2.725 s and 1.168 s). The 87 per-case `E2E case=` lines from the full run were emitted but not retained — see Telemetry gaps.

## Recommendations

### 1. Make the E2E build cache incremental instead of clean-per-fingerprint

Observed: `scripts/prepare-e2e-build.py` sets `cache_path = cache_root / f"{root_key}-{fingerprint}"` and `derived_data = cache_path / "DerivedData"`. Any change to a fingerprinted file therefore produces a brand-new, empty DerivedData directory and a full clean `xcodebuild build-for-testing`. Measured cost this task: 121 s + 153 s + ~155 s + ~156 s ≈ **585 s, 75 % of all CLI verification wall clock**, while the two focused runs it gated executed 3.893 s and 5.081 s of tests. `PlayhouseUITests.swift` is not in the fingerprint exclusion list (unlike `test-bridge.py` and `BridgeTestContracts.json`), so each UI-test edit during review repairs also forced a clean rebuild.

Action: keep the fingerprint as the cache *validity* key (manifest + `cache_bundle_is_valid()` + the existing post-build re-check and `flock`), but point `derived_data` at a single per-worktree path such as `cache_root / root_key / "DerivedData"` so xcodebuild recompiles only changed files.

Verify: run `scripts/test-e2e.sh --case <id>` twice with one Swift file edited between runs and compare `E2E phase=build elapsed_seconds=`; expect the second run well under the ~155 s observed here.

### 2. Share one DerivedData between implementation compile checks and the E2E build

Observed: the 6 implementation `xcodebuild build -quiet` runs used a **private** derivedData path, separate from the E2E build cache. None of them warmed the cache that the subsequent test runs then rebuilt from scratch, so an estimated 6–24 min of compile work was discarded before 585 s of measured rebuild.

Action: run implementation compile checks through `scripts/prepare-e2e-build.py` (or against the same derivedData path it uses), so the first `scripts/test-e2e.sh` invocation hits a warm cache. This compounds with recommendation 1 and does not change what is built — `build-for-testing` with `-only-testing:PlayhouseUITests/PlayhouseUITests` already compiles both the app and the paired UI test target, which is also what caught the `diagnosticEvents()` throwing errors.

Verify: after an implementation compile check, the next `scripts/test-e2e.sh` prints "Reusing matching E2E build" or a build phase far below 150 s.

### 3. Surface the per-case timings the suite already emits

Observed: `TimedTestResult.stopTest` in `scripts/test-bridge.py` writes `E2E case=<name> elapsed_seconds=<n>` for every case, and `scripts/test-e2e.sh` tees the whole stream to `${test_output_dir}/bridge-tests.log` inside a `mktemp -d /tmp/playhouse-bridge.XXXXXX`. Nothing ranks or summarizes it, so the 180.398 s of full-suite case time this task could not be attributed to any case; only the aggregate line survived into the ledger. This is unretained data, not missing instrumentation.

Action: in `scripts/test-e2e.sh`'s `cleanup`, parse `${bridge_log}` for `E2E case=` lines and print the slowest N alongside the existing `E2E total_seconds=` line. No new instrumentation required.

Verify: a full run ends with a ranked slowest-case list covering all 87 contract cases.

### 4. Pre-check per-thread accessor coverage before launching static review round 1

Observed: round 1 cost 599 s of blocked wait and returned task REJECTED (activity-duration coverage gap), UI REJECTED (no in-process parallelism coverage, no visible parallelism assertions, per-thread state uncovered), architecture CONCERN (edge-lossy aggregate `isTurnActive`, misattributed client-level diagnostics). All three findings map directly onto the diff's own shape: it deletes `isTurnActive(threadID:)`/`isTurnActiveInProcess(threadID:)`/`activeTurnOwnerProcessID(threadID:)` and introduces `wasLastTurnInterrupted(threadID:)`, `lastTurnActivityDurations(threadID:)`, `diagnosticFields(forThread:_:)`, `pendingUserInputRequest(forThread:)`, and `activeThreadIDs`. Three rounds were needed; measured blocked total 1029 s.

Action: before launching round 1 on a change of this shape, enumerate each added or removed per-thread accessor from the diff and confirm each has both a CLI assertion in `scripts/test-bridge.py` and a visible assertion in the paired UI case, and that any surviving aggregate state is named in the review brief as a known boundary question.

Verify: rounds-to-approval (3 this task) and total blocked review seconds (1029 s this task) on the next comparable per-thread state change.

### 5. Reopen only the reviews whose inputs changed after non-blocking cleanups

Observed: round 3 ran all three reviewers (48 s / 46 s / 82 s, aggregate 176 s, 82 s blocked) to confirm two cleanups already labelled non-blocking. AGENTS.md already permits retaining approvals whose relevant inputs are unchanged, with a recorded explanation; this task re-ran the full fan-out instead.

Action: record each review's input file set at approval time, and after a repair reopen only the reviews whose recorded inputs intersect the new diff.

Verify: a cleanup touching only `ClaudeCodeClient.swift` reopens the architecture and task reviews but retains the UI coverage approval with a recorded reason.

## Telemetry gaps

- **Exploration, design, test authoring, and inter-round repair editing have no timestamps in any source.** These are the largest unmeasured intervals in the task; nothing in the repository emits phase markers for them.
- **Implementation `xcodebuild build -quiet` runs are untimed** and emit no `E2E phase=` marker, so the 6 runs are only an estimate ("1–4 minutes each"). Recommendation 2 would also bring them under the existing build-phase instrumentation.
- **Per-case durations for the 87-case full run were emitted and tee'd but not retained** (see recommendation 3); only `Ran 87 tests in 180.398s` survived, so no case-level ranking was possible for the single largest verification run.
- **`E2E build cache lock wait_seconds=` is emitted by `prepare-e2e-build.py` but was not captured** for any of the four runs, so lock wait cannot be separated from actual compile time inside the ~153–156 s build phases. Capturing this line alongside `E2E phase=build` would confirm whether recommendation 1 targets the right component.
- **Subagent review durations are measured but opaque internally** — no split between reading, analysis, and report writing, so the 1243 s round-1 aggregate cannot be attributed further.

## Carried follow-ups recorded during review (not closed by this task)

- `CodexAppServerClient` retains the same single-`activeThreadID` / single-handler-set shape removed from Claude here.
- `ClaudeSessionRunner.stopProcess()` busy-waits on the MainActor with `Thread.sleep` for up to 1.5 s.
- The Claude fixture's `<executable>.history` read-modify-write is unlocked and is now exercised by genuinely parallel fixture processes.
- `interruptedThreadIDs`, `activityDurationsByThread`, and `lastTurnDiagnosticsByThread` are unpruned.
