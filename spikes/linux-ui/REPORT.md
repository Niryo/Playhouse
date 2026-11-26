# Spike: SwiftCrossUI vs Adwaita for Swift for a Linux Playhouse

The board's task card (`Playhouse/App/TaskItemView.swift` + `AtomCard` and
the atoms it uses) rebuilt in both libraries in a Linux container, measured
the same way, and compared with the real macOS card.

**Recommendation: SwiftCrossUI, on a fork we maintain (and upstream from).**
It is the only one of the two that fits the `PlayhouseUI` plan (SwiftUI-shaped
code shared with macOS, native `@Observable`, `@State` tied to identity), it
looks closest to the native card, and it is the healthier project. Upstream
as it stands can't run our board (500 cards in 12.7 s, 2,000 in over 3
minutes, live updates starve painting). **A fork
([§8](#8-the-swiftcrossui-fork-performance-fixes-and-an-animation-poc)) fixed
that**:
- **Startup:** 500 cards in 1.9 s (Adwaita 1.6 s) and 2,000 in 7.7 s (Adwaita 13.6 s).
- **Live test:** 40 ms median update latency at 58% CPU (Adwaita 28.5 ms at 40%).
- **Lazy board:** with the fork's `LazyVStack`, any board size appears in ~0.2 s and the live test runs at Adwaita's level (41% CPU, 21 ms).
- **Animations:** the fork adds a working `withAnimation` / `.animation(_:value:)` POC with springs, which animates the card's expand/collapse and the CPU meter.

So performance no longer decides between the two: SwiftCrossUI wins on the
things that matter more (shared code, state model, health). The remaining
cost is owning a fork until the fixes are upstream. Adwaita for Swift stays the
fallback. Details in [Recommendation](#recommendation).

| | Winner | One line |
|---|---|---|
| 1. Looks | SwiftCrossUI (slightly) | both close; SwiftCrossUI nearly identical, Adwaita needs CSS for everything |
| 2. Feel | tie | both need raw GTK somewhere (SwiftCrossUI: context menu; Adwaita: hover, right-click) |
| 3. Performance | **Adwaita, by far** (upstream); **even** with the fork | upstream SwiftCrossUI is ~8–14x slower, superlinear, and starves under live updates; the fork beats Adwaita at 50 and 2,000 cards, is 0.3 s behind at 500, and uses ~1.45x Adwaita's CPU for live updates (on par with a lazy board) ([§8](#8-the-swiftcrossui-fork-performance-fixes-and-an-animation-poc)) |
| 4. Animations | Adwaita (upstream); **SwiftCrossUI fork** | upstream SwiftCrossUI has none; Adwaita has stack and CSS transitions, no `withAnimation`; the fork adds `withAnimation`, `.animation(_:value:)`, ease curves and springs |
| 5. Flexibility | SwiftCrossUI | shapes, gradients, SwiftUI layout and modifiers; Adwaita has more widgets but GTK layout + CSS |
| 6. State & observation | **SwiftCrossUI** | native `@Observable`, per-view updates; Adwaita needs a bridge and re-evaluates the whole tree |
| 7. Project health | **SwiftCrossUI** | active, ~15 contributors/year, regular releases; Adwaita: 2 contributors/year, no usable release |

## Setup

| | |
|---|---|
| Host | Colima VM on Apple silicon: aarch64, 6 vCPU, 12 GB, **no GPU** |
| Image | Ubuntu 25.10, swift.org Swift **6.3.2** (same as the Mac), GTK **4.20.1**, libadwaita **1.8.0**, GLib 2.86 |
| Display | Xvfb 1600×1400, `GDK_SCALE=2` (HiDPI), Mesa llvmpipe, `GSK_RENDERER=gl`, no window manager |
| SwiftCrossUI | `main` @ `8b39220` (2026-11-22, v0.11.0 + 6 days), GTK 4 backend |
| Adwaita for Swift | `main` @ `af5598f` (2026-10-03) + `meta` `main`; the only tag (0.1.0, 2024) doesn't build on current Linux |
| Native reference | The app's own `TaskItemView` and atoms, compiled read-only out of tree (`native/build.sh`), dark appearance, 2x |
| Data | The Plugin Catalog's sample task (`catalog/sample-task.json`) for every card shot |

Two environment findings before any UI code:

- **The official `swift:6.3.2-noble` image can't build Adwaita for Swift.**
  Ubuntu 24.04 ships libadwaita 1.5, and Adwaita for Swift generates bindings
  for 1.6/1.7 widgets at build time from the system GIR files. The image is
  therefore Ubuntu 25.10 with the swift.org 24.04 tarball (plus noble's
  `libxml2.so.2`, which the toolchain links). Both libraries use this image.
- **Adwaita for Swift `main` didn't compile against GLib 2.86**: it names two
  GLib flags as Swift enum members that Swift 6.3.2 imports as global
  constants. `patches/adwaita-glib-2.86.sh` is a two-line fix. SwiftCrossUI
  built unchanged.

## What was built

Both demos implement the same card from the same `@Observable` model
(`shared/Sources/CardModel`): title, progress report (icon, label, detail),
status message, time row (live elapsed clock when working, created date
otherwise), token counter with hover capsule, CPU meter on the leading edge,
hover state, selection ring, right-click context menu (the app's items), and a
spike-only expand/collapse section (repository chips with PR badge, mode pill)
behind a hover-revealed chevron, since the native card has no expand control.
Local state (hover, expanded, menu) is owned by each card view through the
library's `@State`, never by the model. A board demo shows N cards in a scroll
view.

All interaction in the screenshots is real input: xdotool moves the pointer
over the card, clicks the chevron, and right-clicks for the menu.

| Piece | SwiftCrossUI | Adwaita for Swift |
|---|---|---|
| Card view | `scui/Sources/SCUICard/TaskCard.swift` | `adwaita/Sources/AdwCard/TaskCard.swift` |
| App + styling | `main.swift` (SwiftUI-style modifiers; one CSS rule for the window background) | `main.swift` (one global GTK stylesheet, style classes) |
| Raw GTK needed for | context menu (gesture + `GtkPopoverMenu`) | hover, right-click trigger, level bar orientation and hit testing |
| Observation | native | a bridge (`ObservationBridge.swift`) |

## 1. Looks

![side by side](out/side-by-side.png)

| Aspect | Native (SwiftUI) | SwiftCrossUI | Adwaita for Swift |
|---|---|---|---|
| Overall fidelity | reference | **very close**: same layout, spacing and hierarchy | close: same structure; a few points of extra bottom padding, slightly lighter text |
| Font | SF Pro 13/10 pt | Inter (closest open face). Regular text renders at weight 500, which SwiftCrossUI does on purpose to match AppKit; looks closest to SF | Inter at the real weights (400/500/600) |
| Letter spacing (title tracking 0.35) | yes | **no API** (needs raw GTK/CSS) | CSS `letter-spacing` |
| Monospaced token counter | SF Mono | JetBrains Mono (`design: .monospaced` → fontconfig `monospace`) | JetBrains Mono (CSS) |
| Colors (#1E1E1E fill, 7% border, label colors, heatmap) | | exact | exact |
| Corner radius 12 + 1 px border | continuous (squircle) corners | circular arcs; no continuous style | circular arcs (CSS `border-radius`) |
| Card shadow (`black 3.5%`, r 5) | yes | **no shadow modifier** | CSS `box-shadow` |
| CPU meter (gradient masked to the fill) | `LinearGradient.mask` | exact: `GeometryReader` + a gradient slice with the computed top color (no `mask`) | approximate: `GtkLevelBar` + CSS; the fill's gradient spans the fill, not the bar, so its top is always red |
| Icons | SF Symbols | Adwaita symbolic icons by name (`hammer` → `applications-engineering-symbolic`) | same icons |
| Blur / materials / vibrancy | (not on the card; used elsewhere in the app) | none | none (GTK has no backdrop blur) |
| Dark mode | `darkAqua` | `.preferredColorScheme(.dark)` + GTK dark theme | `AdwStyleManager` force-dark |

What couldn't be matched in either: SF Pro/SF Symbols (licensing), continuous
corners, materials. SwiftCrossUI additionally lacks shadows, masks/clip shapes
and tracking without dropping to GTK.

## 2. Feel

![SwiftCrossUI hover and expanded](out/scui-states.png)
![Adwaita hover and expanded](out/adwaita-states.png)
![menus](out/menus.png)

| | SwiftCrossUI | Adwaita for Swift |
|---|---|---|
| Hover | `.onHover` (SwiftUI-like), drives local `@State` | **no hover API**: a raw `GtkEventControllerMotion` sets `@State`; pure styling can use CSS `:hover` |
| Click | `.onTapGesture`. A tap on a child also fires the parent's tap (clicking the chevron also selected the card) | `.onClick`; child buttons claim their clicks. But every `if` becomes a `GtkStack` that fills its parent, and one in an overlay (the meter) silently swallowed clicks for the chevron below until made non-targetable |
| Pressed state | none (no `ButtonStyle` configuration with `isPressed` on GTK) | CSS `:active` on GTK widgets |
| Context menu | **none**; built with raw GTK (`GtkGestureClick` + `GtkPopoverMenu`, ~60 lines of C in `GtkProbe`) | `.menuPopover(visible:)` + `MenuButton`, but no right-click trigger (raw gesture), and **`MenuButton` actions are registered window-wide by label**: with many cards, every card's "Move to Done" calls the last-updated card's handler. Worked around by routing through the right-clicked card |
| Menu keyboard navigation | yes (GTK popover menu: arrows + Return verified) | yes (verified) |
| Destructive item styling | no (GMenu has no destructive role) | no |
| Keyboard focus | `.focusable()`, `@FocusState`, `.focused` | `.focused(Binding)`, focus signal |
| Scrolling | `GtkScrolledWindow` (kinetic, overlay scrollbars) | same widget |

## 3. Performance

Numbers are relative: a 6-vCPU VM with software rendering, no GPU. Every run
is a fresh process; startup runs have the app clock off (it's measured in the
live test). "Content laid out" is the first frame whose scroll view is at least
80 px × N tall. Medians and worst of 3 runs.

### Startup and first render (board of N cards, ms from exec)

| Cards | SwiftCrossUI: content laid out, median / worst | Adwaita: content laid out, median / worst | SwiftCrossUI RSS | Adwaita RSS |
|---:|---:|---:|---:|---:|
| 50 | 923 / 1,159 | 579 / 1,848 | 208 MB | 197 MB |
| 500 | **12,671 / 12,798** | 1,592 / 1,621 | 424 MB | 303 MB |
| 2,000 | **192,896 / 237,685** (3+ minutes) | 13,555 / 14,403 | 991 MB | 658 MB |

The first frame and the "content laid out" frame are the same frame in both
libraries: neither shows anything until the whole list is built and laid out
(no lazy stacks in either).

### Scrolling 500 cards (programmatic, 40 px per frame, to the end and back)

| | Frames | Interval median / p95 / p99 / worst | Frame work median / p95 / p99 | Process CPU for the run |
|---|---:|---:|---:|---:|
| SwiftCrossUI | 2,764 | 16.6 / 21.7 / 24.2 / 317 ms | 8.1 / 12.7 / 20.5 ms | ~100 s (incl. 12 s startup) |
| Adwaita for Swift | 3,390 | 16.5 / 21.3 / 23.0 / 271 ms | 6.3 / 8.7 / 14.5 ms | ~67 s (incl. 1.6 s startup) |

(Frame counts differ because the Adwaita cards are a few points taller.)

### Live updates (board of 100 cards; all 100 update CPU fraction + tokens, plus the clock, 10x per second for 30 s)

| | Ticks done (of 300) | CPU | Model mutation per tick | Update → painted frame | Frame work |
|---|---:|---:|---:|---:|---:|
| SwiftCrossUI | **14–16** | **100%** (one core, saturated) | 4.7 ms median, 83 ms worst | no frame painted between ticks (starved) | n/a |
| Adwaita for Swift | 287–289 | 39–40% | 1.1 ms median, 13 ms worst | 28.5 median / 35.8 p95 / 112 worst ms | 3.6 / 11.7 ms (median / p95) |

Observations:

- **SwiftCrossUI's layout engine is the bottleneck, and it scales worse than
  linearly**: ~18 ms per card at 50, ~25 ms at 500, ~96 ms at 2,000. Its stack
  layout probes every child at a minimum and a maximum proposal before the
  final pass, so cost multiplies with nesting depth, and the card nests ~7
  stacks. Without the app clock, 100 cards take 1.5 s and 200 take 2.3 s; with
  the 1 Hz clock on, 200 cards never painted within 240 s, because each tick
  re-lays out every working card and the next tick arrives first.
- In the live test each SwiftCrossUI tick costs ~2 s of main-thread time
  (100 card re-layouts), so it manages 15 of 300 ticks and never paints in
  between. This is the scenario a real board runs all day (clocks and CPU
  meters on every working card).
- **Adwaita for Swift is 8–14x faster to first render** and handles the live
  test at 40% of a core with ~30 ms update latency, even though every refresh
  re-evaluates the whole tree. GTK does the layout natively and Meta only
  touches widget properties that changed.
- Scrolling is smooth in both once laid out (~60 fps, GTK scrolls existing
  widgets; neither library is involved per frame).
- Memory: both keep every card's widgets alive (no virtualization);
  SwiftCrossUI uses ~1.5x the memory at 2,000 cards.
- A 50-card board is fine in both. Software rendering in a VM inflates
  absolute numbers; the ratios between the libraries are the useful part.

**Follow-up:** the causes behind these numbers were found and mostly fixed in a
fork; see [§8](#8-the-swiftcrossui-fork-performance-fixes-and-an-animation-poc)
for the same tables with the fork.

## 4. Animations

![Adwaita expand transition frames](out/adwaita-anim.png)

| | SwiftCrossUI | Adwaita for Swift |
|---|---|---|
| Implicit animations (`.animation(_:value:)`) | **none** | none |
| `withAnimation` | **none** | none |
| Transitions | none | `.transition(StackTransitionType)` on `if`/`else` branches: crossfade, slide, over/under, rotate (GtkStack, GTK's 200 ms, no duration/curve parameter) |
| Curves / springs | none | CSS `transition` with `ease-*`/`cubic-bezier` for CSS properties; libadwaita's `AdwTimedAnimation`/`AdwSpringAnimation` exist in C but aren't wrapped |
| Expand/collapse tried | instant (verified frame by frame) | chips slide in (`.slideDown`); the card's height snaps, since the stack doesn't interpolate size |
| Meter tried | instant; animating means a timer driving local state every frame | instant: `GtkLevelBar`'s value is an allocation, not a CSS property; same timer approach needed |
| Hover border / token capsule | instant | CSS transitions (150 ms ease-out) |

The native card animates the meter (`easeInOut 1.2 s`) and the token
capsule (`easeOut 0.14 s`). Neither library can express that declaratively.
The fork in [§8](#8-the-swiftcrossui-fork-performance-fixes-and-an-animation-poc)
adds that to SwiftCrossUI as a proof of concept.

## 5. Flexibility

| | SwiftCrossUI | Adwaita for Swift |
|---|---|---|
| Custom drawing | `Shape`/`Path`, `RoundedRectangle`, `Capsule`, `Circle`, `Ellipse`; linear/radial/angular gradients; `GeometryReader` | **none in Swift**: CSS (gradients, borders, radius, shadows, filters) or raw `GtkDrawingArea`/`GtkSnapshot` in C |
| Missing modifiers that the card wanted | `shadow`, `mask`/`clipShape`, `tracking`, `scaleEffect`, `contextMenu`, animations | `onHover`, right-click, shapes, `frame(width:)` semantics |
| Styling a view freely | modifiers (`font`, `foregroundColor`, `background`, `overlay`, `cornerRadius`, `opacity`, `padding`, `frame`) | CSS classes (`.style("x")`) on one global stylesheet, plus libadwaita's named styles (`.card()`, `.pill()`, …). Per-instance values (e.g. a heatmap color) need Pango markup or per-widget CSS providers |
| Custom components (pill, chip, meter) | plain `View` structs composing shapes and text | plain `View` structs composing GTK widgets + CSS |
| Escape to raw GTK | `.inspect { (widget: Gtk.Widget) in … }`, typed Swift GTK wrappers + `CGtk` | `.inspect`/`.inspectOnAppear { storage in storage.opaquePointer }` + the whole `CAdw` C API |
| Layout model | its own SwiftUI-style layout engine over `GtkFixed` (frames, alignment, `Spacer`, `layoutPriority`, `fixedSize`, `ZStack`/overlay/background) | GTK's: boxes, `hexpand`/`halign`, `Clamp`, size requests; no `Spacer`, no `ZStack` except `Overlay`; wrapped labels need `max-width-chars` |
| Widget breadth | ~40 views/controls, cross-platform subset | everything in GTK/libadwaita, generated from GIR (50+ widgets incl. navigation, preferences, toasts, dialogs) |
| SwiftUI-likeness | **high**: `View`/`body`, `@State`, `@Environment`, `@Observable`, `@Bindable`, `ForEach`, `ScrollView`, same modifier names | medium: `View`/`var view: Body`, `@State`/`@Binding`, but different modifiers and GTK layout semantics |

### The same card code in both

The title row with the hover-revealed toggle, as the macOS SwiftUI version
would write it:

```swift
// SwiftUI (macOS)                                  // SwiftCrossUI: identical
Text(model.title)                                   Text(model.title)
    .font(.system(size: 13, weight: .semibold))         .font(.system(size: 13, weight: .semibold))
    .foregroundColor(Palette.text)                      .foregroundColor(Palette.text)
    .frame(maxWidth: .infinity, alignment: .leading)    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    .overlay(alignment: .topTrailing) {                 .overlay(alignment: .topTrailing) {
        if ui.hovering || ui.expanded {                     if ui.hovering || ui.expanded {
            Image(systemName: "chevron.down")                   Icon.system(.custom("pan-down-symbolic"))
                .onTapGesture { ui.expanded.toggle() }              .onTapGesture { ui.expanded.toggle() }
        }                                                   }
    }                                                   }
    .onHover { ui.hovering = $0 }                       .onHover { ui.hovering = $0 }
```

```swift
// Adwaita for Swift
Overlay()
    .child {
        Text(card.title).wrap().maxWidthChars(12).xalign(0).hexpand().style("ph-title")  // font, color in CSS
    }
    .overlay {
        if hovering || expanded {
            Button(icon: .custom(name: "pan-down-symbolic")) { expanded.toggle() }
                .flat().style("ph-chevron").halign(.end).valign(.start)
        }
    }
    .hexpand()
    .inspectOnAppear { storage in   // no onHover: a raw GTK motion controller
        RawEvents.attach(to: UnsafeMutableRawPointer(storage.opaquePointer), hover: { hovering = $0 }, …)
    }
```

With SwiftCrossUI, a `PlayhouseUI` layer is mostly typealiases
(`PHText = Text`, `PHVStack = VStack`, `PHState = State`, …) plus a handful of
shims for what it lacks (`Image(systemName:)` → icon-name map, `contextMenu`,
`shadow`, `tracking`, animations as no-ops or timers). With Adwaita for Swift
nearly every composite would need two implementations or a translation layer
from SwiftUI-style modifiers to GTK layout + CSS, so the shared-code promise
mostly disappears.

## 6. State and observation

| | SwiftCrossUI | Adwaita for Swift |
|---|---|---|
| `@Observable` on the Linux toolchain | `withObservationTracking`: 4/4 checks pass (tracked fires, untracked doesn't, fires once per registration, nested observables) | same toolchain, same result |
| Library support for `@Observable` | **native**: a view re-renders when an observable it read in `body` changes; only that view (and its parents if its size changed) | **none**: views update only on their own `@State`. The bridge tracks every read in a card's body and bumps a root `@State` revision once per main-loop turn |
| Redraw after model changes (title, status appears/disappears, tokens, clock tick, card removed) | 6/6 | 6/6 (with the bridge) |
| Cost of one change | the views that read it | **the whole tree's bodies are re-evaluated on any state change** (Meta's model), plus `ForEach` diffs by Levenshtein distance |
| `@State` identity in lists | follows identity: an expanded card stays expanded when cards before it are removed, inserted, or it is swapped with a neighbour (`ForEach` by id; checked through the GTK widget tree) | follows identity in the same check (`ForEach(id:)` moves storage with the element) |
| `@State` holding an `@Observable` UI-state object | works (`CardUIState` holds hover/expanded), observed like any model | not observed by the library: only assignments to a `@State` trigger updates, so the demo uses plain `Bool`s (or the bridge) |
| Bindings | `$state`, `@Binding`, `@Bindable` | `$state`, `@Binding` |
| Environment | `@Environment`, `EnvironmentValues`, custom keys | Meta `@Environment` |
| Extra | `@AppStorage` | `@State("key")` persists to disk (MetaSQLite) |

## 7. Project health

As of 2026-11-26.

| | SwiftCrossUI | Adwaita for Swift |
|---|---|---|
| Repository | github.com/moreSwift/swift-cross-ui | codeberg.org/aparoksha/adwaita-swift (moved from GitHub 2024, then git.aparoksha.dev, now Codeberg; the old domain redirects) |
| Latest release | v0.11.0 (2026-11-16) | 0.1.0 (2024-10-17), the only tag; reported not to build on current Linux |
| Cadence | 12 releases in ~9 months (every 3–6 weeks) since March 2026 | none since 2024 |
| Commits, last 90 days / 12 months | 61 / 350 | 11 / 88 (none in the last 54 days) |
| Contributors, all-time / last 12 months | ~26 / ~15 | ~10 / **2** |
| Main maintainer share | stackotter: 75% all-time, 49% last 90 days | david-swift: ~88% all-time; `meta` 99% |
| Stars / forks / open issues | 1,807 / 108 / 202 | 13 on Codeberg (812 on the archived GitHub repo) / 1 / 20 |
| License | MIT | MIT |
| Docs | DocC site, quick-start tutorial, per-backend pages, examples | DocC site, tutorial, Flatpak template |
| Platforms | AppKit (macOS), UIKit (iOS/tvOS/visionOS), WinUI (Windows), GTK 4 and GTK 3 (Linux), Android | GNOME/libadwaita only (macOS via Homebrew GTK) |
| Toolchain floor | Swift 5.10, any GTK 4 | Swift 6.3, libadwaita ≥ ~1.7 (undeclared; issue open since 2024) |
| Stability | pre-1.0, minor versions break | pre-1.0, `main` only, unversioned `branch: main` dependencies |
| Other | `LLM_POLICY.md` requires disclosing LLM use; a CI check rejects commits co-authored by Claude (matters if we upstream fixes with agents) | bus factor ~1; hosting moved twice |

## 8. The SwiftCrossUI fork: performance fixes and an animation POC

A follow-up to the gate in the recommendation below: fork SwiftCrossUI (same
pinned revision), find out why it's slow, fix what we can, and prototype
animations, in two rounds. The fork is `patches/swiftcrossui-fork.patch`:
~780 lines changed in 26 files plus ~710 lines in 6 new files (the animation
POC is 325 of them, the lazy stack ~250); `./run.sh fork` clones the pinned revision
into `fork/`, applies it, and builds, checks, benchmarks and captures the
fork in the same container as the earlier runs. The same changes are pushed
as one commit on [`Niryo/swift-cross-ui`, branch `playhouse-perf`](https://github.com/Niryo/swift-cross-ui/tree/playhouse-perf)
(commit `3a5e724`, tag `playhouse-perf-v0.1`); depend on it with
`.package(url: "https://github.com/Niryo/swift-cross-ui", revision: "3a5e724d6a5ea22e5151efca41f4e83fc97d5bbb")`,
or build the demo against it with `PH_SCUI_FORK=remote`. The demo card code is
unchanged except for `#if PH_SCUI_FORK` lines that use the animation API and
the lazy board. **The fork's card, hover and expanded screenshots are
pixel-identical to upstream's** (`compare -metric AE` = 0), and the redraw,
observation and `@State` identity checks pass with all three variants (plain
card, granular card, lazy board).

### What was slow, and the fixes

Profiled with `perf` in the container (`Dockerfile.profile`,
`scripts/fork-dev.sh perf|perflive|stats`), plus layout counters added to the
fork (`LayoutStats`, `PH_LAYOUT_STATS=1`).

| # | Cause (upstream) | Fix in the fork | Effect |
|---|---|---|---|
| 1 | **Every widget added its own display-wide `GtkCssProvider`.** GTK consults every provider on every style lookup, so 500 cards (~10,000 widgets) meant ~10,000 providers and O(N²) styling: `g_type_interface_peek` alone was 34% of startup | Content-addressed, refcounted shared styles: widgets with the same declarations share one class and one provider (`SharedWidgetStyles`); a provider goes away with its last widget | 500 cards 12.7 s → ~3.5 s; scaling becomes linear |
| 2 | GTK 4 text measurement made a new Pango context and layout per measurement (upstream fixed exactly this for GTK 3 in the pinned commit, #820, but not for GTK 4) | Port of #820 to GTK 4; cache the line-limit height per text style instead of restyling a label each time | `gtk_widget_create_pango_context` 36% → ~2% |
| 3 | Icons measured by toggling their size request (two queued resizes per probe) | A named icon's natural size is its pixel size | `gtk_widget_get_preferred_size` 16% → ~4% |
| 4 | **Each node observed its whole subtree.** Nodes wrap their entire `computeLayout` (the subtree's layout) in `withObservationTracking`, and Swift merges nested access lists into the enclosing one, so every ancestor up to the window observed every property any descendant read. One card's clock tick re-laid out its ancestors, i.e. the board | Body-scoped observation (`BodyTracking`): a node only tracks reads while evaluating its own `body` (and closures evaluated for it, like `ForEach` content and `GeometryReader`), as SwiftUI does. Descendants track their own reads and propagate size changes up through `onResize` | With 5 and 6: live test 16 → 266 ticks with the same card; enables granular updates |
| 5 | `UUID()` per observed layout (`getrandom` syscall) | A counter | ~7% of startup |
| 6 | Text re-shaped on every layout probe | Per-widget cache of recent measurements keyed by text, style, line limit and proposal | Live test latency 1.3 s → 0.1 s (plain card) |
| 7 | A `ScrollView` laid its content out twice (caching probe, then final) even when scroll bars take no space (GTK's overlay scroll bars) | One pass when the final proposal equals the probe | One board layout per pass instead of two |
| 8 | The window's minimum-size probe laid the whole board out at width 0 | A scroll view answers the zero probe without laying out its content (trade-off: it no longer imposes its content's minimum width on the window) | One board layout per pass instead of two |
| 9 | Repeated passes with no data change (a window resize that keeps the content's width) re-laid out and re-committed everything | First round: a global data generation. Replaced by 11 | Startup: 31,000 → 15,500 node layouts for 100 cards |
| 10 | `runInMainThread` leaked one context object per call (destroy notify was a no-op) | Release it | Memory |
| 11 | **A body re-evaluation re-laid out and re-committed the whole subtree**, and so did a parent re-laid out only because one child changed size: SwiftCrossUI can't compare views, since its modifiers store closures | **Per-node invalidation.** Each node stamps the views its body produces with a version, renewed only when its own inputs (observed properties, `@State`, or the view its parent passes in) changed. A child given a view from a version it already saw reuses its layout, keeps its cached probe results across commits, and skips its commit. A descendant that re-lays out at the same size only drops its ancestors' probe results. This gives the effect of SwiftUI's view comparison without making modifiers comparable | Live test: node layouts per tick −30%; window resizes and siblings of a changed view cost almost nothing |
| 12 | Every node's debug tag and every child's snapshot name were built by formatting and splitting its full generic type name | Cached per type | ~4% of startup |
| 13 | App startup read the whole executable and compared its last 8 bytes via the generic `Sequence.suffix`, which iterates every byte | Map the file, check by index | ~70 ms fixed startup cost |
| 14 | **~85% of a card's GTK widgets were `GtkFixed` containers** (59 per card), many wrapping exactly one child | A one-element `TupleView1` and `EnvironmentModifier` (`font`, `foregroundColor`, …) use their child's widget instead of wrapping it | 59 → 43 containers per card; 500 cards ~2.35 → ~1.95 s |
| 15 | A `ZStack` probed every child at size zero just to read its layout priority | Lay children out at the proposal first; fall back to the priority algorithm only when priorities differ | Meter subtree: half the layouts |
| 16 | Smaller costs in the update path: a label's Pango layout re-fetched on every commit, two environment copies per node for the resize and invalidation hooks, a pass-through check that boxed widgets | Skip unchanged label size requests, one combined hook, cache the check, stop the invalidation walk at the first ancestor with nothing else cached | Live CPU 63% → 58% |
| 17 | No lazy stack: every row of a long list gets nodes and widgets | **`LazyVStack`** (new): rows get nodes only near the visible rect, heights of the others are estimated, rows that scroll away are hidden but keep their nodes and `@State`; scrolling re-runs only the stack's layout (clean rows are reused). GTK supplies the visible rect and scroll events | Any board size in ~0.2 s and 190 MB; live test on par with Adwaita |

Layout work per 100-card startup went from ~97,000 node layouts and ~9,000
text measurements (200 cards, upstream) to ~15,700 and ~1,700 per 100 cards.

Card structure matters as it does in SwiftUI. The **granular card**
(`PH_VARIANT=granular`) moves the clock, the token counter and the meter into
their own views (`ElapsedTime`, `TokenCounter`, `CPUMeter`), so a tick
re-evaluates only those. With the plain card every tick re-evaluates the whole
card body (99% CPU in the live test below). Upstream can't benefit from
granular views at all, because of cause 4.

**A measurement correction from the first round:** the fork's live test
animates the meter on every CPU change (`.animation(_:value:)`), so it painted
~41 frames a second against Adwaita's ~19, and its CPU (75%) wasn't like for
like. The live rows below run with animations off (`noanim`), plus one
animated row. Per painted frame, the first-round fork already cost about the
same as Adwaita.

What's left, and why eager live updates still cost ~1.45x Adwaita's CPU:
- **GTK's own work on a deeper tree.** Every stack, padding, frame, overlay,
  background and `if` is a `GtkFixed`, so a card has ~43 containers. Every
  changed label re-measures and re-allocates its ancestor chain.
- **Measuring text twice.** GTK's labels measure their text again with Pango
  after SwiftCrossUI has measured it.
- **Swift overhead in the update path** (~30% of samples): environment copies,
  retain/release and generic dispatch.

Further flattening (padding and frames could become offsets on their child)
would help, but it reaches into most modifiers.

**Pre-existing upstream bug noticed on the board:** some short elapsed-time
labels on working cards render ellipsized ("2…" instead of "25m"). Upstream
SwiftCrossUI shows the same, so it isn't a fork regression. It looks like
text measured before GTK applied the label's font class. Not fixed.

### Results (same container; upstream and Adwaita rows from §3; 3 runs, median / worst)

![lazy board](out/fork-lazy.png)

| Startup, content laid out | 50 cards | 500 cards | 2,000 cards | RSS at 2,000 |
|---|---:|---:|---:|---:|
| SwiftCrossUI upstream | 923 / 1,159 ms | 12,671 / 12,798 ms | 192,896 / 237,685 ms | 991 MB |
| **SwiftCrossUI fork** | **336 / 364** | **1,945 / 2,560** | **7,733 / 7,792** | 932 MB |
| SwiftCrossUI fork, granular card | 392 / 472 | 2,049 / 2,086 | 8,392 / 9,494 | 1,006 MB |
| SwiftCrossUI fork, granular card, `LazyVStack` board | 294 / 330 | 212 / 223 | 226 / 228 | 191 MB |
| Adwaita for Swift | 579 / 1,848 | 1,592 / 1,621 | 13,555 / 14,403 | 658 MB |

| Live test (100 cards, all updating 10x/s for 30 s) | Ticks of 300 | Frames painted | CPU | Update → painted frame, median / p95 / worst |
|---|---:|---:|---:|---:|
| SwiftCrossUI upstream | 16 | 0 (starved) | 100% | n/a |
| SwiftCrossUI fork, plain card | 280 | 456 | 99% | 86 / 112 / 654 ms |
| **SwiftCrossUI fork, granular card** | **283** | **534** | **58%** | **40 / 61 / 453 ms** |
| SwiftCrossUI fork, granular card, meter animations on | 293 | 1,287 | 67% | 38 / 59 / 487 ms |
| SwiftCrossUI fork, granular card, `LazyVStack` board | 286 | 387 | 41% | 21 / 29 / 91 ms |
| Adwaita for Swift | 288 | 581 | 40% | 28.5 / 35.8 / 112 ms |

| Scrolling 500 cards | Interval median / p95 / worst | Frame work median / p95 |
|---|---:|---:|
| SwiftCrossUI upstream | 16.6 / 21.7 / 317 ms | 8.1 / 12.7 ms |
| SwiftCrossUI fork | 16.6 / 21.5 / 357 ms | 7.6 / 8.4 ms |
| SwiftCrossUI fork, granular card | 16.6 / 21.4 / 88 ms | 7.6 / 8.5 ms |
| SwiftCrossUI fork, granular card, `LazyVStack` board | 17.0 / 26.6 / 47 ms | 1.8 / 8.2 ms |
| Adwaita for Swift | 16.5 / 21.3 / 271 ms | 6.3 / 8.7 ms |

The lazy rows aren't like for like with Adwaita, which builds every card.
The native macOS board column is a plain `VStack` too. They show what
`PlayhouseUI` gets where a lazy stack fits: the app already uses
`LazyVStack` for transcripts and long lists, and a column of hundreds of
cards would qualify. The lazy board scrolls with a slightly worse p95 (26.6 ms),
because rows are built as they come into view, but no long stalls (worst
frame 47 ms vs 357 ms).

**Gate status** (set in the recommendation below: 500 cards < 2 s, 2,000 <
15 s, live < ~50% CPU and < 50 ms latency):

| | Eager board (like Adwaita) | `LazyVStack` board |
|---|---|---|
| 500 cards < 2 s | **pass** with the plain card (1.95 s median, 2.56 s worst); granular card 2.05 s | pass (0.21 s) |
| 2,000 cards < 15 s | pass (7.7 s; Adwaita 13.6 s) | pass (0.23 s) |
| Live latency < 50 ms | pass (40 ms median; p95 61 ms) | pass (21 ms) |
| Live CPU < ~50% | **not met** (58%; Adwaita 40%) | pass (41%) |

Effort for both rounds: one agent session of a few hours each. The fixes are
verified by this spike's checks, screenshots and benchmarks. SwiftCrossUI's
own test suite wasn't run, so treat them as a prototype to harden, not
finished patches.

### Animation POC

![expand](out/fork-anim-expand.png)
![meter](out/fork-anim-meter.png)

API, SwiftUI-shaped (`Sources/SwiftCrossUI/Animation/Animation.swift`):

```swift
// The card's expand toggle (TaskCard.swift)
withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { ui.expanded.toggle() }

// The meter, like the native card's
meter(cpu).animation(.easeInOut(duration: 1.2), value: cpu?.fraction)
```

| | Status in the fork |
|---|---|
| `withAnimation(_:_:)` | yes: changes made in the closure animate the updates they cause (the transaction stays pending until the queued view updates have run) |
| `.animation(_:value:)` | yes: geometry committed in the subtree animates when `value` changes; `nil` disables |
| Curves | `.linear`, `.easeIn/Out/InOut`, `.timingCurve` (cubic Bézier), `.spring(response:dampingFraction:)`, `.bouncy/.smooth/.snappy`, `.delay`, `.speed` |
| What animates | sizes and positions (so expand/collapse, reflow of siblings, the meter's fill), shapes (re-pathed at every interpolated size, so corner radii stay correct), and insertion (the inserted subtree fades in) |
| Retargeting | an animation interrupted by a new one starts from the on-screen value; a non-animated update to the same target lets it finish |
| Frame driving | ~60 Hz GLib timeout; time advances by at most 33 ms per frame, so the expensive first frame (building and painting the inserted section took ~250 ms on llvmpipe) delays the curve instead of skipping it |
| Not done | removal transitions (collapsed chips disappear at once); animatable colors/opacity of existing views (the meter's top color jumps to the final hue while its height animates; the native card masks a full gradient instead); custom `animatableData`; `matchedGeometryEffect`; velocity carry-over; vsync via `GdkFrameClock` instead of a timeout |

How it works: in an animated update the GTK backend reports each committed
size request, `GtkFixed` position and insertion to an `Animator`. It
interpolates from the on-screen value to the new one on each frame instead of
applying it at once. That works because SwiftCrossUI positions every widget
itself (`GtkFixed` + size requests), so interpolating committed geometry is
enough. Clipping during an expand uses `gtk_widget_set_overflow(HIDDEN)` on
the card. Color animation would need either animatable environment values or
GTK CSS transitions on the shared style classes; both look feasible.

### Upstreaming

Fixes 1–3, 5, 6, 10, 12, 13, 15 and 16 are local and low-risk: good PR
candidates. Fixes 4 (body-scoped observation) and 11 (per-node invalidation)
change when views update and need upstream design discussion, but they're
what SwiftUI does and the spike's checks pass. Fixes 7, 8 and 14 trade a
little generality for speed and need discussion: the zero-probe shortcut
changes window minimum sizes, and pass-through widgets share one GTK widget
between two nodes. Animations and `LazyVStack` are feature-sized RFCs. Note again that upstream's `LLM_POLICY.md` requires
disclosure and its CI rejects Claude-co-authored commits, so these patches
would have to be re-done or carefully attributed by a person before
submission. Until then a fork pinned to a revision works; rebasing ~1,500 lines
across SwiftCrossUI's 3–6-week releases is real but manageable work.

## Recommendation

**SwiftCrossUI is the library to build `PlayhouseUI` on, on a fork we pin
and maintain while the fixes go upstream.** The fork (§8) showed the
performance gap came from fixable causes, not the architecture. In this
container the fork now:
- builds 50 and 2,000-card boards faster than Adwaita and is 0.3 s behind at 500;
- keeps up with live updates at 40 ms median latency;
- with a lazy board, matches Adwaita's live CPU and starts any board size in 0.2 s.

The one gate item still open is eager live-update CPU (58% vs 40%). Animations
with springs fit its architecture. Adwaita for Swift stays the fallback.

Why SwiftCrossUI:

1. **It's the only one where shared code is real.** The card's SwiftCrossUI
   code is the SwiftUI code with a few substitutions, so `PlayhouseUI` can be
   typealiases plus a small shim layer. Adwaita for Swift would need a second
   implementation of every composite, or a translation layer we'd own.
2. **It supports our state model as designed.** `@Observable` app models and
   `@State`-owned local state (including small `@Observable` UI-state objects)
   work natively, update only the views that read them, and stay tied to view
   identity in lists. Adwaita for Swift needs an observation bridge, ignores
   `@Observable` UI-state objects, and re-evaluates the whole tree on every
   change.
3. **Looks:** closer to the native card out of the box, from SwiftUI-style
   modifiers instead of a stylesheet.
4. **Health and reach:** active, ~15 contributors a year, regular releases,
   and it also targets macOS/Windows backends. Adwaita for Swift has
   effectively one maintainer, no usable release, a build that broke with the
   current GLib, and a toolchain floor that rules out Ubuntu LTS.

Why the fork, not upstream as is: **upstream performance is a blocker.**
The measured costs (§3) come from its layout engine. Stacks probe each child
at minimum and maximum proposals, which multiplies with nesting depth; there is
no layout caching across updates for unchanged subtrees and no lazy stack.
Every live update re-lays out the changed card. §8 found the actual causes
(display-wide CSS providers per widget, subtree-wide observation, uncached
text measurement, redundant passes) and fixed them in the fork. What remains
is mostly GTK work on a deeper widget tree (a `GtkFixed` per stack, padding,
frame and `if`).

The gate: in this same container, 500 cards appear in < 2 s, 2,000 in
< 15 s, and the live test (100 cards at 10 Hz) stays under ~50% CPU with
< 50 ms update latency, roughly where Adwaita is. **Status with the fork:**
everything passes except eager live-update CPU (58%); with a `LazyVStack`
board everything passes (table in §8). Next steps if eager live CPU matters:
padding and frames as offsets instead of containers, and sharing GTK's label
measurement instead of measuring text twice.

Main risks with SwiftCrossUI:

- **Owning a fork** until the fixes are upstream: ~1,500 lines today
  (including the animation POC and `LazyVStack`). Rebasing on upstream
  releases is the ongoing cost, and the invalidation changes (§8, fixes 4
  and 11) touch the core update path, so they need upstream agreement.
- **The fork is a prototype.** It's verified by this spike's checks,
  screenshots and benchmarks, not by SwiftCrossUI's test suite. Hardening it
  is real work (see effort).
- **Live-update CPU** on eager boards is ~1.45x Adwaita's.
- **Animations are a POC** (§8): geometry, shapes and insertion fade work;
  removal transitions and animatable colors don't yet.
- **No context menu, no shadows/masks/tracking.** Menus and missing modifiers
  go through `.inspect` + raw GTK (proven here for the menu).
- **Pre-1.0 API churn.** Pin a revision and upgrade deliberately.
- **Upstream contribution friction**: its LLM policy and a CI check that
  rejects Claude-co-authored commits.

If the gate fails, Adwaita for Swift works today for a GNOME-only app.
Plan for separate Linux composites written against GTK layout and CSS, an
observation bridge like this spike's, the per-row menu workaround, and a fork
or vendored copy of Adwaita for Swift and `meta`, since the project depends on
one maintainer.

### Effort to build `PlayhouseUI` on SwiftCrossUI

| Work | Estimate |
|---|---|
| Typealias layer for the views/modifiers the composites use, compiled on both platforms | 1 week |
| Shims: SF Symbol → icon names, `contextMenu` (raw GTK, done here), `shadow`/`tracking`/`mask` via `.inspect` + CSS or no-ops, `Image(systemName:)` | 1–2 weeks |
| Fonts/metrics pass (Inter, weights, spacing) so cards match | 3–5 days |
| Performance: harden the fork's fixes and `LazyVStack` (§8, done as a spike) against SwiftCrossUI's tests and more views, and start upstreaming | 2–3 weeks |
| Optional: flatter widget tree (padding/frames as offsets), shared label measurement, to close the eager live-CPU gap | 1–2 weeks |
| Animations: take the POC (§8) to removal transitions, animatable colors/opacity, frame-clock driving | 1–2 weeks |
| Port the atoms the composites use (~30) and one composite end to end (the board) | 3–4 weeks |
| **Total to a usable board on Linux** | **~2.5–3 months for one engineer**. Performance is no longer the unknown; the main uncertainty is upstream acceptance of the fork's core changes |

## Reproducing

`./run.sh` (see README.md); `./run.sh fork compose` for just the fork. Raw
benchmark events are in `out/perf/results.jsonl` (upstream, Adwaita) and
`out/perf/results-fork.jsonl`, checks in `out/perf/*-checks.jsonl`, the
tables in `out/perf/summary.md`.
