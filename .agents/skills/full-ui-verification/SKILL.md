---
name: full-ui-verification
description: Run StationAI's full visible UI test suite on demand, repair failures, and commit and push only the scoped verification changes.
---

# Full UI verification

Use this skill only when explicitly invoked. It runs the full StationAI UI suite, diagnoses and repairs failures, confirms the full suite is green, then commits and pushes the changes made by this skill.

## Workflow

1. Read `AGENTS.md`, the verifier instructions in `.codex/agents/`, and the test scripts. Inspect `git status --short` and `git diff` before changing anything. Record pre-existing staged, unstaged, and untracked work so it cannot be swept into the commit.
2. Run `scripts/test-ui-tart.sh` for the full visible UI suite. All UI test execution must happen in the Tart VM, never on the regular host. Require all contract UI cases to execute with no skips, failures, or incomplete results.
3. For each failure, determine whether it reflects a product defect, a test defect, or a behavior that has been intentionally removed. Fix the cause rather than weakening an assertion to make the run green. Use focused `scripts/test-ui-tart.sh --case <case-id>` runs while repairing; once all failures pass, run the full UI suite again in the VM as the final UI confirmation.
4. If a failing UI test expects a feature or behavior that is absent, inspect read-only Git history (`git log`, `git show`, and related read-only commands) and the surrounding code/docs to determine when and why it was removed. Never restore product code solely to satisfy a failing test. If history clearly shows the removal was intentional, remove the obsolete UI and CLI tests and their shared contract entry, then validate exact parity and run the fast CLI suite. If the history indicates the removal may have been accidental or the intent is unclear, stop before changing product code or deleting tests and ask the user whether to restore the feature or keep it removed. Never bring back the feature without the user's explicit approval.
5. For other product fixes or test updates, preserve exact CLI/UI case and expectation parity. Run `scripts/check-test-parity.py` and the fast `scripts/test-e2e.sh` suite when product behavior, CLI tests, UI tests, or shared contracts changed. Follow the relevant CLI case repair guidance in `AGENTS.md`. Invoke the `task_verifier` from `.codex/agents/task-verifier.toml` after repairs; it must run the fast gate and the read-only UI coverage review, without executing UI tests. The full UI suite must then pass once more as final confirmation.
6. Before committing, inspect the final unstaged diff and status against the baseline recorded in step 1. Stage only clean-baseline paths changed by this skill, using explicit path arguments to `git add`; then commit with a path-scoped command (for example, `git commit --only -m "..." -- <scoped-paths>`) so unrelated staged entries are not included. If a path the skill needs to commit already had pre-existing staged or unstaged changes at the baseline, do not include that path or disturb its index/worktree state; finish verification and report why the full scoped commit cannot safely proceed. Do not include unrelated work.
7. Push the scoped commit to the current branch's configured upstream. Explicit invocation of this skill is authorization for its path-scoped `git commit` and `git push` operations, as specified in `AGENTS.md`. If there is no configured upstream or the push fails, retain the local commit and report the exact blocker.

## Verification and reporting

Serialize every app verification session through the repository-root `.e2e.lock`; use the provided test scripts, which acquire the lock. Report the initial full UI result, each focused repair run, any CLI/parity checks, the final full UI result, changed files, and commit/push outcome. If you pause for the user's decision about a possibly accidental feature removal, state the relevant history evidence and do not commit or push the unresolved change.
