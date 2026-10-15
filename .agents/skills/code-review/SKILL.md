---
name: code-review
description: Review a StationAI implementation task by directly exercising app behavior, auditing unauthorized mocks, and checking user-visible UI quality before it is considered done.
---

# StationAI task review

Use this skill after each implementation task in this repository. Review the task against the user's request and the relevant product requirements, then return a clear `APPROVED` or `REJECTED` decision. The task is complete only when the verifier approves it.

## Review process

1. Read the task request, applicable `AGENTS.md` instructions, and relevant product documentation. Use read-only Git status/diff to define the current task's unstaged scope. Review only unstaged changes for this task, including relevant untracked files; do not approve staged-only files or staged hunks. For a partially staged file, assess the unstaged delta and use staged content only as context.
2. Identify requirements and classify the in-scope changes by their effect on app behavior, UI, tests, documentation, process rules, and configuration. Trace relevant requirements to the implementation. Look for missing states, broken interactions, regressions, accessibility or visibility issues, and scope drift where applicable.
3. For app behavior changes, build and launch the real app, then directly interact with the relevant workflows through the macOS accessibility interface or another available GUI driver. Use a fresh temporary `STATIONAI_DATA_DIRECTORY` when creating or moving data. If StationAI is already running, launch a separate instance and never reuse or terminate the pre-existing process. Check the actual app state, persistence, validation, and failure behavior that applies. The task verifier must not run automated tests, including XCTest or `scripts/test-e2e.sh`.
4. For documentation, process-rule, or verifier-configuration-only changes that cannot affect app behavior, do not launch the app; use relevant syntax or consistency checks on the changed artifacts and state why no app interaction applies. If the app cannot be launched or direct interaction is unavailable for an app-behavior task, report that gap instead of falling back to tests.
5. Audit in-scope test and production code for mocks, stubs, fakes, or simulated dependencies. Any such addition without explicit user permission is a rejection. Do not treat a separate directory for real test data as a mock.
6. Capture and inspect screenshots from the real app when the in-scope task changes user-visible app behavior or UI. Evaluate alignment, spacing, clipping, overlap, hierarchy, readable text, and control visibility. Use direct app capture during the interactive session, never a mock or static reconstruction. When the changes have no UI impact, screenshots are not applicable and should not trigger an unrelated app launch.
   - For drag-and-drop changes, capture the screenshot at the first possible moment after the drop action, before waiting for elements or UI quiescence. Inspect it for both the placed card and a leftover floating drag image or placeholder. If both are visible, reject the change and identify the duplicate in the screenshot.
   - Also record the real interaction from before pointer movement through mouse-up and the preview's disappearance. Inspect the recording frame by frame around release: the preview should track the pointer smoothly, the destination card should appear as the drag completes, and the floating preview should be gone by the next rendered frame. A screenshot of the final board or accessibility/model state alone does not verify animation timing.

## Decision

Return `REJECTED` when a required feature is missing, the verifier cannot directly exercise its relevant app workflow, the app does not build or interaction fails, an unapproved mock was added, or applicable screenshots show a material layout defect. Give concrete findings with file and line references when possible, plus the exact work needed to pass review. The implementing agent must address those findings and ask the verifier to review again.

Return `APPROVED` only when all requirements are accounted for, every applicable direct-interaction or artifact check passes, no unapproved mocks are present, and applicable screenshot review finds no material visual defects. A task with no relevant app interaction or UI impact may be approved after the in-scope checks pass, with those exclusions explained in the report.

Keep the review read-only. Do not fix the implementation while acting as verifier. Do not run Git write operations.

## Review report

Include:

- Decision: `APPROVED` or `REJECTED`.
- Requirement-to-implementation and direct-interaction summary.
- Unstaged files reviewed; identify staged/untracked scope handling.
- App workflows exercised through direct interaction and their results, or why no app interaction applies.
- Screenshot path(s) and visual assessment, or why screenshots are not applicable.
- Mock audit result.
- Findings ordered by severity, if any.
