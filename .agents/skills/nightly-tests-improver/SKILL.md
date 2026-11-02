---
name: nightly-tests-improver
description: Unattended nightly round over Playhouse's visible UI suite in the Tart VM - run everything, root-cause and fix failures and flakiness, find and remove slow spots without dropping checks, raise test quality, review the changes, confirm green, then commit and push.
---

# Nightly tests improver

Use this skill when explicitly invoked (for example from a nightly schedule). One
invocation is one improvement round: it leaves the UI suite at least as green and
at least as fast as it found it, with every change reviewed, and ends with a
scoped commit pushed to the current branch's upstream. Explicit invocation of this
skill is authorization for that path-scoped `git add`, `git commit`, and `git push`,
as `AGENTS.md` states. It never includes pre-existing staged changes.

Principles that made the previous rounds work:

- Evidence before edits. Every fix names the artifact that proved the cause (a
  diagnostics line, a screenshot, a kernel log line, a profile). A fix that did
  not change the outcome is removed, not kept "just in case".
- Fix the cause, never the assertion. Waiting for a *real* settle condition is a
  fix; widening a timeout or deleting a check is not.
- The suite must stay independent of the real Codex and Claude CLIs and of
  sign-in. Any case that reaches `/opt/homebrew/bin/codex` or a real `claude` is a
  bug (set a fixture executable).
- Temporary tracing is allowed and encouraged while diagnosing; remove it before
  the final run.
- Reproduce order-dependent failures in order. The single-session runner executes
  cases alphabetically inside one daemon and one test-runner process; a case that
  passes alone and fails in the full run is leaking state from an alphabetically
  earlier case.

## Round structure

1. **Baseline.** Read `AGENTS.md`, this file, `scripts/test-ui.sh`,
   `scripts/test-ui-tart.sh`, and `Playhouse/BridgeTests/BridgeTestContracts.json`.
   Record `git status --short` and `git diff --stat`; note any pre-existing staged
   or unstaged paths so they are never swept into the final commit. Confirm the
   Tart VM `playhouse-ui` is available (`export PATH=/opt/homebrew/bin:$PATH; tart list`).

2. **Full run with instrumentation.** Start the daemon memory sampler in the VM,
   then run the full suite:

   ```bash
   export PATH=/opt/homebrew/bin:$PATH
   tart exec playhouse-ui /bin/bash -c 'rm -f /tmp/daemon-mem.log; nohup bash -c "while true; do p=\$(pgrep -x playhouse-daemon | tail -1); [ -n \"\$p\" ] && echo \"\$(date +%H:%M:%S) pid=\$p rss_mb=\$(( \$(ps -o rss= -p \$p) / 1024 ))\"; sleep 20; done" > /tmp/daemon-mem.log 2>&1 &'
   scripts/test-ui-tart.sh > "$SCRATCH/full1.log" 2>&1
   ```

   Run it in the background and wait for completion; a full run takes about 50
   minutes. Collect from the log: `Visible UI suite:` totals, every
   `Test Case ... (passed|failed) (N seconds)` line (the per-case duration table),
   the xcodebuild invocation (confirms `-test-timeouts-enabled YES` and the
   allowances), and from the VM: `/tmp/daemon-mem.log` (peak RSS; it should stay
   under about 100 MB for the whole run), the daemon log
   `/private/tmp/playhouse-bridge/501/<hash>.sock.log` (every `listening` line is
   a daemon start; one without an `idle, exiting` before it is a death), and the
   artifacts directory on the host under
   `/tmp/playhouse-ui-tart-artifacts/<run>/playhouse-ui.*/` (`bridge-watcher.log`
   lists daemon deaths as `watcher exited rc=69`, plus the single `.xcresult`).

3. **Triage every failure to a root cause.** For each failed case gather, in this
   order, and stop when the cause is proven:
   - The `error:` line and the last `Waiting Ns for ...` step before it in the
     xcodebuild log; the step timeline (`t = ...s`) aligned with daemon timestamps.
   - Attachments: `xcrun xcresulttool export attachments --path <xcresult> --output-path <dir>`;
     `manifest.json` maps the failure screenshot and
     `failure-accessibility-hierarchy` per test. Read the screenshot. The hierarchy
     tells whether the app was on the board or inside a task, and what the form
     actually contained.
   - The case's preserved app data: failed cases keep
     `/tmp/playhouse-ui-test-data/PlayhouseUITests-<uuid>/` in the VM.
     `data/Diagnostics.jsonl` has every bridge request (`command`, `argument.*`,
     `dataDirectory`), provider events (`codex.app_server.started/exited` with
     `codexPID` and `executable`, `codex.rpc.request.started` by `method`,
     `codex.turn.*`, `claude.*`), persistence and lifecycle writes, and
     `provider.output.handling_stalled` when a provider message handler is stuck.
     A request sent to a `codexPID` the case never started means cross-case state.
   - The VM unified log for the failure window:
     `log show --start "YYYY-MM-DD HH:MM:SS" --end "..." --style compact --predicate '...'`.
     Known killers: `eventMessage CONTAINS "killing largest compressed process"`
     (kernel jetsam of the daemon, a memory leak), `CacheDeleteAppContainerCaches
     requesting termination` (macOS purged the sandboxed test runner under disk
     pressure), `exited due to SIGTERM | sent by xcodebuild` (normal teardown).
   - Live profiling if the daemon misbehaves: trigger on RSS in the sampler loop and
     run `sample <pid> 4 -mayDie -file ...`, `vmmap --summary <pid>`, `heap <pid>`
     (class histogram: millions of `Closure context` / `__NSMallocBlock__` means a
     dispatch queue piling up), `lsof -p <pid>`.
   - The daemon's design facts that matter: one daemon serves every case in a run;
     provider clients are shared per (executable, Codex home, data directory);
     fixture thread IDs are constant across cases, so any lookup keyed by thread ID
     alone must be scoped by data directory; provider stdout goes through
     `ProviderOutputPump` (ConversationModel.swift), which reports stuck handlers.

   Classify each cause as product defect, test defect, fixture defect, or runner /
   environment defect, and fix it where it lives. Keep the headless CLI/XPC case and
   the visible UI case in exact parity (`scripts/check-test-parity.py`) whenever a
   contract or test changes.

4. **Prove each fix.** Rerun the fixed case alone with
   `scripts/test-ui-tart.sh --case <id> [--case <id>...]`. For order-dependent
   failures rerun the alphabetical prefix that reproduced it, or the specific
   earlier case that leaks state. If memory or a stall was involved, keep the
   sampler running and read it. If a fix does not change the outcome, revert it.

5. **Flakiness.** A case that failed in this run but passed in the previous
   nightly, or passed alone, is flaky until its cause is found. Typical causes seen
   so far: clicking a control the instant it appears while the transcript appends a
   message and auto-scrolls (`waitForStableFrame` before the click, then assert the
   click registered); counting rows during the transcript reload that follows a
   turn end (wait for the reloaded state before counting); navigation helpers
   racing a transition the test itself started (`openTask` accepts the board
   appearing as success); a spurious empty read from a provider pipe treated as
   EOF. Fix the cause and add the assertion that would have made the miss explicit.

6. **Speed.** Build the duration table from the run and sort it. Investigate
   anything over about 90 seconds and the sum of everything under 10 seconds that
   is dominated by setup. Look for idle time (sleeps, product cooldowns, polling
   intervals, repeated app launches that verify nothing new) and runner overhead.
   Knobs that already exist: `PLAYHOUSE_E2E_PR_CHECK_COOLDOWN_SECONDS` (board PR
   check cooldown, tests use 3 s), `PLAYHOUSE_UI_TEST_TIMEOUT_SECONDS` (XCTest
   per-case allowance, default 180 s), `PLAYHOUSE_UI_BATCH_SIZE` (cases per
   xcodebuild session; default is all in one). Shorten only waits that are idle
   by construction. A case whose time is real UI actions and real recovery paths
   stays as it is; say so in the report instead of trimming checks.

7. **Quality.** With the suite green, review the test file and fixtures for:
   cases that assert one detail already covered by a neighbor (fold them in and
   update the contract and CLI case); hand-rolled helpers duplicated across cases;
   fixtures that duplicate each other; assertions that pass spuriously (for example
   a status or text that is already true before the step under test, as the Codex
   questions case once did); any case without a fixture that can reach a real
   provider CLI; leftover tracing or debug markers. Apply the improvements that keep
   every behavior covered.

8. **Review every round.** After each batch of changes, before the confirmation
   run, run the code review from `.agents/skills/code-review/SKILL.md` over the
   round's changes, and when product sources changed, the static reviewers that
   `AGENTS.md` requires for source changes (`task_verifier` static phase,
   `ui_verifier`, `architecture_reviewer`). Resolve findings, rerun the affected
   cases, and only then move on.

9. **Confirm.** Run the full suite once more on the final tree with the sampler.
   It must execute every contract case with no failure, skip, or incomplete
   result, and the daemon peak must stay flat. If it is not green, go back to step
   3; do not stop with a known-red suite unless an external blocker prevents any
   progress, in which case report the exact blocker.

10. **Report and commit.** Write `docs/nightly-tests/<YYYY-MM-DD>.md` with: totals
    and wall time of the first and final runs, the daemon peak, each failure with
    its proven cause and fix, flaky cases fixed, speed changes with before/after
    seconds, quality changes, what was deliberately left alone and why, and open
    items for the next night. Then stage only the paths this round changed
    (explicit `git add <path>`), commit with a message that names the round and
    its fixes, and push to the configured upstream. Leave pre-existing staged or
    unstaged work untouched and mention it in the report.

## Rules

- All UI test execution happens in the Tart VM through `scripts/test-ui-tart.sh`.
  Never run `scripts/test-ui.sh` on the host directly and never run the headless
  suite or live provider turns as part of this round unless a fix requires a
  specific CLI/XPC case for parity.
- Never weaken an assertion, extend a timeout as the fix, or remove a check to
  get green. Removing a case is allowed only when its behavior is fully covered
  elsewhere and both suites and the contract are updated together.
- Do not change product behavior visible to users without saying so prominently
  in the report; product fixes for real defects found by the suite are in scope.
- Strip every temporary log, trace, or marker before the confirmation run.
- One round per invocation. If the night runs out of time, finish the current
  step cleanly, run the confirmation suite if anything changed, and report what is
  left rather than committing an unverified tree.
