---
name: code-review
description: Coordinate static source-code reviews, then run StationAI CLI/XPC verification directly in the main agent. Skip non-source-only changes.
---

# StationAI task review

Use this skill for source-change tasks in this repository. For non-source-only changes as defined in AGENTS.md, stop before checks or reviewer dispatch and report NOT APPLICABLE. The main agent follows this skill directly for runtime execution; skills do not require a separate executor agent. Review the task against the user's request and product requirements, then return `APPROVED` or `REJECTED`. The routine gate is headless and quick: it runs CLI/XPC checks and reviews paired UI test quality without executing UI tests or opening the app. Run the full UI suite on demand with `$full-ui-verification`.

## Review process

1. Read the task request, applicable `AGENTS.md`, and relevant product documentation. Use read-only Git status/diff to define the current task's unstaged scope. Include relevant untracked files, exclude staged-only files and staged hunks, and assess only the unstaged delta in partially staged files.
2. Map every in-scope semantic product capability to a manager operation, CLI command, and bridge assertion. Review validation and failure paths, persistence across fresh XPC connections, ordering/state behavior, conversation history, and UI wiring. Transient focus, sheet, or selection state is outside the bridge contract.
   For AI-provider-related work, add a Claude/Codex applicability matrix to the ledger: implementation path, capability evidence, test case IDs, and any explicit permission for a one-provider design. Do not proceed past static review when parity or required permission is missing. Shared coverage is sufficient only when it exercises both applicable provider paths or proves the behavior is provider-independent; otherwise require provider-specific assertions and paired cases.
3. Check test parity with `scripts/check-test-parity.py`: every Python CLI test and Swift UI test must have the same case name and the same expectation annotation from `StationAI/BridgeTests/BridgeTestContracts.json`. Missing, extra, duplicate, or mismatched cases reject the task. Each case should focus on one logical behavior or contract; small related expectations can extend an existing case, while independent capabilities or failure paths get separate cases.
4. Phase 1 is static only. The coordinator starts `task_verifier` in `static` phase alongside `ui_verifier` and `architecture_reviewer`, with the same unstaged fingerprint and exact paired case IDs. The task verifier checks requirements, CLI coverage, parity, failure/persistence behavior, and mocks; the UI reviewer checks visible test actions/assertions; the architecture reviewer checks design. Do not build, run runtime tests, or open the app during this phase. Resolve findings and rerun only affected reviews. Record relevant review inputs and explain retained approvals when the overall fingerprint changes.
5. Phase 2 starts only after task and UI static `APPROVED` plus architecture `APPROVED` or documented `CONCERN`. The main agent verifies this evidence and the approved fingerprint, then runs `scripts/test-e2e.sh` directly for product behavior changes. Do not delegate runtime work or resume the task verifier for it. For executable runner changes without product behavior changes, the main agent performs applicable syntax checks and a focused CLI case when retry selection or result enforcement changed. A first full green run is final confirmation. Require every named contract case exactly once with no skips, failures, or incomplete results; inspect inner case counts, not just the Xcode adapter count. Use real committed Git fixtures, SwiftData, settings, and app-bundled CLI/XPC. Reject mocks or simulated implementations. If runtime fails, the main agent repairs it, affected static reviewers approve the repair, and the main agent runs only failed/affected cases, followed by one full confirmation. Build/setup failures before any cases execute require a full retry after repair and affected static approvals.
6. Keep relevant inputs stable during runtime; compare start/end fingerprints and discard stale runtime evidence when implementation/test/contract/runner inputs changed. Unrelated documentation edits do not invalidate behavioral passes. Additional `scripts/stationai.sh` workflows require a concrete coverage gap, not duplication of existing suite evidence. Live provider integration remains opt-in. Routine verification never executes UI tests; `scripts/test-full-e2e.sh` and `$full-ui-verification` remain on-demand workflows.
7. Keep a per-task verification ledger containing the phase, unstaged change fingerprint, relevant input dependencies and retained approvals, CLI commands and case IDs, UI coverage review IDs/findings, pass/fail result, and elapsed time; reuse a pass only while its relevant source/test/contract inputs are unchanged. Non-source-only changes bypass this entire gate; do not run tests, parity checks, or static reviewers for them. Routine verification does not run a UI test or capture a screenshot.
8. Audit in-scope production and test code for unapproved mocks. Static reviewers remain read-only; the main agent owns repairs and runtime execution. Do not run Git write operations.

## Decision

Return `REJECTED` when an in-scope product capability lacks CLI/XPC or paired UI coverage, parity fails, the CLI suite has missing cases, skips, failures, or incomplete results, the app does not build, an unapproved mock was added, or the UI coverage review finds weak/missing tests. Give concrete findings with file and line references and the work needed to pass review.

Label every decision with its phase. Static `APPROVED` means the applicable static checks passed; it does not assert runtime success. For non-source-only changes, report NOT APPLICABLE without tests or static reviewers. Final product approval requires both the static barrier and runtime evidence. Return final `APPROVED` only when requirements map to implementation and passing bridge assertions, persistence and failure behavior are covered, paired UI tests meaningfully check the changed visible behavior, and no unapproved mocks are present. Do not claim UI runtime success. State any Codex sign-in/model limitation when the opt-in live integration suite was not run.

## Review report

Include:

- Decision: `APPROVED` or `REJECTED`.
- Requirement-to-manager/CLI/XPC mapping and behavioral summary.
- For AI-provider-related work, Claude/Codex applicability, implementation and coverage evidence, and any authorized one-provider exception.
- Shared CLI/UI test case names and counts (separate from Xcode wrapper counts), expectation parity, matched assertions, fixture details, persistence coverage, full CLI result, and read-only UI coverage review result.
- Unstaged files reviewed; explain staged/untracked scope handling.
- Additional CLI/XPC workflows exercised or why none were needed.
- Confirm that routine verification did not run UI tests or screenshots.
- Mock audit result.
- Findings ordered by severity, if any.
