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
   Reports live outside the repository, in `/tmp/playhouse-nightly-tests/`, and are
   never committed. Read the whole most recent report,
   `ls /tmp/playhouse-nightly-tests/*.md | sort | tail -1` (if there is none, start
   cold). List the commits since the commit the report records
   (`git log --oneline <report commit>..HEAD`), so you know what changed after that
   round.

1a. **Resume from the latest report.** Each round picks up where the previous one
   stopped instead of starting cold. From the latest report, extract:
   - **Carried failures:** every case that failed in the report's *final* run (or its
     last run, if the round ended without a green confirmation) and is not marked
     fixed. These are this round's first work.
   - **Uncommitted round work:** if the report says its changes were left unstaged,
     compare its recorded fingerprint with the current `git diff | shasum` over the
     listed paths. If they match exactly, treat those paths as this round's changes:
     they get reviewed, verified and committed with this round. If they do not match,
     or were already committed, go by what the working tree and `git log` show, and
     say which case applied in this round's report. Never sweep in paths the report
     does not list.
   - **Open items:** the numbered open items, split into two groups. The first group is
     items about a specific failing or flaky case. The second is everything else
     (speed, quality, architecture, runner).

   Then, before the full run:
   1. Run every carried failure in **one** focused invocation,
      `scripts/test-ui-tart.sh --case <id> [--case <id>...]`, on the current tree. If
      the report gives an order-dependent reproduction (an alphabetical prefix or a
      leaking earlier case), include it.
   2. For each case still red, triage and fix it as in steps 3 and 4. Start from the
      report's evidence and its "likely cause", and prove or refute that cause instead
      of assuming it. Rerun the batch until every carried failure is green in a
      focused run.
   3. A carried failure that passes at once is still open. It is flaky until its cause
      is found (step 5), so use the report's evidence to find and fix that cause.
      Passing this time does not close it.
   4. If the fixes for carried failures changed source files, run the step 8 review
      for them now, so the full run starts on a reviewed tree.

   If the latest report has no carried failures, skip straight to step 2. Either way,
   once the full run is green, work the case-specific open items in steps 5 to 7, then
   the remaining open items as time allows. This round's report states the outcome of
   each carried failure and open item: fixed (and how), still open (and why), or no
   longer applicable.

2. **Full run with instrumentation.** The full suite now takes about three hours, longer
   than one background command may run (2 hours), so run it as four alphabetical parts
   taken from the contract, one after another, each with every case of its part:

   ```bash
   export PATH=/opt/homebrew/bin:$PATH
   python3 -c 'import json,sys; ids=sorted(c["id"] for c in json.load(open("Playhouse/BridgeTests/BridgeTestContracts.json"))); k=-(-len(ids)//4); [open(f"{sys.argv[1]}/part{i+1}.txt","w").write("\n".join(ids[i*k:(i+1)*k])+"\n") for i in range(4)]' "$SCRATCH"
   scripts/test-ui-tart.sh $(sed 's/^/--case /' "$SCRATCH/part1.txt") > "$SCRATCH/full1-part1.log" 2>&1
   ```

   Run each part in the background and wait for completion. Collect from the log: `Visible UI suite:` totals, every
   `Test Case ... (passed|failed) (N seconds)` line (the per-case duration table),
   the xcodebuild invocation (confirms `-test-timeouts-enabled YES` and the
   allowances), the `Daemon memory peak:` line and the run's `daemon-memory.log` in
   its artifacts directory (the runner samples the daemon's RSS every 20 seconds
   inside the run itself, so a VM restart before the run cannot lose it; it should stay
   under about 100 MB for the whole run), and from the VM the daemon log
   `/private/tmp/playhouse-bridge/501/<hash>.sock.log` (every `listening` line is
   a daemon start; one without an `idle, exiting` before it is a death), and the
   artifacts directory on the host under
   `/tmp/playhouse-ui-tart-artifacts/<run>/playhouse-ui.*/` (`bridge-watcher.log`
   lists daemon deaths as `watcher exited rc=69`, plus the single `.xcresult`).

   If this run is fully green and the round ends up changing nothing that the
   suite depends on, it is also the confirmation run; step 9 does not repeat it.

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

4. **Prove each fix with focused runs only.** Rerun only the fixed cases with
   `scripts/test-ui-tart.sh --case <id> [--case <id>...]`; batch every case that is
   ready into one invocation rather than one VM session per case. For
   order-dependent failures rerun the alphabetical prefix that reproduced it, or the
   specific earlier case that leaks state. If memory or a stall was involved, keep
   reading the run's `daemon-memory.log`. If a fix does not change the outcome, revert it.
   Repeat steps 3 and 4 on whatever is still red until every failed case passes in
   a focused run. Do not start another full run while any known failure is open.

5. **Flakiness.** A case that failed in this run but passed in the previous
   nightly, or passed alone, is flaky until its cause is found. The same applies to
   the carried failures from step 1a that passed on the first try. Typical causes seen
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

9. **Confirm.** Skip this step if step 2 was green and nothing the suite depends
   on has changed since. Otherwise run the full suite once more on the final tree
   (in the same four parts). Together the four logs must execute every contract case exactly once with no failure, skip, or
   incomplete result, and the daemon peak must stay flat. If it is not green, go
   back to steps 3 and 4 for only the cases that failed in this run, fix them with
   focused runs until all are green, rerun the review in step 8 for those fixes,
   then repeat this full run; do not redo steps 5 to 7. Do not stop with a
   known-red suite unless an external blocker prevents any progress, in which case
   report the exact blocker.

10. **Report and commit.** Write `/tmp/playhouse-nightly-tests/<YYYY-MM-DD>.md`
    (create the folder if needed; never write the report into the repository) with:
    the `HEAD` commit the round started from and the commit it pushed, totals
    and wall time of the first and final runs, the daemon peak, each failure with
    its proven cause and fix, what happened to each carried failure and open item from
    the previous report (step 1a), flaky cases fixed, speed changes with before/after
    seconds, quality changes, what was deliberately left alone and why, and open
    items for the next night. Then stage only the repository paths this round changed
    (explicit `git add <path>`), commit with a message that names the round and
    its fixes, and push to the configured upstream. Leave pre-existing staged or
    unstaged work untouched and mention it in the report. The only exception is the
    previous round's uncommitted work that step 1a adopted after its fingerprint
    matched. The next round resumes from this report, so put the final run's failures
    and the open items in it, with enough evidence (paths, timestamps, likely cause)
    to start from.

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
