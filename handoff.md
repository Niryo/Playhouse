# Handoff: Claude Code as a second conversation provider

Status as of 2026-10-24. This work is uncommitted on branch `support-codex`: nothing is staged, committed, or pushed. It implements `~/Downloads/PLAN.md` ("Add Claude Code to Playhouse conversations"), with the deviations listed below.

## 1. Where things stand

| Area | State |
| --- | --- |
| Claude Code runtime client | Done. Verified live against Claude Code 2.1.308. |
| Provider-neutral conversation model | Done. Types renamed; shared protocol in place. |
| Per-task provider, default-provider setting | Done, with deterministic paired tests. |
| Mid-conversation switching and handoff | Done. Claude → Codex → Claude handoff verified by hand, live. |
| Mixed-provider transcript (ordering, divider, reopen) | Done, with deterministic paired tests. |
| Helper turns (title, PR summary, conflicts) per provider, with fallback | Done. |
| CLI/XPC: provider, capabilities, stop, default provider | Done. |
| UI: provider picker, boundary divider, capability notice, labels | Done. Compiles; **not run in Tart yet**. |
| Live suite with provider switch (`claude` default, `codex`, `all`) | Done. All 6 Claude, all 5 Codex, and the `all` handoff scenarios pass live. See §6. |
| Required review gates (task/UI/architecture reviewers, workflow report) | **Not run.** See §7. |
| Docs (`README.md`, `docs/bridge.md`, `AGENTS.md`) | **Not updated.** See §7. |

## 2. Plan review: deviations from `PLAN.md`

1. **No TypeScript Agent SDK helper.** The SDK is a thin wrapper over the `claude` CLI's documented streaming protocol (`-p --input-format stream-json --output-format stream-json` plus JSON `control_request`/`control_response` messages). `ClaudeCodeClient.swift` speaks that protocol directly, the same way `CodexAppServerClient` speaks the Codex app-server's JSON-RPC. This avoids bundling a Node/Bun runtime, keeps one process model for both providers, and uses the user's installed `claude` with its own credentials and configuration. The SDK types (`sdk.d.ts` in `@anthropic-ai/claude-agent-sdk@0.3.296`) were the reference for message shapes.
2. **Steer uses `priority: "next"`, not `"now"`.** Probed live:
   - `"now"` cancels the in-flight command (`command_lifecycle: cancelled`, an extra `result` with `stop_reason: tool_use`) and starts a new one.
   - `"next"` injects the message at the next tool boundary inside the same turn, with a single `result`. That matches Codex's `turn/steer`.
   - Queue stays Playhouse's own persisted queue for both providers. `"later"` is not used.
3. **Version floor is 2.1.296, not "upgrade from 2.1.119".** The plan was stale. 2.1.296 is the CLI version bundled with the SDK release whose types document `priority`. Only 2.1.308 was actually tested. Older CLIs get a clear "update Claude Code" error from `ClaudeCodeClient.verifyVersion`.
4. **Transcript persistence is hybrid, not a full Playhouse-owned copy of every provider's history.**
   - Codex history is still read live from the Codex app-server, exactly as before.
   - Claude turns, plus the ordered provider segment ledger, are stored by Playhouse.
   - Tasks that never use Claude have no transcript file and run the old code path unchanged. That's why the 62 pre-existing cases were unaffected.
   - Deferred: importing existing Codex histories into Playhouse with stable IDs. This means archive search and reopening Codex turns still need the Codex runtime, as before.
5. **New tasks default to Codex.** This matches the plan, but is now a setting (`settings set-default-provider`). The live test suite defaults to Claude, per the user's instruction.

## 3. Architecture notes (read before changing anything)

### Files

| File | Role |
| --- | --- |
| `Playhouse/App/ConversationModel.swift` (new) | Shared types: `ConversationMessage` (now carries `provider`), questions, `ConversationMode`, `ConversationModelOption`, `ConversationProviderBoundary`. Also the **`ConversationProviderClient` protocol**, `ConversationClients` (one client per provider, plus `helperClients(preferring:)`), and `ConversationSteerMailbox`, extracted from the Codex client. The mailbox is the cross-process steer *and interrupt* channel, keyed by native thread/session ID. |
| `Playhouse/App/BoardTask.swift` | The base `enum ConversationProvider` lives here on purpose: `scripts/seed-task-pr-link.swift` compiles `BoardTask.swift` standalone, so it must not depend on other files. Provider extensions (`defaultModelID`, `titleModelID`, `supportsGoals`, `parse`) are in `ConversationModel.swift`. New `@Model` fields: `claudeSessionID` and `conversationProviderRawValue` (nil means Codex), plus helpers `activeConversationID`, `conversationID(for:)`, `hasConversation`. |
| `Playhouse/App/ClaudeCodeClient.swift` (new) | The Claude runtime. Details below. |
| `Playhouse/App/ConversationTranscriptStore.swift` (new) | Per-task JSON at `<data dir>/conversation-transcripts/<taskID>.json`, guarded by a file lock. Holds `segments` (provider, startedAt, `codexTurnIDs`, `handoffDelivered`) and Claude `turns` (messages plus activities). Also `ConversationHandoff`, which builds and strips the handoff context block. |
| `Playhouse/App/BridgeCore.swift` | `ConversationManager` (renamed from `CodexConversationManager`) routes everything through the task's provider client. It composes mixed history (`compose(transcript:codex:)`), records Claude turns incrementally, implements `setProvider` (settled-state checks and boundary), builds the handoff, and holds the Goal gate. `ConversationTitleGenerator` is provider-neutral and falls back on unavailability. Bridge commands `conversation.provider.{get,set,capabilities}`, `conversation.stop`, `settings.set-default-provider`, `task.create --provider`. |
| `CodexAppServerClient.swift` | Conforms to the protocol and uses the shared mailbox. Codex history parsing now tags messages `provider: .codex` and strips handoff blocks from user text. |
| UI: `TaskConversationView.swift`, `KanbanBoardView.swift`, `PlayhouseApp.swift` | Both clients are app-level `@StateObject`s. The view picks the active client by `task.conversationProvider`. Added a provider menu (`conversation-provider-menu`, items `conversation-provider-<id>`), a boundary row (`provider-boundary-<provider>`), and a capability notice (`provider-capabilities-notice`). Goal UI is hidden for Claude. Labels are provider-specific. |
| `scripts/build-bridge.sh` | XPC plist now sets **`JoinExistingSession = true`**. See §5. New sources were added to the shared source list, and to the pbxproj build phase inputs. |

### How a Claude turn runs

1. Each turn launches `claude -p ... --permission-prompt-tool stdio --permission-mode default|plan --session-id|--resume <id>`.
   - It also passes `--add-dir` for extra roots, and `--append-system-prompt` for Playhouse's progress/outcome instructions.
   - The cwd is the first root.
2. Playhouse sends `initialize` and checks the version, then writes the user message with a known `uuid`.
3. **Turn end = a `result` arrived and every command UUID we submitted has reached `completed`/`cancelled`/`failed` in `command_lifecycle`.** If the CLI never emits lifecycle events, `result` alone ends the turn.
4. stdin is closed and the process exits.
5. Session creation: `startThread` only mints a UUID, and the first turn passes `--session-id`. If `--resume` returns "No conversation found with session ID", the client retries once with `--session-id`.

### Event mapping (stream-json to Playhouse)

| Claude event | Playhouse |
| --- | --- |
| `stream_event` text deltas | `text_delta` |
| assistant text blocks | Commentary progress messages. The last text before the turn settles becomes the final answer. |
| `tool_use` / `tool_result` | Activities (Bash, Edit/Write, Read, Grep, Web, `mcp__server__tool`, and `Task`/`Agent` as subagents with `childThreadID = tool_use_id`) |
| `can_use_tool` for `AskUserQuestion` | A `ConversationUserInputRequest` with question IDs `question-1…`. Answers go back as `updatedInput.answers` keyed by question text. |
| `can_use_tool` for `ExitPlanMode` in plan mode | The plan becomes the turn's final message. The tool is then denied with "end your turn", so plan mode stays until the user starts implementation, mirroring Codex. |
| Any other `can_use_tool` | Allowed. Claude Code has already applied the user's native allow/deny rules before asking, so deny rules are honored. |

### Mixed history

- Segments are ordered. Codex segments own Codex turn IDs:
  - At the first switch away from a Codex-only task, the switch snapshots every existing turn into the segment.
  - Later turns are claimed when each Codex turn completes, through `onHistory` → `claimCodexTurns`.
- Unclaimed Codex turns fall into the last Codex segment.
- **Codex is read in a mixed transcript only if a Codex segment owns turns.** Codex refuses `thread/items/list` for a thread with no turns.
- Boundaries are emitted where consecutive segments differ in provider. An empty segment is replaced when switching again, so switching back and forth without sending leaves no divider.

### Handoff

- On a segment's first prompt, the visible user and final-assistant text the provider hasn't seen is prepended inside `<playhouse-handoff-context>…</playhouse-handoff-context>`. It's capped at about 40k characters, keeping the most recent turns.
- `handoffDelivered` is set only after a successful turn.
- Codex stores the block in its thread, and Playhouse strips it on read. Claude's transcript stores only the typed text.
- The handoff is computed **before** a new native thread is created. This ordering is deliberate: see the Codex limitation above.

### Switching rules

`ConversationManager.setProvider` and `requireSettledConversation` reject a switch while any of these hold:
- A turn reservation is held, or a send is active.
- A turn is active in this process or another one (mailbox owner).
- A submitted prompt is pending.
- Queued follow-ups exist (any state).
- An unanswered async question is outstanding and the task is Waiting Response.
- Subagents are still running.

A Done task can't switch. A task without a conversation switches immediately, with no boundary.

### Helper turns

- Title, PR summary, and conflict resolution use the task's provider. Title models: Codex `gpt-6-luna`, Claude `haiku`.
- Title and PR summary fall back to the other provider **only when the preferred one is unavailable** (`isProviderUnavailable`: not installed, can't start, or not signed in). An empty or failed answer still uses the prompt fallback. This keeps the fixture tests deterministic and avoids surprise model calls.

## 4. Testing layout (per the user's instruction)

- **Tests unrelated to the provider:** untouched.
- **Shared mocked tests:** the existing fixture-based CLI/XPC and UI cases use `scripts/fixtures/codex-app-server-fixture.py`. They were **not duplicated**, because they exercise Playhouse logic, not the provider.
- **New deterministic paired cases** (CLI in `scripts/test-bridge.py`, UI in `PlayhouseUITests.swift`, contract in `BridgeTestContracts.json`, parity is 64/64):
  - `test_conversation_provider_selection_persists_and_validates`
  - `test_conversation_provider_switch_waits_for_settled_turn_and_records_boundary`
- **Shared real (non-mocked) tests:** `scripts/test-live-integration.{sh,py}`, with a provider switch `--provider claude|codex|all`, or `PLAYHOUSE_LIVE_PROVIDER`. Default is **claude**. Gate: `PLAYHOUSE_RUN_LIVE_INTEGRATION=1`.
  - Shared scenarios: plan/edit/resume/reload across two roots; steer into an active turn; stop from another process; concurrent auto-branch claim.
  - Claude-only: `AskUserQuestion` round trip; native capability report.
  - Codex-only: pinned model. The Codex Goal case is the live UI case.
  - `all` only: cross-provider handoff in both directions with ordering assertions.
  - `scripts/test-codex-integration.sh` is now a wrapper that runs `--provider codex`.
  - The old `scripts/test-codex-integration.py` was replaced by `test-live-integration.py`. Its auto-branch scenario was moved over verbatim.
- **Live UI:**
  - `scripts/test-ui-tart.sh --live-provider claude|codex`; `--live-codex` is an alias.
  - The guest marker is now `/tmp/playhouse-live-ui-integration`, and its content is the provider name.
  - UI tests read it through `liveProvider`. Shared live UI cases call `useLiveProvider(taskID:)`. The Goal live case only goes live for Codex.

## 5. Things to be aware of (gotchas found the hard way)

- **The XPC service needs `JoinExistingSession = true`.** Without it, the service runs in a new security session with no login-keychain access, and Claude Code reports "Not logged in · Please run /login" even when the user is signed in. Codex authenticates from a file and never hit this. The environment fill-in (`HOME`/`USER`/`LOGNAME`) in `launchSession` is defensive and was not the fix.
- **Claude backgrounds long commands (mitigated, not designed away).** Claude ran `sleep 25` as a background task and ended its turn early. Each turn's process exits at turn end, so background work would be lost. The current fix is an instruction appended to every Claude session (`ClaudeCodeClient.foregroundExecutionInstruction`): run commands in the foreground, never `run_in_background`, never `&`, never end a turn while started work is still running. Verified live (steer and stop pass). Still open: a Claude-side mechanism that keeps a process alive across background tasks would make this robust if the model ignores the instruction. Track as a design item.
- **Codex can't resume a thread that never ran a turn** ("no rollout found") and can't list its items ("thread/items/list is not supported yet"). This is pre-existing: a Codex-only task whose first turn fails after `thread/start` already hits it. The send path now avoids creating such threads during a switch, but tasks already in that state stay stuck. Consider starting a fresh thread when resume reports no rollout.
- **Pre-existing path quirk.** `hasConversationTurnReservation` compares a lock path that Foundation normalizes differently once the lock file exists (`/private/tmp/...` vs `/tmp/...`). A data directory spelled `/private/tmp/...` therefore fails every send with "A turn outcome requires an active conversation turn". Real data (`~/Library/...`) and the harness (`/tmp/...`) are unaffected. Not fixed, because it's unrelated to this change.
- **Provider child processes must receive the bridge environment explicitly (fixed).** A child inherits its launcher's environment (the XPC service or the GUI app), not the CLI caller's, so in-turn `playhouse task progress`/`task outcome` calls previously went to the default service name and store. `ConversationProcessEnvironment.forwardPlayhouseBridgeEnvironment` sets `PLAYHOUSE_BRIDGE_SERVICE_NAME` to `BridgeContract.serviceName(forApplication: PlayhouseAppIdentity.applicationIdentifier)` (app ID + `.bridge`, the same in both processes) and `PLAYHOUSE_DATA_DIRECTORY` for Claude and Codex children. Do **not** use `Bundle.main.bundleIdentifier`: in the GUI app that's the app's own ID, which no XPC service has (the architecture review caught this). Covered by `test_task_progress_reports_publish_persist_and_clear`: the fixture records what it inherited and the outcome is reported with exactly that environment, from both a CLI-started and a composer-started turn.
- **A rejected branch claim restores the prior status (fixed).** `sendReserved` wraps every pre-turn step (title before worktree, `prepareRepositoryWorktrees`, workspace context, title reservation) and restores the prior status and message on failure. The composer pre-saves In Progress before calling the manager, so it passes `statusBeforeSubmission`. Architecture review left a **CONCERN** here: the composer still owns part of the send pipeline (`saveDraftAndGenerateTitle(status: .inProgress, reserveTitleForSend: true)`), so early failures before the guarded block (Done guard, image/model validation, turn-lock failure) still leave a composer-sent task In Progress, possibly with a stale "Generating title…". The better design is a manager entry point that does the pre-save and returns a submission token (prior status, message, title) that `send` consumes and rolls back on any pre-turn failure.
- **Live harness keep switch.** `PLAYHOUSE_LIVE_KEEP_WORKSPACE=1` keeps the disposable workspace (including `playhouse-data/Diagnostics.jsonl`) for diagnosis; the default removes it.
- **Harness must not read a process's stdout while `StreamingTurn` owns it.** Use `StreamingTurn.finish()`, never `communicate()`, on a turn process (this caused a lost-output false failure).
- **The Codex fixture reuses one turn ID for every turn** (`turn_playhouse_fixture`). Segment claiming by turn ID works for the new tests, but don't write fixture-based tests that switch Codex → Claude → Codex and expect the second Codex turn after the boundary. Real Codex turn IDs are unique.
- Failed Claude sends still leave the user prompt in Playhouse's transcript. This is intentional, because Claude's own session also records it. Codex behaves the same.
- `ConversationMessage.provider` is nil for legacy messages; the UI falls back to the task's provider.

## 6. Verification evidence

- **Deterministic CLI/XPC suite** (`scripts/test-e2e.sh`):
  - First full run: 58/62 passed. The 4 failures were caused by this change: the standalone `BoardTask.swift` compile in a seed script, and one diagnostic-operation-name assertion. Both are fixed, and those 4 plus the 2 new cases pass in a focused run.
  - Final full run at handoff: **64/64 passed**, 0 skipped (`Bridge suite: total=64, passed=64`).
- **Live suite, final run (this handoff):**
  - Claude, all 6 scenarios: plan/edit/resume/reload, steer into an active turn, stop from another process, concurrent auto-branch, question round trip, capability report. All pass.
  - Codex, all 5 scenarios: plan/edit/resume/reload, steer, stop, concurrent auto-branch, pinned model. All pass.
  - `--provider all`: cross-provider handoff in both directions, with provider-order and timeline assertions. Passes.
  - Live UI cases (Tart or the local `test-ui.sh` path) have **not** been run.
- **Deterministic CLI/XPC suite, after the final source change:** 64/64 pass, 0 skipped.
- **Live Claude, by hand through the CLI/XPC (earlier):**
  - A real turn that ran a shell command and edited a file, with streaming text, activities, and the transcript persisted.
  - Claude → Codex switch: Codex recalled a codeword from the Claude turn, the boundary sat after the Claude reply, and the handoff block was hidden.
- **Live suite scenarios run** (against a local smoke build):
  - Passed: `scenario_claude_question_round_trip`, `scenario_claude_capabilities`.
  - Failed: `scenario_steer_active_turn`, because of the backgrounding issue in §5. The steer itself was accepted and recorded in the same turn.
  - Not yet run: the shared plan/edit/resume, stop, and auto-branch scenarios for Claude; anything for Codex; the `all` handoff scenario.
- **UI:** compiles (`build-for-testing` as part of the e2e build). **No UI case was run in Tart.**

## 7. What's left (in order)

1. ~~Fix the rejected-claim status~~ Done (§5); `Backlog` assertion restored in the CLI, UI and live suites. Follow-up: the submission-token refactor from the architecture CONCERN (§5).
2. **Decide on the Claude background-task design** (§5) beyond the current instruction.
3. ~~Run the full live suite~~ Done for claude, codex, and `all` (§6). Rerun after any provider-facing change.
4. **Run the new paired UI cases in Tart:** `scripts/test-ui-tart.sh --case test_conversation_provider_selection_persists_and_validates --case test_conversation_provider_switch_waits_for_settled_turn_and_records_boundary`. Watch for:
   - Menu interaction on macOS. The provider menu's `label` is asserted to contain the provider name, and its `isEnabled` state is asserted.
   - The capability notice, which runs `claude` in the guest. If `claude` isn't installed there, it just shows the "wasn't found" text; nothing asserts on it.
5. **Repository gates from `AGENTS.md`:** done for the follow-up change set (static: task and UI `APPROVED`, architecture `CONCERN`; runtime: see §6). Still due once the remaining source work lands:
   - Static review in parallel: `task_verifier` (static phase), `ui_verifier`, and `architecture_reviewer` (`.codex/agents/*.toml`) on the unstaged fingerprint.
   - Then the main-agent runtime run of `scripts/test-e2e.sh`.
   - Then `workflow_optimizer`, which writes a report under `docs/workflow-improvements/`.
6. ~~Docs~~ Done (`docs/bridge.md`, `README.md`, `AGENTS.md`, `.agents/skills/code-review/SKILL.md`). Originally:
   - `docs/bridge.md`: new commands, the provider model, the transcript store, and the live suite.
   - `README.md`: live suite usage, replacing the Codex-only text.
   - `AGENTS.md`: references to `scripts/test-codex-integration.sh` should point at `test-live-integration.sh`, and "Live Codex turns" should become "live provider turns".
7. **Plan items deferred or partial:**
   - Importing Codex history into Playhouse's store, so archive search and reopening don't depend on the Codex runtime.
   - Claude subagent inspection shows only the subagent's summary and report (from the parent's tool result), not its sidechain transcript.
   - No per-turn diff for Claude (`history.diff` is nil). The changes panel uses the workspace's Git inventory.
   - Model picker for Claude: lists the `initialize` models and defaults to `default`. Not validated in the UI.
   - Rename leftovers: many accessibility IDs and UserDefaults keys still say `codex-…` (for example `codex-activity-disclosure`, `playhouse.codex.response-started-at…`). Renaming them would churn the UI tests; decide deliberately.
8. **Nice-to-haves:** a `--provider` flag on `conversation send` (switch, then send); showing the capability notice on first open, not only after a switch; and the handoff size cap could be made configurable.

## 8. Where the time went

- **Most time:** understanding the existing conversation stack (about 4,200 lines in `BridgeCore.swift`, 3,500 in `TaskConversationView.swift`, 1,800 in the Codex client, 6,700 of UI tests). Close behind: probing the real Claude CLI protocol, covering stream events, `can_use_tool`, steering priorities, interrupt, resume, and missing sessions.
- **Biggest debugging detours:**
  1. The `/private/tmp` lock-path quirk, which made my ad-hoc smoke setup fail every send and initially looked like a regression.
  2. The XPC security-session problem: Claude reported "not logged in" only under the XPC service. I wrongly tried a disclaimed-responsibility `posix_spawn` first, then reverted it.
- **Live testing found** three real bugs that the deterministic suite couldn't:
  - the XPC keychain session;
  - the Codex empty-thread read during handoff;
  - Claude's command backgrounding.

  Budget time for live runs on both providers.

## 9. Useful commands

```sh
# Deterministic suite (no sign-in needed)
scripts/test-e2e.sh
scripts/test-e2e.sh --case test_conversation_provider_switch_waits_for_settled_turn_and_records_boundary

# Live suite (real providers; claude is the default)
PLAYHOUSE_RUN_LIVE_INTEGRATION=1 scripts/test-live-integration.sh --provider claude --skip-ui
PLAYHOUSE_RUN_LIVE_INTEGRATION=1 scripts/test-live-integration.sh --provider all
# Focused live scenario against an existing build:
PLAYHOUSE_RUN_LIVE_INTEGRATION=1 PLAYHOUSE_APP_PATH=<Playhouse.app> PLAYHOUSE_BRIDGE_TEST_FIXTURE_ROOT=<fixture> \
  python3 scripts/test-live-integration.py --provider claude --scenario scenario_steer_active_turn

# Provider operations
playhouse-cli task create --title T --root <dir> --provider claude
playhouse-cli conversation provider <task-id> [set codex|claude|capabilities]
playhouse-cli conversation stop <task-id>
playhouse-cli settings set-default-provider claude
```

The live suite creates its fixtures under `TMPDIR`; use a `/tmp/...` spelling, not `/private/tmp/...` (see §5).
