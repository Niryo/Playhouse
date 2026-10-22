# Native composer growth on saved-draft open

Task: restore the native composer’s dynamic height when opening a saved long draft, while preserving scrolling and responsiveness.

## Timeline and measured cost

| Phase | 22 Oct 2026, Israel time | Evidence and duration |
| --- | --- | --- |
| Implementation and static review | Ledger started 10:41:42; first runtime began 10:43:16 | 1m34s derived wall time. Individual exploration, edits, and review durations are not recorded. |
| First full CLI/XPC attempt | 10:43:16–10:44:41 | 85s measured build; aborted before cases when concurrent UI test source edits changed the reviewed inputs. |
| Repair, fingerprint refresh, and review | 10:44:41–10:47:42 | 3m01s derived wall time. The ledger records refreshed reviews, including a UI caret-shortcut correction; it does not isolate edit or reviewer time. |
| Final full CLI/XPC run | 10:47:42–10:50:42 | 180s measured. Build phase 52s, including 51.636s waiting for the build cache lock; fixture 2s; case phase 126s, including 62.476s waiting for the bridge run lock. All 54 cases passed, with no skips; actual test execution was 63.799s. |
| Completion | Run ended 10:50:42; ledger completed 10:51:14 | 32s derived wall time; actions within it are not recorded. |

The ledger covers 9m32s wall time from start to completion. About 114s of the final 180s run were measured lock waits, and the aborted first attempt added 85s of build work. The slowest individual case was the composer case at 4.950s, followed by task deletion at 3.071s and displaying an existing PR link at 2.996s. Per-case time is small relative to coordination waits. These figures come from the task conversation, verification ledger, both E2E logs, runner phase output, and their file times. Earlier user feedback and screenshot arrival have no reliable timestamps in these records; active agent time cannot be separated from all wall-clock gaps. No new UI runtime or screenshot validation occurred in this followup.

## Practical improvements

1. **Keep the reviewed source tree stable during runtime verification.** The first 85s build produced no case evidence because concurrent changes to the shared UI test source invalidated its fingerprint. Before launching a required full run, coordinate a short no-edit window for the relevant source, test, and contract files, then verify their hashes at completion as this task did. Measure avoided aborted builds across future concurrent tasks; retain the required refresh-and-rerun path whenever inputs do change.
2. **Coordinate runs sharing a cached app build.** The successful run spent 51.636s on the build cache lock and 62.476s on the bridge run lock, about 63% of its 180s duration. The runner already reports lock waits and holder details, so no new telemetry is needed. Queue same-build headless runs at the task level when parallel agents are active, then compare lock-wait totals and overall duration; unrelated builds can remain concurrent.
3. **Capture direct UI responsiveness when evaluating a visual performance fix.** Static UI review and the passing CLI/XPC suite establish coverage and app persistence, but neither measures whether a saved long draft opens at the intended height and responds promptly. The existing paired composer UI case now asserts an initial viewport of at least 239 points and growth after restart; run that focused case in Tart on demand and record time to first usable input with the same long-draft fixture. The missing measurement is specific to this task’s symptom, not a reason to expand routine CLI verification.
