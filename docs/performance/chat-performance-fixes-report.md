# Chat performance fixes: before/after

This follows [chat-performance-report.md](chat-performance-report.md). It records what was fixed, what was deliberately left alone and why, and the measured result.

Every change is in `Playhouse/App/TaskConversationView.swift`. Nothing new is cached across transcript passes.

## Result

Baseline (`HEAD`) and fixed build were profiled with the identical scripted session in the Tart VM:
- the same seeded data: a 752-message chat, a 40-turn chat and 6 filler tasks;
- the same Debug build configuration;
- the same harness.

The numbers are main-thread CPU of the app, excluding the XCUITest accessibility queries the harness itself triggers.

| Phase | Before | After | Change | Second fixed run |
|---|---|---|---|---|
| Stream a live reply into the long chat | 17.0 s | **12.3 s** | **−28%** | −25% |
| Switch long ↔ medium chat × 3 | 7.9 s | **5.8 s** | **−27%** | −24% |
| Scroll up/down 100 × 600 pt | 18.3 s | **14.9 s** | **−19%** | −16% |
| Type ~330 characters in the composer | 7.2 s | **6.2 s** | **−15%** | −14% |
| Open the long chat | 0.91 s | **0.79 s** | **−14%** | −13% |
| Idle in the long chat, 10 s | 22 ms | 5 ms | – | – |
| Window zoom × 4 | 0.47 s | 0.50 s | ≈ | ≈ |
| Board idle after the chat, 10 s | 0.15 s | 0.15 s | ≈ | ≈ |

"Second fixed run" is an earlier profile of the same fixes, before the last small `displayableAssistantText` correction. The two fixed runs agree within 3 points, so the gains are reproducible rather than noise. The baseline was profiled once.

**While a reply streams, the main thread went from 84% busy on average (peaking at 92%) to 63% (peaking at 75%).** The UI now has headroom for input and scrolling during a stream; before, it was close to saturated.

Where the streaming time went, in ms:

| Cost | Before | After |
|---|---|---|
| SwiftUI view-input equality | 3,058 | 1,289 |
| of which comparing message arrays | 2,539 | 1,033 |
| `ConversationMessage` copies and destroys | 1,742 | 643 |
| `transcriptRows` | 1,131 | 554 |
| Transcript layout, place and size | 2,513 | 2,029 |
| `displayableAssistantText` | 351 | 188 |
| CoreAnimation commit (display and layout flush) | 3,267 | 3,867 |

The commit share rises because the app now renders the stream more promptly within the recorded window.

Task switching: message-array equality fell from 509 ms to 2 ms, `ConversationMessage` copies and destroys from 347 ms to 5 ms, and `transcriptRows` from 220 ms to 13 ms.

## What changed

1. **Streamed text is applied in batches.** Each `text_delta` used to append to `@State messages` immediately, and every write re-renders and re-compares the whole transcript. Deltas now collect in `PendingStreamedTextDeltas` and are applied at most every 50 ms. This is a buffer of not-yet-shown text, not a cache of derived data.
   - Ordering is preserved because every other update flushes the buffer before it applies. The same is true of every other writer of `messages`: `applyHistoryMessages`, `loadConversation` and `showLocalSteer`.
   - The end of a send (success or error) and the end of a watched turn flush too.
   - Buffered text for another task is dropped, never shown.
2. **Whole-array `onChange` triggers became conditional.** Three triggers compared the entire transcript on every pass:
   - `.onChange(of: messages)`
   - `.onChange(of: messages.map(\.text))`
   - `.onChange(of: activities)`

   Their handlers only act in rare states: while a recovered private reply waits to be shown, or before the conversation is first presented. They now compare `nil` outside those states, and the handlers ignore the switch between `nil` and a value.
3. **The transcript `ForEach` iterates `(id, index)` references.** It used to iterate the messages themselves, and SwiftUI compares a `ForEach`'s data on every update. Row identity is still the message ID.
4. **Per-row scans run once per pass.** Each row filtered all provider boundaries and goal achievements and called `renderedAnchorMessageID`, which rebuilt the rendered window. It also scanned every message to find the next timeline order, even with no context compaction present. `makeTranscriptRowContext` now groups boundaries and goal entries by their anchor once per pass, and the compaction scan runs only when a compaction exists.
5. **`displayableAssistantText` returns its input when there is nothing to strip.** That is the case when the text contains no `<` byte and has no leading or trailing whitespace.
   - The first version used `String.contains("proposed_plan>")`. The profile showed that generic substring search was slower than the replacements it skipped (351 ms became 568 ms).
   - A byte scan for `<` replaced it, bringing the function down to 188 ms. Both tags contain `<`, so the result is identical.

## Issues deliberately not fixed

| Report issue | Why it was left | Suggested next step |
|---|---|---|
| 3: `ConversationTranscriptLayout` measures rows twice, uncached | The only fix is caching row sizes across layout calls, which is exactly the risky kind. The layout's own comment explains that AppKit rows grow on their own and a cache would leave stale filler. The 50 ms batching already cuts the number of layout passes. | Revisit only together with real row virtualization. |
| 4: Hit testing scales with rendered rows | It is SwiftUI's own responder walk, about 6.6 s of the scroll phase. The fix is to render fewer rows. | Virtualize the transcript (`NSTableView`) or trim the window, below. |
| 5: The rendered window never shrinks | `test_conversation_history_pages_claude_transcript_from_store` asserts that a turn sent after scrolling up "keeps the earlier pages loaded without reading them again". Trimming changes that tested contract, so it needs a product decision first. | Decide whether to trim when the reader returns to the bottom; if yes, update that contract and both suites. |
| 6: Each keystroke lays out the whole window | The transcript body is already not rebuilt per keystroke. The remaining cost is SwiftUI laying out the window's root hosting view after the composer's state changes. Fixing it means hosting the composer separately, a structural change with focus and accessibility risk. | Host the composer in its own `NSHostingView`. |
| Root cause of 1 and 2: all transcript state is `@State` on one view | Every write to `messages` still makes SwiftUI copy and compare the old and new array: the remaining ~1 s of "message arrays" while streaming. Batching makes it happen less often. Removing it means moving transcript state into an observable model that rows observe individually. | The structural refactor in the original report's step 5. |
| 8: Main-thread SwiftData/SQLite reads, `BridgeValue.decoded` double decode, workspace-change re-renders | These did not appear in the profile at meaningful cost. Changing them without evidence adds risk for no measured gain. | Re-profile a real coding turn with file edits before touching them. |

## Corrections to the original report

- **The app target is optimized even in Debug.** Its `swiftc` invocation uses `-O`, not `-Onone`, so the original report's warning that Debug "exaggerates Swift-side costs" was overstated.
- **The Debug build also compiles with `-profile-generate -profile-coverage-mapping`.** This is code-coverage instrumentation, and it is why a `default.profraw` appears in the repository root. It does add overhead to the build `scripts/run.sh` launches for daily use, and turning it off for that build is a cheap, separate win.

## Open observation

The fixed runs show a ~1 s app-side hang when the streamed turn completes: the completed history replaces the streamed rows, row views are re-created and the transcript is re-measured. About as much time again in that window is harness accessibility queries.

The baseline trace shows no such hang inside its window. The most likely reason is that the saturated baseline was still catching up on deltas and settled the turn after its recording stopped. The completion code path itself is unchanged.

This is consistent with the evidence but not proven. A focused profile that keeps recording a few seconds after the turn ends would settle it.

## Verification

- Static reviews of the final change (fingerprint `91786145c40ea010`): task verifier APPROVED, UI verifier APPROVED, architecture reviewer APPROVED. Their suggested hardenings were applied and re-approved: the flush in `applyHistoryMessages`, `showLocalSteer` and `loadConversation`.
- Headless CLI/XPC suite (`scripts/test-e2e.sh`, full, on the final tree): 186/186 passed, 0 skipped.
- Focused UI cases in Tart (`scripts/test-ui-tart.sh --case …`, on the final tree): 9/9 passed. Each covers part of the change:
  - `test_conversation_follows_latest_streamed_messages`: interleaved deltas and progress, following while streaming.
  - `test_plan_mode_renders_markdown_in_conversation`: deltas with nothing after them, so only the 50 ms apply can show them, and plan-tag stripping.
  - `test_conversation_history_pages_claude_transcript_from_store`: `ForEach` references as the window grows.
  - `test_conversation_shows_context_compaction`: compaction rows.
  - `test_conversation_provider_switch_waits_for_settled_turn_and_records_boundary`: provider-boundary rows.
  - `test_thread_goal_lifecycle_persists_through_cli_xpc`: goal rows, including an anchor outside the window.
  - `test_codex_pending_question_recovers_after_provider_process_restarts`: the conditional recovered-reply trigger.
  - `test_turn_events_stream_to_a_watcher_that_did_not_send`: the watched-turn flush.
  - `test_conversation_steers_and_queues_active_turn`: the steer flush.
- Provider parity: the change is shared client-side presentation. Claude and Codex both reach `applyStreamedUpdate` through `RemoteConversationManager.send` and `watch`, and the focused cases include both providers.
- Screenshot showcase: not applicable. The change is meant to be visually identical.

## Reproducing the comparison

The harness lives in `/tmp/playhouse-perf`:
- `make-scratch.sh` makes a patched scratch copy of a source tree;
- `run-profile.sh` runs the scenario in Tart and collects the traces;
- `export-all.sh` exports and parses the traces;
- `compare.py <base> <fix>` prints the tables above.

The traces are in `out-base`, `out-fix` and `out-fix2`.
