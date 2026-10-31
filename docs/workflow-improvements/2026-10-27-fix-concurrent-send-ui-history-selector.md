# Fix concurrent-send UI history selector

## Scope and evidence

- Task: fix red UI case `test_conversation_serializes_concurrent_sends`.
- Evidence checked: supplied task conversation timeline, Tart run identifiers and per-case output, parity result, static-review fingerprint, and review outcomes.
- Observed task window: approximately 2026-10-27 21:26 to 21:30:01 local (about 4 minutes). The start has minute precision, so this is a partial, derived wall-clock duration rather than precise active-agent time.

## Timeline

| Phase | Timing | Basis |
| --- | ---: | --- |
| Task request/start | 21:26 local | Supplied timestamp; minute precision |
| Baseline Tart run `20261027T192702Z-64150` | 58.919s elapsed | Measured |
| Failing case within baseline run | 31.646s | Measured; failure at `PlayhouseUITests.swift:4888` |
| Diagnosis and selector repair | Unknown | Occurred between runs; no edit/checkpoint timestamps supplied |
| Passing Tart run `20261027T192823Z-65072` | 99.291s elapsed | Measured |
| Passing case within rerun | 24.263s | Measured |
| Parity check, 67 identical cases | 0.933s | Measured; placement within the task window is not timestamped |
| Static task, UI, and architecture reviews | Unknown | All approved fingerprint `883b2cde6c6345321203b0bce5a25acb7cf5ee0d3f45f6a4e28f1f11d1f0ba17`; exact durations unavailable |
| Completion | 21:30:01 local | Supplied passing-run end |

The two Tart invocations account for 158.210s of measured runtime. Including parity gives 159.143s. Against the approximately 241s visible task window, roughly 82s remain unreconciled; that interval includes diagnosis, the two selector edits, review activity, command overhead, and timestamp imprecision. Active work versus runtime wait cannot be separated from the supplied evidence.

## Findings and recommendations

1. **Use persistence evidence to narrow UI-selector failures.** The failed run had already proven both prompts, one thread, and two distinct turns in the persisted fixture, while the failure was a global `app.staticTexts` lookup after relaunch. The repair only changed both post-relaunch lookups to exact-label matches under `conversation-scroll-view` descendants. For similar failures, first classify whether the data assertion passed; when it did, inspect accessibility scope and label matching before investigating serialization. Verify this practice by tracking whether the next persistence-proven lookup failure is resolved without modifying product state or concurrency logic.

2. **Capture phase checkpoints in the verification ledger.** Approximately 82s of the visible window cannot be assigned, and static-review durations are entirely unknown. Record timestamps for diagnosis start, edit completion, each static review start/end, and runtime verification start/end. Verify the improvement by requiring the next optimizer report to reconcile at least diagnosis, repair, reviews, and test runtime without treating missing durations as zero.

## Slowest measured operations

1. Passing Tart invocation: 99.291s.
2. Baseline Tart invocation: 58.919s.
3. Failing case body: 31.646s.
4. Passing case body: 24.263s.
5. Parity check: 0.933s.

Suite overhead outside the named case was 27.273s for the baseline run and 75.028s for the passing run. The evidence does not explain that difference, so no optimization is recommended from this task alone.
