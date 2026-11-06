# Add a Persistent Sidebar to the Kanban Page — Window Growth Follow-up

Task: `15BBAF9C-70D1-48DC-B605-DDC16C07403A` (2026-11-06, Asia/Jerusalem).

Scope: when standalone chat opens over the Kanban board, grow the app window so the shifted columns stay visible, matching master's behaviour.

## What happened

1. The first implementation resized the window by hand: a `BoardWindowFrameController` captured the `NSWindow`, called `setFrame(_:display:animate:)` to widen it by the chat width, and restored the saved frame on close. An initial screen-bound clamp blocked any growth on the Tart VM display; removing the clamp made the focused UI case pass.
2. The user reviewed the running app and rejected it: the AppKit frame animation ran out of step with SwiftUI's panel transition, and the geometry was computed manually. On master the window grew without any window code, because the chat sat in an `HStack` beside a `minWidth: 980` board and the scene uses `.windowResizability(.contentSize)`.
3. The controller was removed. `mainContent` now sets `minWidth: 980 + chatSidebarWidth` while the chat overlay is visible, so SwiftUI grows the content-sized window to the same width as master (about 1440 pt). As on master, closing chat keeps the grown window width; the sidebar, header and columns return to their positions.

## Improvements

1. **Check how master achieves a behaviour before rebuilding it.** The window growth on master was a side effect of a minimum content width under `.windowResizability(.contentSize)`. Reproducing that constraint would have avoided an imperative AppKit controller, its saved-frame state, and the screen-clamp failure.
2. **Prefer SwiftUI-owned sizing over `NSWindow.setFrame` for content-driven window changes.** Imperative frame animation runs on its own timeline and does not stay in step with SwiftUI transitions.
3. **Show the running app for animation and feel changes.** Tests confirmed the window grew and the columns fit, but only a person watching the app could judge whether the animation felt right.
