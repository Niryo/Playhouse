# Fix chat input jumping on new lines

Task: `597740E9-2F83-4890-B224-75F813813F72`  
Unstaged source fingerprint at verification: `7bdab22f2bf5bce02c4af2e07e32bcea62938545239e4f8ecfaa83c402276aa4`

## Observed timeline

| Phase | Time or duration | Evidence and precision |
| --- | --- | --- |
| Task created; exploration and implementation began | 06:34:35 UTC, 29 Oct | Task-get timestamp supplied in the task handoff. Start of active work is unknown. |
| Composer layout fix written | By 06:37:46 UTC | Source file modification time; latest write only, not elapsed work. |
| Paired contract, CLI annotation, and UI case refined | By 06:45:00 UTC | File modification times. Task verifier rejected initial coverage then approved; UI verifier rejected three drafts before approving the fourth. Review and repair boundaries have no timestamps. Architecture approved once. |
| Parity and full CLI/XPC verification | About 06:48:12–06:54:15 UTC; **363 s measured** | Supplied run start plus runner `E2E total_seconds`; end is derived. Parity passed at 92 cases. Build 142 s, fixture 2 s, bridge cases 219 s; phase values are rounded to seconds. No focused retry or second full run was reported. |
| Handoff | After runtime verification | Exact completion timestamp unavailable; 06:54:15 UTC is the derived end of the observed verification, not a measured task-end timestamp. |

The observed task-to-runtime interval is about **19 min 40 s** (derived from supplied timestamps). The measured suite accounts for **6 min 3 s**, or 31% of that interval. The remaining **about 13 min 37 s** contains exploration, implementation, static review and repair, communication, and unobserved gaps; evidence does not divide it into active work, tool wait, or idle time. The timeline is partial through handoff.

The full run passed **92/92** bridge cases with no skips. Its build took 39% of the measured run and its case phase took 60%. The slowest named cases in the retained `/private/tmp/playhouse-bridge.X16KCP/bridge-tests.log` were `test_task_done_preserves_worktree_and_branch` (31.488 s), `test_codex_questions_can_be_answered_over_cli_xpc` (27.771 s), and `test_review_pr_conflicts_probe_and_verify` (15.166 s). Together they took 74.425 s, 34% of bridge-case time and 21% of the full run. The changed composer case took 7.587 s. Per-case durations sum to 219.531 s, consistent with the suite's 219.532 s result.

## Improvements supported by this task

1. **Make scroll visibility assertions reviewable on the first draft.** The UI review needed three revisions: first checking the outer viewport, then typing in chunks too large to catch the first hidden letters, then omitting an explicit visible-bounds assertion. Review time was not recorded, but there were three avoidable rejection and repair cycles before approval. Add a reusable UI assertion for a text editor's insertion position against its scroll viewport, and use short increments at line-wrap boundaries in the paired composer case. Check the next similar scroll regression by whether the first static UI review accepts the visibility assertion and whether each typed increment is checked.
2. **Measure the Swift probe inside the long Codex-question case.** That case took 27.771 s (13% of bridge-case time) and explicitly invokes `swiftc` before running a separate probe, but the current per-case timer does not separate compilation from probe execution. Add two elapsed-time records around those operations in `scripts/test-bridge.py`; compare them with the case total on the next full run. If compilation dominates, move the probe into the content-matched build cache used by `scripts/prepare-e2e-build.py` and verify that a second run avoids that compilation while executing the same assertion. The potential saving cannot yet be quantified more narrowly than the 27.771 s case ceiling.

## Evidence limits

Checked the supplied task timeline and verification ledger, the current unstaged diff and file modification times, `scripts/test-e2e.sh`, `scripts/test-bridge.py`, and the retained bridge log. The runner records phase and per-case durations, but the available record has no timestamped review starts/ends, repair boundaries, active-agent intervals, or handoff time. Those gaps require task-specific review/progress events or a timestamped conversation/tool transcript; file modification times cannot replace them. The build's 142 s is measured, but one full run supplies no evidence that caching failed or that this required build could be avoided.
