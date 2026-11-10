# Chat performance profile: long conversations

> Follow-up: fixes and before/after numbers are in [chat-performance-fixes-report.md](chat-performance-fixes-report.md). That report also corrects one statement here: the app target compiles with `-O` even in Debug (it also enables coverage instrumentation).

Profiled 2026-11-10 in the shared Tart VM (`playhouse-ui`, macOS 26.6.2, 6 vCPU, 12 GB, Xcode 26.5) against the **Debug** build, the configuration `scripts/run.sh` ships. Instruments recorded each phase separately with Time Profiler and Hangs (`xctrace record --attach`).

## TL;DR

The guess was right: the chat transcript is where the time goes. Opening a long chat and sitting idle in it are cheap. Every *change* to an open long chat is expensive, because one streamed text chunk, one keystroke or one mouse movement makes SwiftUI revisit the whole rendered transcript.

| # | Issue | Evidence | Impact |
|---|-------|----------|--------|
| 1 | Each streamed text delta re-renders, re-compares and re-lays-out the entire rendered transcript | Main thread 80–100% busy for the whole stream; ~37–42 ms of main-thread time per delta | Streaming into a long chat saturates the UI thread: dropped frames, laggy input and scrolling while an agent is answering |
| 2 | SwiftUI compares `[ConversationMessage]` arrays element by element on every update | `AGDispatchEquatable → Array.==` is 16% of streaming time; copies and destroys of `ConversationMessage` add another ~11% | O(messages) work per delta, independent of what changed |
| 3 | `ConversationTranscriptLayout` measures every row twice per pass, with no cache, and is not lazy | `placeSubviews` + `sizeThatFits` ≈ 14% of streaming time (7.7 s) | O(rendered rows) layout per delta, per keystroke and per resize |
| 4 | Hit testing walks every rendered row's responders on every scroll or mouse event | `ViewResponder.hitTest` is 5.0 s of 14.8 s of app-side scroll work (34%); `_routeScrollWheelEvent` adds 2.2 s | Scrolling a long chat costs ~50 ms per event and gets worse as the rendered window grows |
| 5 | The rendered window only grows | After scrolling up, every later delta, keystroke and hit test pays for all the revealed rows | Issues 1–4 get worse the longer a session lasts |
| 6 | Each composer keystroke re-lays-out the whole window's SwiftUI tree | ~17 ms of main-thread time per keystroke; 53% of it is root `NSHostingView.layout()` | Typing in a long chat is sluggish, especially while a reply streams |
| 7 | Navigating away from a long chat whose rendered window has grown is slow | First task switch: ~3.8 s of app main-thread work; Hangs recorded 1.24 s and 1.57 s hangs | Visible freezes when switching tasks |
| 8 | Smaller per-update costs: string work in `body`, synchronous FS and SwiftData reads | `displayableAssistantText` 2.1%; `isRepositoryRootConfigured` stats the filesystem on each composer body; SwiftData fetches per revision bump (static) | Constant-factor waste on each update |

Things that are **fine**:
- **Idle:** 5 ms of CPU in 10 s, either in a long chat or on the board.
- **Opening a 752-message chat:** ~0.8 s of app work, because only the newest page is read. One 411 ms microhang.
- **Window resize:** ~0.4 s for 4 zoom toggles.

---

## Method

The harness was a scratch copy of the repository in `/tmp/playhouse-perf`. Nothing in this worktree's source changed. It contained:

1. **Simulated provider.** A patched copy of `scripts/fixtures/claude-code-fixture.py` answers `perf-turn N` prompts with realistic long agent turns. Each turn has:
   - streamed commentary;
   - 5–9 tool calls (Read with 220-line outputs, Grep with 60 hits, Bash with 80 lines of test output, Edit with 18-line diffs);
   - a long markdown answer with headings, bullet lists, a table, Swift and Bash code blocks and links.

   The stream is roughly 1,250 text deltas and ~250 KB per turn.
2. **Seeding.** A scratch UI case, `test_perf_profile_long_chats`, seeded data through the real CLI, daemon and SQLite store:
   - **Perf long chat:** 120 turns, giving 752 messages plus activities. The store was 5.7 MB.
   - **Perf medium chat:** 40 turns.
   - 6 board filler tasks.

   Seeding took 81 s.
3. **Recording.** A guest-side controller started `xctrace` attached to the running app for each phase and stopped it when the phase ended:

| Phase | Wall time | App main-thread CPU | of which XCUITest AX queries |
|---|---|---|---|
| 01 Open long chat (newest page pinned) | 5.1 s (includes a 3 s settle) | 1.4 s | 0.6 s |
| 02 Idle in long chat, 10 s | 10.0 s | **~0 s** | – |
| 03 Scroll up 50 × 600 pt, then down 50 × 600 pt | 51.0 s | 23.4 s | 8.5 s |
| 04 Type ~330 characters into the composer, then clear | 14.9 s | 8.5 s | 2.6 s |
| 05 Stream a live reply into the long chat | 61.8 s | **54.7 s (80–100% for the whole stream)** | 6.3 s |
| 06 Switch long ↔ medium chat × 3 | 27.8 s | 13.5 s | 6.3 s |
| 07 Window zoom/unzoom × 4 | 12.9 s | 1.6 s | 1.2 s |

App memory (RSS) grew from 249 MB after the open to 369 MB after streaming.

Hangs recorded by the Hangs instrument: open 411 ms; scroll 607 and 689 ms; typing 561, 543, 456 and 453 ms; stream 505, 465 and 305 ms; task switch **1.24 s and 1.57 s**.

### Caveats

- **XCUITest's accessibility queries are harness cost.** In the AX stacks, `XCTAccessibilityFramework attributesForElement:` accounts for 5.3 of 6.3 s in phase 06. They are reported separately above and excluded from the per-issue numbers. They still show that the transcript's AX tree is expensive to serialize: a real AX client such as VoiceOver, a window manager or a text expander would pay the same.
- **Stream duration is not app slowness.** `time.sleep(0.012)` takes ~61 ms in the VM, so the fixture's pacing set the 62 s phase-05 duration. The bridge client reads on a detached thread into an unbounded `AsyncStream` (`DaemonClient.swift:118`), so a slow UI does not back-pressure the daemon. The finding is the per-delta cost: ~54.7 s of main-thread CPU for ~1,300 deltas.
- **Debug build, virtual GPU.** `-Onone` exaggerates Swift-side costs, and CoreAnimation commit times on the VM's paravirtual GPU are not representative. Relative rankings are the useful signal; absolute milliseconds will be lower on a real Mac with a Release build.
- **Scope gaps:**
  - The daemon was not profiled.
  - Only the Claude history path was seeded. Codex rendering uses the same `TaskConversationView`; its history loads through `thread/resume`.
  - The SwiftUI-template recording of a second stream was abandoned. It produced 1.8 GB in ~60 s and xctrace could not finish saving it, which itself reflects the volume of attribute-graph updates.
  - The board-idle phase did not run, because the scratch case stopped after the SwiftUI recording timed out.

---

## Issues in detail

### 1. Streaming: one delta re-renders the whole transcript

Phase 05 kept the main thread busy 80–100% for the entire stream. Breakdown of the 54.7 s:

| Bucket | Time | Share |
|---|---|---|
| CoreAnimation commit (display-cycle layout and flush) | 12.3 s | 22.5% |
| SwiftUI view-input equality (`AGDispatchEquatable`) | 10.8 s | 19.7% |
| └ of which `Array<ConversationMessage> ==` | 8.8 s | 16.1% |
| `ConversationTranscriptLayout.placeSubviews` / `sizeThatFits` | 5.2 s / 2.5 s | 9.4% / 4.6% |
| `TaskConversationView.transcriptRows` / `messageBubble` | 3.8 s / 2.9 s | 7.0% / 5.3% |
| `ConversationMessage` copy / destroy | 3.2 s / 2.7 s | 5.9% / 4.9% |
| Markdown parse (streaming message only) | 1.3 s | 2.4% |
| `displayableAssistantText` | 1.1 s | 2.1% |
| XCUITest AX queries (harness) | 6.3 s | 11.5% |

Why it happens:
- `applyStreamedUpdate` appends each delta to the view's `@State` array (`messages[messageIndex].text += delta`, `TaskConversationView.swift:6362`).
- All transcript state is `@State` on the single ~8.5k-line `TaskConversationView`, so each delta invalidates the whole body. SwiftUI then:
  - rebuilds every rendered row (`transcriptRows(for:context:)`);
  - compares every row's inputs;
  - re-measures and re-places every row;
  - runs `updateNSView` on every AppKit-backed text row.
- Deltas are applied one at a time on the main actor with no coalescing (`DaemonClient.call` delivers each event through `AsyncStream`; `RemoteConversationManager.forwardUpdates` decodes each one on main).

Fix direction, highest leverage first:
- **Coalesce deltas.** Buffer `text_delta` events and apply at most once per frame (~16 ms) or every 30–50 ms. This alone divides the per-token cost by the batch size.
- **Isolate the streaming message.** Move the in-flight assistant text into its own `@Observable` model that only its row reads, so a delta invalidates one row instead of the transcript. Settled rows should be `Equatable` views (`.equatable()`) keyed on stable values.
- **Split state ownership.** Move transcript state out of `TaskConversationView` into an observable store. Each row should observe its own message, for example via an ID lookup into a dictionary of per-message observable objects. This turns O(rows) invalidation into O(1).

### 2. Whole-array equality on every update

`AGDispatchEquatable → static Array<A>.==` is 8.5 s on its own, and its leaves are `ConversationMessage.__derived_struct_equals`, `initializeWithCopy` and `destroy`. Candidate sources:
- `.onChange(of: messages)` (`TaskConversationView.swift:1817`);
- `.onChange(of: messages.map(\.text))` (`:3602`), which also builds a fresh array of every message's full text on each body pass;
- `.onChange(of: activities)` (`:3607`);
- arrays passed as view inputs, such as the row context and `renderedConversationMessages`.

The `onChange(of: messages.map(\.text))` handler only acts when `!hasPresentedLatestConversation`, yet the map and compare run on every body evaluation.

`ConversationMessage` (`ConversationModel.swift:119`) holds strings, `imageDataURLs`, optional arrays and a `Date`. Each copy retains and releases several references, which explains the heavy `swift_retain/release` and `swift_bridgeObjectRetain/Release` self time (~12% of samples).

Fix direction:
- Replace these `onChange` triggers with cheap scalars: `messages.count`, the last message's ID and text length, or a revision counter bumped by the model.
- Make row inputs small value types (ID plus revision) rather than whole messages or arrays.

### 3. Custom transcript layout: non-lazy, uncached, measured twice

`ConversationTranscriptLayout` (`TaskConversationView.swift:7622`) calls `measure()`, which calls `sizeThatFits` on every subview, from both `sizeThatFits` and `placeSubviews`. Its comment says it deliberately has no cache: "a row that grows on its own … would otherwise leave a stale filler". The transcript is a plain `VStack`; LazyVStack was dropped on purpose (`:3447`).

Measured cost:
- 7.7 s during streaming;
- 0.8 s in task switching;
- 1.2 s of `ConversationTranscriptLayout.measure` across phases 03 and 06.

Fix direction:
- Cache row sizes in the layout's `cache`, keyed by subview identity and proposed width, and invalidate only the rows whose content changed. A per-row revision can be published through a `LayoutValueKey`.
- Longer term, consider an `NSTableView` or `NSCollectionView`-backed transcript, which virtualizes rows and handles self-sizing AppKit rows. That would address issues 3, 4, 5 and the AX cost together.

### 4. Scrolling: hit testing scales with rendered rows

App-side scrolling cost (excluding the harness's AX queries) was 14.8 s for 100 scroll gestures:

| Cost | Time | Share |
|---|---|---|
| `-[NSScrollView hitTest:]` → `HostingScrollView.PlatformGroupContainer.hitTest` → `ViewResponder.hitTest` | 5.0 s | 34% |
| `_routeScrollWheelEvent` → `NSThemeFrame _hitTestForEvent:` | 2.2 s | 15% |
| `-[NSTextView mouseMoved:]` forwarded through the responder chain | 1.6 s | 11% |
| Layout (`layoutSubtreeIfNeeded`) | 3.5 s | 24% |

The cause is that SwiftUI's responder-based hit test visits every responder in the transcript, and nothing is lazy. Every row contributes:
- `.nativeHelp` tooltips (dozens in this file);
- buttons;
- hover handlers;
- AppKit `NSTextView`s (`SelectableAnnotationText`, `CodeBlockTextView`).

Fix direction:
- Virtualize rows (see issues 3 and 5).
- Reduce per-row responders: attach tooltips and hover only to visible interactive controls, and avoid `.help` on text containers.
- Make settled text rows a single responder.

### 5. The rendered window never shrinks

`renderedConversationMessages` runs from `oldestRenderedMessageID` to the end. Scrolling up reveals 40 messages at a time; `loadEarlierConversationMessages` loads 80-message pages from the store. Nothing un-renders rows that scroll far out of view. In phase 05, which ran after the phase-03 scroll-up, every delta paid for all the rows revealed earlier. That is a likely reason the per-delta cost (~40 ms) is so high.

Fix direction:
- Trim the window when the reader returns to the bottom or when a new turn starts, keeping e.g. the latest two pages rendered.
- Better, use real virtualization.

### 6. Typing: every keystroke lays out the whole window

Phase 04 used 5.9 s of app-side main-thread time for ~330 keystrokes, about 17 ms each:
- 53% is `NSWindow layoutIfNeeded` → `NSHostingView.layout()` for the whole window. That splits into an attribute-graph flush (1.5 s) and `sizeThatFits` through the root ZStack/Padding/FlexFrame (0.9 s).
- `NSTextView keyDown` itself is only 0.4 s.

What is already right: the transcript's *body* is not re-evaluated per keystroke (`transcriptRows` was only 37 ms), because the draft lives in `ComposerDraftModel` (`:138`). What still happens:
- The editor's layout requests (`ChatEditorScrollView.requestTextLayout`, `layout()`) invalidate the root hosting view's layout, so SwiftUI re-walks the window's graph.
- `composerHeight` is parent `@State` (`:1005`). When the editor grows a line, the whole `TaskConversationView` re-renders.
- `isRepositoryRootConfigured` (`:1181`) calls `WorkspaceSettings.validDirectoryURL`, a filesystem check, every time the composer body evaluates.

Fix direction:
- Host the composer in its own `NSHostingView`, or give the editor a fixed-height container whose size changes only on line-count changes, so keystrokes don't dirty the root layout.
- Keep `composerHeight` inside the composer subtree.
- Cache the repository-root validity in state, refreshed on settings change.

### 7. Leaving a long chat is slow

The first switch from the long chat, whose rendered window had grown in phases 03 and 05, to the medium chat cost ~3.8 s of app main-thread work. Later switches, with the window re-pinned to the newest page, cost ~0.5–1 s each. The Hangs instrument recorded 1.24 s and 1.57 s hangs. The stacks are the same transcript rebuild seen in issue 1 (`transcriptRows`, `ConversationMessage` equality and copies, layout), which suggests the transcript re-renders several times during the navigation transition.

Fix direction:
- Avoid rendering the outgoing transcript during the transition, for example by replacing it with a lightweight placeholder before navigating.
- Trim the window as in issue 5.

### 8. Smaller per-update costs

These come from the code audit, and many are confirmed by the profile:
- `displayableAssistantText` (`:4479`) runs two `replacingOccurrences` and a trim over each assistant message's full text, twice per row per pass: 1.1 s during streaming.
- `transcriptRows` does O(n) scans per row: `providerBoundaries.filter { renderedAnchorMessageID… }`, which rebuilds `renderedConversationMessages` for each boundary; `goalAchievementTimelineEntries.filter`; `conversationMessages.first(where:)`; `activities.filter { isContextCompaction }`. Together that is O(rows × n) per pass. Precompute these lookups once per update into dictionaries.
- `followConversationBottom` (`:1502`) schedules a `Task { proxy.scrollTo(...) }` on every scroll-geometry change while following. Each delta grows the content, triggering another scroll and another layout pass.
- Main-thread synchronous reads, found statically and not individually visible in this profile:
  - `refreshQueuedMessages` runs a SwiftData fetch on every conversation revision bump.
  - `assistantLabel` → `cachedModels` builds a `RemoteConversationManager`, runs SwiftData fetches and decodes JSON per old-provider assistant row per pass. It only matters in chats that switched provider; it did not occur here.
  - `refreshChatPageStatus` and `ChatPageRecallRow` open SQLite and run migrations on main, for standalone chats.
- `RemoteConversationManager.forwardUpdates` decodes each event via `BridgeValue.decoded`, which re-encodes to JSON and decodes again, on the main actor. Not prominent per delta here; it grows with `history` and `completed` payloads.
- `WorkspaceChangeWatcher` FSEvents → `refreshWorkspaceChanges` writes `changeInventory` `@State` and re-renders the whole transcript while the agent edits files. This cannot show in this profile, because the fixture's file paths are outside the worktree, but it compounds issue 1 during real coding turns.
- Running Playhouse as a Debug build (`scripts/run.sh` uses `-configuration Debug`) adds a constant factor to everything above. Offering a Release or `-O` daily-driver build is a cheap win.

---

## Suggested order of work

1. **Coalesce streamed deltas** to one apply per frame (issue 1). Small change, largest immediate win.
2. **Remove whole-array `onChange` triggers and shrink row inputs** (issue 2).
3. **Cache row measurements** in `ConversationTranscriptLayout` and **trim the rendered window** back to the newest pages (issues 3, 5, 7).
4. **Isolate composer layout and `composerHeight`** from the transcript (issue 6).
5. **Per-row observation and an equatable settled-row view.** This is a structural change to `TaskConversationView` state ownership (issues 1 and 2 at the root).
6. **Evaluate a virtualized AppKit transcript** (`NSTableView`) for issues 3–5, hit testing and AX together.

For each step, re-run this scenario and compare per-phase main-thread CPU. The target is streaming well under 50% main-thread use and under ~4 ms per keystroke on the same chat.

## Reproducing

The harness lives outside the repository in `/tmp/playhouse-perf`:
- `perf_fixture_patch.py` adds the long-turn fixture reply;
- `perf-controller.sh` is the guest-side `xctrace` controller;
- `PerfScenario.swift.txt` is the scratch UI case;
- `analyze_trace.py`, `stacks.py`, `buckets.py` and `noax.py` analyze the traces.

The raw `.trace` bundles for phases 01–07 are in `/tmp/playhouse-perf/traces`.

To re-run: patch a scratch copy as described, then run `PLAYHOUSE_UI_LOCK_TIMEOUT_SECONDS=5400 scripts/test-ui-tart.sh --case test_perf_profile_long_chats`. Export with `xctrace export --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]'`, then `python3 stacks.py parse <xml> <pkl>` and `python3 buckets.py <pkl>`.
