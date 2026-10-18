---
name: code-review
description: Review a StationAI implementation task through the fast CLI/XPC bridge and read-only paired UI test coverage review.
---

# StationAI task review

Use this skill after each implementation task in this repository. Review the task against the user's request and product requirements, then return `APPROVED` or `REJECTED`. The routine gate is headless and quick: it runs CLI/XPC checks and reviews paired UI test quality without executing UI tests or opening the app. Run the full UI suite on demand with `$full-ui-verification`.

## Review process

1. Read the task request, applicable `AGENTS.md`, and relevant product documentation. Use read-only Git status/diff to define the current task's unstaged scope. Include relevant untracked files, exclude staged-only files and staged hunks, and assess only the unstaged delta in partially staged files.
2. Map every in-scope semantic product capability to a manager operation, CLI command, and bridge assertion. Review validation and failure paths, persistence across fresh XPC connections, ordering/state behavior, conversation history, and UI wiring. Transient focus, sheet, or selection state is outside the bridge contract.
3. Check test parity with `scripts/check-test-parity.py`: every Python CLI test and Swift UI test must have the same case name and the same expectation annotation from `StationAI/BridgeTests/BridgeTestContracts.json`. Missing, extra, duplicate, or mismatched cases reject the task. Each case should focus on one logical behavior or contract; small related expectations can extend an existing case, while independent capabilities or failure paths get separate cases.
4. Run `scripts/test-e2e.sh` first for app behavior changes. Require a CLI assertion added or extended for each changed behavior/bug fix, then require the matching UI case and shared expectation. The initial full suite must execute every named CLI case from the shared contract with no skips or failures. If it fails, fix the issue and use `scripts/test-e2e.sh --case <case-id>` to rerun only failed cases. After every failed case is green, run the full CLI suite once for final confirmation. Review inner case names and assertions; the Xcode adapter count alone is not coverage. It uses committed Git fixtures, isolated real SwiftData and preferences, and the app-bundled CLI/XPC service. It does not require Codex sign-in. Reject mocks, stubs, fakes, simulated persistence, or test-only behavior in production paths.
5. Only after the initial CLI suite and parity checks pass, call the UI coverage reviewer defined in `.codex/agents/ui-verifier.toml`. Give it the exact paired UI case IDs that cover the changed behavior. It inspects the test actions and assertions to judge whether they would detect relevant regressions; it must not run UI tests or open the app. If review finds missing/weak coverage, repair the paired CLI/UI assertions and shared contract, then rerun affected CLI checks and repeat the read-only review. `scripts/test-full-e2e.sh` remains available for an explicitly requested complete CLI and UI run; `$full-ui-verification` is the on-demand full UI workflow.
6. Exercise additional semantic workflows through `scripts/stationai.sh`, which uses the bundled CLI and XPC service. Use the separate live Codex integration suite only when the task changes Codex turn behavior and the task calls for that opt-in run.
7. Keep a per-task verification ledger containing the unstaged change fingerprint, CLI commands and case IDs, UI coverage review IDs/findings, pass/fail result, and elapsed time; reuse a pass only while its relevant source/test/contract inputs are unchanged. For docs, process, or verifier-only changes, validate changed artifacts with syntax/consistency checks. Routine verification does not run a UI test or capture a screenshot.
8. Audit in-scope production and test code for unapproved mocks. Keep the review read-only and do not run Git write operations.

## Decision

Return `REJECTED` when an in-scope product capability lacks CLI/XPC or paired UI coverage, parity fails, the CLI suite has missing cases, skips, failures, or incomplete results, the app does not build, an unapproved mock was added, or the UI coverage review finds weak/missing tests. Give concrete findings with file and line references and the work needed to pass review.

Return `APPROVED` only when requirements map to implementation and passing bridge assertions, persistence and failure behavior are covered, paired UI tests meaningfully check the changed visible behavior, and no unapproved mocks are present. Do not claim UI runtime success. State any Codex sign-in/model limitation when the opt-in live integration suite was not run.

## Review report

Include:

- Decision: `APPROVED` or `REJECTED`.
- Requirement-to-manager/CLI/XPC mapping and behavioral summary.
- Shared CLI/UI test case names and counts (separate from Xcode wrapper counts), expectation parity, matched assertions, fixture details, persistence coverage, full CLI result, and read-only UI coverage review result.
- Unstaged files reviewed; explain staged/untracked scope handling.
- Additional CLI/XPC workflows exercised or why none were needed.
- Confirm that routine verification did not run UI tests or screenshots.
- Mock audit result.
- Findings ordered by severity, if any.
