# Plan Standalone Chat with Context Pages — standalone chat model separation

Task: "Plan Standalone Chat with Context Pages", final phase — replacing the hidden-`BoardTask` standalone chat with a separate `StandaloneChat` `@Model` behind a `ConversationSubject` protocol.
Commits: `aaf6de2` (merge master into branch), `6f12833` (model separation).
Report date: 2026-10-31. Scope: this task only.

## Timeline (partial)

Only durations printed by the runners are measured. No task card, verification ledger, or wall-clock start/end signal was supplied for this session, so phase boundaries below are ordered but mostly untimed. Nothing here is a reconstructed estimate unless labelled.

| # | Phase | Duration | Source |
|---|---|---|---|
| 1 | Resume merge of `master` (conflicts resolved in tree, uncommitted) | unknown | no timestamps available |
| 2 | First post-merge full suite — failed broadly | unknown (failed before completion report) | runner output not retained in evidence |
| 3 | Diagnose + repair two self-inflicted merge defects | unknown | — |
| 4 | Full suite, post-repair | **MEASURED 97/97 passed, ~424 s** | `test-e2e.sh` total |
| 5 | Separation refactor (`ConversationSubject`, `StandaloneChat`, migration) | unknown active time; used repeated `xcrun swiftc -typecheck` (seconds each) instead of full builds | — |
| 6 | Focused case runs | **MEASURED ~2–5 s/case**, except `test_standalone_chat_separate_model_and_pages_round_trip` at **MEASURED ~245 s**; build phase **MEASURED ~155 s cold, ~1 s cached** | `E2E case=… elapsed_seconds=…`, `E2E phase=build …` |
| 7 | Static review round 1 → `ui_verifier` APPROVED, `task_verifier` REJECTED (2 real bugs), `architecture_reviewer` CONCERN | unknown | — |
| 8 | Repairs: lookup rename, 6 wrong-side call sites, migration field copy, fixture rewritten to a genuinely pre-split store | unknown | — |
| 9 | Static review round 2 → `ui_verifier` REJECTED (6 dead migration lines), then APPROVED after repair; `task_verifier` APPROVED | unknown | — |
| 10 | Final full suite | **MEASURED 98/98, 0 skipped, ~422–430 s**, run 3× across the session | `test-e2e.sh` total |

Measured total of observed suite runs: roughly 424 + (3 × ~425) ≈ **~1700 s of full-suite runtime**, plus focused runs. Everything else — merge resolution, the refactor itself, all review turns — is unmeasured. The timeline is therefore partial: implementation and review are the largest uncovered intervals.

Slowest measured operations, ranked:
1. `test_standalone_chat_separate_model_and_pages_round_trip` — ~245 s, **~57 % of a ~430 s full run**, in a serial suite.
2. Cold `xcodebuild` phase — ~155 s (amortised to ~1 s when the content-matched cache hits).
3. All remaining 97 cases together — ~180 s.

## Telemetry audit

Sources checked before claiming any gap: the conversation/tool timeline supplied with this task, `scripts/test-e2e.sh` (`report_phase` emits `E2E phase=<name> elapsed_seconds=…` and `E2E total_seconds=…`), `scripts/test-bridge.py:7181` (`TimedTestResult` emits `E2E case=<name> elapsed_seconds=…` per case), and `scripts/ui-test-dashboard.py` (parses per-case UI durations).

- Per-case and per-phase CLI timing **is already emitted**. The gap is retention and aggregation: no script collects `E2E case=` lines across runs, so "which case dominates" had to be rediscovered by hand this session. Do not add new logging for this; add a collector.
- Agent-side phase timing (merge, refactor, each review turn) is genuinely not produced by any component in the repo. Recommending new telemetry here would mean instrumenting the agent harness, which is outside the repository; recorded as a known blind spot rather than an action.

## Recommendations

### 1. Fail fast on fixture syntax errors, and stop reporting them as provider failures

Evidence: during conflict resolution `scripts/fixtures/codex-app-server-fixture.py` kept a loop `continue` after master had refactored that handler into a function. The result was `SyntaxError: 'continue' not properly in loop`, which crashed the fixture, which surfaced through `Playhouse/App/CodexAppServerClient.swift:55` as *"The Codex app-server stopped unexpectedly. Codex CLI exited with status 1."* Every Codex-backed case failed with a message pointing at the provider. Cost: one full failing suite run (~minutes of runtime, phase 2 above) plus diagnosis, against a defect a `python3 -m py_compile` finds instantly. No `py_compile`/`compileall` check exists anywhere in `scripts/` or `.agents/` today.

Action: add `python3 -m compileall -q scripts/fixtures scripts/*.py` to the static block already at the top of `scripts/test-e2e.sh` (which runs `check-test-parity.py`, `check-button-feedback.py`, `check-e2e-locking.py` before the build phase). Separately, when a fixture process exits non-zero, have the fixture launcher surface the fixture's own stderr tail in the failure text so a fixture crash is not attributed to the provider.

Verify: introduce a deliberate syntax error in a fixture and confirm `scripts/test-e2e.sh` aborts in the static phase (seconds) instead of after the ~155 s build plus a failing suite.

### 2. Derive the bridge test's swiftc source list instead of hand-maintaining it

Evidence: `scripts/test-bridge.py:6238` holds `core = ["BoardTask", "ConversationSubject", …, "StandaloneChatStore", "BridgeCore"]`, a second hand-maintained copy of the list in `scripts/build-bridge.sh:40` (`shared_sources`). Adding `StandaloneChatStore.swift` to the app without updating the test list produced `cannot find type 'StandaloneChatMessage' in scope` — a compile failure inside a test case, discovered only at suite runtime after the build phase.

Action: add a check (either a new small script in the static block, or an assertion inside `check-test-parity.py`) that the `core` list in `test-bridge.py` is a subset of, and consistent with, `shared_sources` in `build-bridge.sh`. Both lists are literal and machine-readable; a ~20-line comparison covers it. A stronger variant is to have `test-bridge.py` read the list out of `build-bridge.sh` so only one copy exists.

Verify: add a new file to `shared_sources` without touching `test-bridge.py` and confirm the static check fails before the build phase.

### 3. Sanitise inherited bridge environment in `scripts/test-e2e.sh`

Evidence: every `scripts/test-e2e.sh` invocation this session had to manually unset `PLAYHOUSE_BRIDGE_SOCKET_PATH`, `PLAYHOUSE_DATA_DIRECTORY`, and `PLAYHOUSE_BRIDGE_SERVICE_NAME`, because master's single-daemon change made the session environment point at the *primary* app's daemon, producing `This Playhouse worktree app cannot open another app's task store.` (`Playhouse/App/BridgeCore.swift:260`). This cost a misdiagnosis cycle. `PLAYHOUSE_BRIDGE_SOCKET_PATH` is read by `Playhouse/CLI/BridgeClient.swift:13` and `Playhouse/App/DaemonClient.swift:29`; `grep` over `scripts/test-e2e.sh` shows it never unsets or validates any of the three.

Action: have `scripts/test-e2e.sh` explicitly `unset PLAYHOUSE_BRIDGE_SOCKET_PATH` (it sets the other two per run anyway) before the build phase, and print a one-line note when it does so. The run already owns an isolated data directory and service name, so inheriting a socket path can only point outside the run.

Verify: export `PLAYHOUSE_BRIDGE_SOCKET_PATH=/tmp/bogus.sock` and confirm the suite still reaches 98/98 instead of failing with the foreign-store message.

### 4. Collect the per-case durations the runner already prints

Evidence: `test-bridge.py` already emits `E2E case=… elapsed_seconds=…` for every case, and `test-e2e.sh` emits per-phase and total seconds — yet identifying that `test_standalone_chat_separate_model_and_pages_round_trip` (~245 s) is >half of a ~430 s serial run was manual work this session. The suite has no `--jobs`/parallel option, so one case sets the floor for every full run, and the harness foreground command timeout is 600 s against a ~430 s suite: a single new long case can push full runs past the timeout.

Action: add a small script that parses `E2E case=` / `E2E phase=` / `E2E total_seconds=` from a run log into a ranked table and appends it to the run's artifact directory (`test-e2e.sh` already creates `/tmp/playhouse-bridge.XXXXXX` and prints its path). No new logging required — parse only. Pair it with a warning threshold so a case crossing, say, 240 s is called out in the run's final output.

Verify: run the full suite once and confirm the artifact directory contains a ranked duration table naming the ~245 s case, and that the warning fires for it.

### 5. Strict-by-default naming for the widened subject lookup

Evidence: the `task_verifier` found two real bugs that a **green 98/98 full suite had not caught** — queuing a follow-up in the standalone chat threw `taskNotFound`, and the no-op branch of `setProvider` used a task-only lookup. Root cause is an inverted default: the permissive, subject-wide lookup inherited the plain name `requireTask`, so all pre-existing call sites silently widened and the author had to opt each one *back* into strictness. The architecture reviewer's CONCERN prompted the rename; the tree now has `requireTask` (strict, `BoardTask`) and `requireSubject` (permissive) in `Playhouse/App/BridgeCore.swift`, with six call sites corrected.

Action (process, not a rule change): when a refactor widens an existing type or lookup, give the *widened* member the new name and keep the old name on the narrow behaviour, so the compiler flags every site that must change rather than silently accepting them. Where that is impossible, delete the stored property or narrow the protocol first — the technique that worked here: removing the `isStandaloneChat` stored property made the compiler enumerate all 25 call sites, and typing repository state read-only on `ConversationSubject` marked every task-only path.

Verify: not script-checkable. The checkable residue is that both bugs now have CLI assertions and paired UI cases; confirm those two assertions fail if `requireSubject` is reverted to `requireTask` at those sites.

### 6. Static review before runtime evidence held up — keep the ordering

Evidence, stated because it contradicts the intuition that a green suite should gate first: the suite was green at 98/98 *while* two user-visible bugs were live, and both were found by reading, not running. Separately, the `ui_verifier` rejection caught six migration lines copying status/progress/timing that nothing asserted — dead code a passing suite cannot see. The existing AGENTS.md phase order (static barrier, then main-agent runtime) produced the right outcome here.

No action. Recorded so a future optimisation proposal does not try to move runtime evidence ahead of static review on the argument that it would have caught things sooner — in this task it would not have.

## Blind spots

- No measured duration for the merge resolution, the refactor, or any individual review turn. Closing this requires harness-level timestamps, not a repository change.
- The first post-merge full-suite failure (phase 2) has no retained duration; its runner output was not preserved into the evidence for this report. Recommendation 4 would retain it for future runs.
