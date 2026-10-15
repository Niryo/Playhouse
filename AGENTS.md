# StationAI agent instructions

These rules govern development work in this repository. They describe the development process; they are not features of the StationAI app.

## Git write operations

- Do not run Git commands that change the working tree, index, refs, or repository history unless the user explicitly authorizes the specific operation in the current conversation.
- This includes `git add`, `commit`, `push`, `pull`, `stash`, `restore`, `reset`, `checkout`, `switch`, `clean`, `merge`, `rebase`, `cherry-pick`, branch or tag creation/deletion, and worktree creation/removal.
- A request to implement, edit, or review code is not permission to run a Git write command. Read-only commands such as `git status`, `git diff`, and `git log` are allowed.

## Verification scope

- The task verifier reviews only the current task's unstaged working-tree changes. Use read-only `git status --short` and `git diff` to identify that scope; include relevant untracked files as unstaged. Exclude staged-only files and staged hunks from the review. For a partially staged file, assess the unstaged delta only; staged content may be consulted as context but is not approved by the verifier.
- The task verifier must not run automated tests. For app behavior changes, build and launch the real app, then directly interact with the affected workflows and inspect their results. For documentation, process, or verifier-configuration-only changes that cannot affect app behavior, validate the changed artifacts with relevant syntax or consistency checks instead of launching the app.
- Capture and inspect real-app screenshots when the unstaged task changes user-visible behavior or UI. For documentation, process, or configuration-only changes with no UI impact, screenshots are not applicable.
- State which unstaged changes were reviewed, which app workflows were exercised, and whether screenshots applied. If direct app interaction or relevant artifact checks cannot be completed, reject with the specific gap.

## App verification, E2E coordination, and mocks

- Serialize all app verification sessions through the same repository-root `.e2e.lock`. Developer-initiated E2E test runs use `scripts/test-e2e.sh`; custom E2E test commands use `scripts/with-e2e-lock.sh -- <command> [args...]`. The OS-managed lock waits 20 seconds between retries while another run holds it.
- The task verifier must hold that lock for the full direct app session, from launch through interaction, screenshots, and app shutdown. Start a long-lived interactive shell under `scripts/with-e2e-lock.sh -- bash` using a PTY, run `scripts/run.sh` and interact from that shell, close the app, then exit the shell. Do not run the lock wrapper only around `scripts/run.sh`, because that command exits while the app remains open and would release the lock too early.
- When developers run E2E tests outside the task verifier, those tests must exercise the actual app and its real persistence and dependencies. The verifier exercises behavior by direct UI interaction and does not run automated tests.
- Do not add mocks, stubs, fakes, or simulated implementations. If a test genuinely requires a mock, first explain the dependency and why it cannot be exercised directly, then ask the user for explicit permission. Do not add it until permission is given.
- An isolated test data directory is acceptable when it still exercises the app's real persistence implementation.
- Developer-run E2E tests should cover each requested user-visible feature and relevant empty, validation, and failure states. They may extend a coherent scenario instead of creating a separate test for every assertion.

## Task verification gate

- After every implementation task, invoke the `task_verifier` subagent defined in `.codex/agents/task-verifier.toml`.
- The verifier must run the `code-review` skill in `.agents/skills/code-review/SKILL.md`, examine the unstaged task changes, directly exercise relevant app workflows without running tests, and audit in-scope code for unapproved mocks. Screenshots follow the relevance rules above.
- A task is complete only after the verifier reports `APPROVED`. If it reports `REJECTED`, address its findings and run the verifier again before calling the task complete.
