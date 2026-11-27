# Plugins

A plugin is plain JavaScript that builds UI with React. A custom React
renderer running in JavaScriptCore turns each commit into mutation ops. Swift
applies them to an observable node tree, and SwiftUI draws that tree from
native **atoms**. Plugins compose only atoms. Composites such as the task
item, a board column's frame, the board's Agents info section, the Token Stats modal, the Skills
page's header and gallery, the task header's repository chips and Add
repository picker, the conversation composer's box and the board's Done
archive exist only as native SwiftUI built from the same atoms
(`Playhouse/Views/TaskItemView.swift`, `DoneArchivePanel` in
`Playhouse/Views/DoneArchiveView.swift`,
`KanbanColumnSection` in `Playhouse/Views/KanbanColumnSection.swift`,
`ComposerView` in `Playhouse/Views/ComposerView.swift`, `AgentsInfoSection` in
`Playhouse/Views/AgentsInfoView.swift`, `TokenStatsView` in
`Playhouse/Views/TokenStatsView.swift`, `SkillsPageHeader` and
`SkillGalleryView` in `Playhouse/Views/SkillGalleryView.swift`,
`RepositoryChipsView` and `RepositoryPickerView` in
`Playhouse/Views/RepositoryChipsView.swift`). The skill and rule editors'
previews (`SkillMarkdownPreview` in `Playhouse/Views/SkillsPageView.swift`),
the side chat's replies, the question form and the transcript's replies and
progress notes are built from the `Markdown` atom, the app's one Markdown
renderer; the transcript passes it a native-only `MarkdownTextHost` for its
comments and side chats.

| Path | What it is |
| --- | --- |
| `Playhouse/Core/Plugins/Runtime/` | PlayhouseCore, Foundation only: `PluginRuntime` (runs a plugin's script on a `ScriptEngine`; `JavaScriptCoreScriptEngine` is the macOS engine, under `#if canImport(JavaScriptCore)`), `PluginNodeTree` (ops → nodes), `AtomProps` (atom names and props), `AtomEvents` (where atoms send their events: a plugin's runtime or a native tree's `AtomEventHandlers`), `PluginRenderCommand` (`playhouse plugin render`), `PluginCommands` (the `/` commands a plugin exposes: their manifest, the handlers' results, `JavaScriptCommandHandler` and the daemon's `PluginHeadlessHost`). Also compiled into the bridge daemon. |
| `Playhouse/Core/Plugins/Services/` | PlayhouseCore: plugin services and the built-in commands that run in the daemon. |
| `Playhouse/Atoms/` | PlayhouseAtoms: the atoms' views, written with PlayhouseUI's names only (no `import SwiftUI`), and `AtomRegistry`, which maps each atom's props type to a builder that makes its view from the props the node stores. |
| `Playhouse/Views/PluginCatalogView.swift` | `PluginSurface` (runs one script and renders its tree) and the Plugin Catalog window. |
| `Playhouse/App/Plugins/Renderer/` | `AtomTreeBenchmark` (a development benchmark, see "Typed and dynamic props"). |
| `Playhouse/Views/PluginHost/` | Installed plugins in the app: `PluginRegistry` (the plugins `plugin list` reports), `PluginSlot` (a placement's entry buttons and Add Plugin mode's "Add here" placeholder), `PluginInlineSlot` (a placement's inline plugins, rendered in place), `PluginHost` (the host calls, answered the same way for script and built-in plugins), `PluginSurfaceView` (a mounted script plugin with live props), its popover, modal, sidebar, page and inline presentations, and the mode's banner. |
| `Playhouse/Views/BuiltInPlugins/` | The built-in plugins, written in Swift and compiled into the app (see "Built-in plugins"). |
| `Playhouse/Resources/PluginRuntime/` | `prelude.js` (the React host config), `vendor/` (prebuilt react 18.3.1, react-reconciler 0.29.2, scheduler 0.23.2), `catalog/` (one page per atom, `TaskItem.js`, `AgentsInfo.js`, `TokenStats.js`, `SkillsPage.js`, `RepositoryChips.js`, `Composer.js`, `KanbanColumn.js`, `DoneArchive.js`, and their `sample-*.json` data). |

`catalog/TaskItem.js` is a demo that copies `TaskItemView` atom for atom, so the
catalog can show the two side by side. It is not a composite exposed to
plugins. Change it whenever `TaskItemView` changes;
`test_plugin_task_item_renders_from_atoms_like_native` compares the two.
`catalog/AgentsInfo.js` does the same for `AgentsInfoSection`, including its
collapsing title (the `Disclosure` atom); change it whenever that section
changes. `test_plugin_agents_info_renders_from_atoms_like_native` compares
those two. `catalog/TokenStats.js` does the same for `TokenStatsView`, the
Token Stats modal's content, opened by the task item's token counter
(`TokenCounterButton`, the same Button atom the card uses); the board still
presents it as a sheet, and the raw input sheet it opens stays native. Change
it whenever that modal changes; `test_plugin_token_stats_renders_from_atoms_like_native`
compares those two. `catalog/SkillsPage.js` does the same for the Skills
page's header (with its Skills | Rules | MCP tabs) and skill gallery
(`SkillsPageHeader` and `SkillGalleryView`), opened by the Skills button
(`SkillsButton`, beside the terminal button at the bottom of the task sidebar
and in the composer of chats without one); `SkillsPageView`
owns their state and keeps the delete and link confirmations, the editor and
New Skill panels, and the Rules and MCP lists native. Change it whenever the
header, tabs or gallery changes; `test_plugin_skills_page_renders_from_atoms_like_native`
compares those two. `catalog/RepositoryChips.js` does the same for the task
header's repository chips (`RepositoryChipsView`) and the Add repository
picker their + button opens (`RepositoryPickerView`); the header presents
the picker and each chip's settings as popovers, and the settings stay
native. Change it whenever the chips or the picker change;
`test_plugin_repository_chips_renders_from_atoms_like_native` compares those
two. `catalog/Composer.js` does the same for `ComposerView`, the conversation
composer's box: the editor, the attach button, the Skills button, the Plan
and Goal buttons (an orange highlight while on, never both), Start
Implementing, the provider menu, the model button with its popover, the
schedule button and the send, stop, continue or schedule control. Its toolbar
is two row Stacks, the actions and then the provider, model and send; the native
box sets them side by side while both fit at their natural widths and otherwise
puts the second on a row of its own under the first (a narrow chat sidebar),
which the catalog's copy, shown at a fixed width, never needs. The
conversation (`TaskConversationView.composer`) derives a `ComposerModel` and
`ComposerActions` and passes the notices, images, queued follow-ups and goal
row above the box as the view's native `header`, and the schedule popover's
content as its native `scheduleContent`. Change `ComposerView` and
`Composer.js` together; `test_plugin_composer_renders_from_atoms_like_native`
compares them. `catalog/KanbanColumn.js` does the same for `KanbanColumnSection`, a board
column's header (status dot, title, count, the Backlog's Add button, which an
empty Backlog moves, pulsing, into its empty state), Blocked
notice, empty state and the Waiting Response column's tint (a second Panel
washing the column in its accent); the column's cards stay native `TaskCardView`s passed in
as content. Change it whenever the column's frame changes;
`test_plugin_kanban_column_renders_from_atoms_like_native` compares the two.
`catalog/DoneArchive.js` does the same for `DoneArchivePanel`, the board's
Done archive: its title and close button, the search on a rounded fill (a
`plain` TextField on a decorated Stack), then the empty message or the lazy
list of rows, each a Button opening its task beside the same pull request
Button and Link atoms the task item uses. The board presents it in a
`SidePanel` atom, opened by the header's archive button (`DoneArchiveButton`),
and asks for the next 40 tasks when the list's `onEndReached` fires; it owns
the loaded pages and the search and derives a `DoneArchiveModel`. Change it
whenever the archive changes; `test_plugin_done_archive_renders_from_atoms_like_native`
compares the two.

Plugins present UI the same three ways the board does, each a controlled
atom whose first child is what it is presented over: `Modal` (a sheet over
the window, which Escape dismisses through `onDismiss`; the board's Token
Stats modal), `Page` (slides in over all of its first child; the built-in Scheduled
Tasks page) and `SidePanel` (slides in over one edge; the Done archive). The
owner closes a Page or SidePanel with its own control, as the board's Back
and close buttons do. A Page or SidePanel keeps an empty AppKit view behind what it covers so
accessibility hit tests reach its controls (without one the board's archive
rows took clicks but XCUITest couldn't find them), and a SidePanel orders its
panel ahead of the covered view, so its controls stay reachable even when
that view is one accessibility group (a plugin's base Stack with `group`). On a Modal or SidePanel, `width` (and a Modal's `height`) sizes what it
presents, not the atom: those keys are its own props there, not the common
frame props. A Popover's `width` likewise sizes only its content, never its
anchor. The board presents those three through the same
atom views (`atomModal`, `atomPage` and `atomSidePanel`).

Smaller native views are also built straight from atoms, with no catalog
copy because they have no state or layout a plugin would need to match: the
board's header, worktree notice and Rename Task sheet (`KanbanBoardView.swift`), and in the
conversation the notices above the composer, the queued follow-ups, the
pending comment count, the active goal row, the comment hover card, the
recall, goal, compaction, provider-switch and chat page rows, and the
changes sidebar's merge notice (`TaskConversationView.swift`).

Each composite reads a display model that is already derived
(`TaskItemModel`, `AgentsInfoModel`, `TokenStatsModel`, `SkillsPageModel`,
`RepositoryChipsModel`, `RepositoryPickerModel`, `ComposerModel`, `KanbanColumnModel`,
`DoneArchiveModel`), so the JavaScript copy
formats nothing the native one doesn't.

The app build does not run npm. `scripts/vendor-react.sh` is the one-time
script that copies the prebuilt files into `vendor/`. Rerun it only to change
the pinned versions.

## Writing a plugin

A plugin is one script. The runtime defines these globals:

- `React`: React 18. Hooks work (`useState`, `useEffect`, …).
- `h`: `React.createElement`.
- One string constant per atom (`Stack`, `Text`, …), so a plugin writes `h(Text, …)`.
- `Playhouse.props`: the plugin's input. Catalog pages get the sample data:
  the top-level fields of every `catalog/sample-*.json` (`task` and
  `blockedStatusMessage` for the task item, `agentsInfo` for Agents info,
  `tokenStats` and `tokenCounter` for Token Stats, `skillsPage` for the Skills
  page, `repositoryChips` and `repositoryPicker` for the repository chips, `kanbanColumns` for the Kanban Column page,
  `doneArchive` for the Done Archive page).
  Two samples may not share a field.
- `Playhouse.render(element)`: mounts the root.
- `setTimeout`, `setInterval`, `clearTimeout`, `clearInterval`, `queueMicrotask`, `console`.
- `fetch(url, options)`: an HTTP or HTTPS request (see Network below).

There is no JSX, TypeScript or bundler. Write plain `createElement` calls:

```js
function Counter() {
  var count = React.useState(0);
  return h(Stack, { axis: "h", spacing: 8 },
    h(Button, { style: "borderless", testID: "add", onPress: function () { count[1](count[0] + 1); } },
      h(Text, { size: 11, color: "accent" }, "Add")),
    h(Text, { size: 11, testID: "count" }, "Count: ", String(count[0])));
}
Playhouse.render(h(Counter));
```

Raw strings may only appear inside a `Text` or a `Markdown`, and only `Stack`, `Button`,
`Link`, `Card`, `Disclosure`, `Panel`, `Scroll`, `PressArea`, `Overlay`, `Popover`, `Modal`, `Page` and `SidePanel` take atom children. An unknown atom, an unknown prop, a prop
with the wrong type, or an event the atom doesn't raise is an error. The commit stops at that op, and
the ops before it stay applied. The catalog shows the error under whatever
rendered.

To run a plugin headlessly and see its commits and node tree:

```sh
scripts/playhouse.sh plugin render --file counter.js --event add:onPress
scripts/playhouse.sh plugin render --page TaskItem --event js-toggle-blocked:onPress
```

`--event <testID>:<event>[:<value>]` sends an event to the atom with that
`testID`. Zero-delay timers, such as the ones React uses to run effects, run
after the first render and after each event. `--advance <seconds>` runs the
timers that come due in that time. The command
exits 1 when the plugin reported errors.

## Atoms

These are exactly the atoms the task item, the Agents info section, the
Token Stats modal, the Skills page, the skill and rule previews, the repository chips and picker, the composer and the Done archive are built from, and that present the board's modal, page and side panel. Every atom also takes these common props:

| Common prop | |
| --- | --- |
| `testID` | Accessibility identifier |
| `label`, `value`, `hint` | Accessibility label, value and hint. macOS reports no value for a container (a `PressArea`, or a `Stack` with children), so put such state in its label |
| `help` | Hover tooltip |
| `width`, `height`, `minWidth`, `minHeight` | Frame, in points (a Button's is its label's slot, and its hover capsule spills past it without growing the layout; a Link's surrounds the capsule) |
| `fillWidth` | Stretch to the available width, content leading |
| `fixedSize` | Keep its natural size, so a tight row squeezes its other children rather than wrapping or truncating it (a badge beside a name) |
| `padding` | Uniform padding |
| `paddingY` | Extra vertical padding (inside `padding`) |
| `opacity` | Dims the atom and everything in it (0…1) |
| `paddingX` | Extra horizontal padding (a Button's sits inside its hover capsule) |
| `passThrough` | Let clicks through to what is behind it (the card) |

Colors are `white`, `primary`, `secondary`, `tertiary`, `accent`, `text`, `panel`
and `window` (the workspace's panel and window backgrounds), `red`,
`green`, `orange`, `blue`, `purple`, or `#RRGGBB`. Weights are `regular`,
`medium`, `semibold` and `bold`.

| Atom | Props | Events | Children |
| --- | --- | --- | --- |
| `Stack` | `axis` (`"v"` default, `"h"`), `spacing`, `align` (column: leading/center/trailing; row: top/center/bottom/baseline), `group` (one accessibility container), `combine` (one accessibility element joining its children's labels), `summary` (one accessibility element that reads only as its `label`, hiding its children, for a notice whose combined texts would otherwise hide the label); a surface, in either axis: `fill` (a color, `primary` default) at `fillOpacity` (1 default), drawn when either is set, a border inside its edge drawn when any of `stroke` (a color, `primary` default), `strokeOpacity` (1 default), `strokeWidth` (1 default) or `dash` (`[on, off]`, solid default) is set, in a rectangle rounded by `cornerRadius` (0 default) or, with `capsule`, with fully rounded ends (a circle when square). With no surface prop it draws nothing. With one, its frame and padding size the surface and its children sit inside it at the start of its axis and at `align` across it (a `minHeight` column with `align: "leading"` keeps them at the top leading corner), or, with `align` center or unset (the default), centered both ways, also when `fillWidth` stretches it, so give a Stack you decorate the `align` its children had. A fixed `width` or `height` centers them, as it does any atom's content. An unknown color draws `primary`. `scrollID` names it as a place a `Scroll` around it can scroll to | | atoms |
| `Text` | `text` (or string children), `size`, `weight`, `design` (`monospaced`, `rounded`), `color`, `lineLimit`, `tracking`, `lineSpacing`, `wrap` (grow vertically), `numeric` (animate digits), `truncation` (`head`, `middle`, `tail` default), `monospacedDigits`, `align` (how wrapped lines line up: `leading` default, `center`, `trailing`) | | strings |
| `Markdown` | `text` (or string children) in Markdown, rendered as formatted blocks: headings (`#` to `######`), bullet (`-`, `*`, `+`) and numbered list items, `>` quotes with a leading bar, fenced code (a card with its language and a copy button), pipe tables (with `:` column alignment), rules (`---`, `***`, `___`) and paragraphs, with **bold**, *italic*, `` `code` `` and links inline (a link opens in the default browser when it is `http`, `https` or `mailto`; any other scheme does nothing). Lists don't nest and raw HTML shows as text. `size` (body text, 13 default; headings are semibold and scale from it: +3, +1, then -1), `color` (the prose and cards; the prose is AppKit text, so a surrounding SwiftUI foreground style doesn't reach it), `selectable` (lets the reader select its text), `frontmatter` (what a leading `---` YAML block shows as: `table`, a small table of its entries, whose accessibility identifier is the atom's `testID` plus `-frontmatter`, or `hide`; unset, the block is ordinary Markdown, a rule and paragraphs; any other value is an error). Each run of prose (headings, paragraphs, lists, quotes) is one AppKit text view, so a selection runs across its blocks, and each block in it reads as its own static text; code blocks, tables and rules are separate cards. Sizes and spacing all scale from `size` (`MarkdownStyle`). With a `testID`, its prose runs are identified `<testID>-prose-<line>` and their blocks `<testID>-heading-<line>`, `<testID>-paragraph-<line>`, `<testID>-list-item-<line>`, `<testID>-ordered-list-item-<line>` and `<testID>-quote-<line>`, its code cards `<testID>-code-block-<line>` with their language and copy button `<testID>-code-block-language-<line>` and `<testID>-code-block-copy-<line>`, its rules `<testID>-rule-<line>` and its tables' cells `<testID>-table-<line>-cell-<row>-<column>`. The transcript's replies are this atom | | strings |
| `Icon` | `name` (SF Symbol) or `asset` (template image), `size`, `weight`, `color`, `original` (draw the asset in its own colors, as the board's logo) | | |
| `Image` | `url` (required: `https`, `http` to IP addresses and local hosts as for `fetch`, a `file://` path or a `data:image/…` URL; any other is an error), `size` (a square of that many points; otherwise the common `width` and `height` frame it, or it takes the width it is offered at the picture's aspect ratio), `contentMode` (`fill` default, covering the frame and cropping; `fit`, showing all of it), `cornerRadius`, `circle` (clipped to a circle, as a profile picture), `placeholder` (an SF Symbol shown on a faint fill while it loads and when it fails; a failed load is never an error); the window loads and caches the picture natively (`AtomImageLoader` in `Playhouse/Atoms/`: decoded pictures in memory, responses in a URL cache that honors the server's cache headers, one request shared by concurrent copies, a failure remembered for a minute), so a re-render or another copy of the URL doesn't load it again, and `plugin render` reports it without loading it; decorative unless it has a `label` | | |
| `Label` | `text`, `icon` (SF Symbol), `size`, `weight`, `color`; SwiftUI's label for an `Icon` and a `Text` in a row `Stack` (see Composite atoms below) | | |
| `Button` | `style` (`plain` default, `borderless`, `bordered` push button, `prominent` accent push button, `link` accent text like a hyperlink, `automatic` the platform default), `emphasis` (hover capsule padding), `overhang` (capsule spills past the layout of a Button without a fixed size), `disabled`, `controlSize` (`small` or `large`; inherited otherwise), `shortcut` (`default`: Return presses it; `cancel`: Escape presses it; modifiers and a key joined by `+`, such as `cmd+shift+n` or ``ctrl+` ``: those keys press it, with modifiers `cmd`, `shift`, `option`, `ctrl`, at least one of them `cmd`, `ctrl` or `option` so it never takes a key from typing, and a single character or `return`, `escape`, `tab`, `space`, `delete`; window-wide, so only a window's primary or dismissing action, or one worth its own keys, sets one, and not keys Playhouse uses itself (`AppShortcut.reserved`, such as `cmd+n` or `cmd+q`); the hover hint then ends by naming it, as in `Save (⌘S)`), `destructive` (the destructive role), `selected` (marked selected to accessibility: the current choice in a row of buttons) | `onPress()` | atoms (its label) |
| `Link` | `url`, `emphasis` | | atoms (its label) |
| `Spinner` | `size` (`small` default, `mini`, `regular`) | | |
| `Spacer` | `minLength` | | |
| `PillPicker` | `options` (`[{value, label, help?, testID?}]`), `selected`; the `help` tooltip may contain `{help}`, which is replaced by the shown option's help | `onChange(value)` | |
| `Card` | `menu` (`[{id, title, icon?, destructive?, testID?}]`), `meter` (0…1 usage bar), `meterLabel`, `meterTestID`; `testID`, `label` and `hint` describe its open button | `onPress()`, `onMenu(id)` | atoms |
| `Disclosure` | `title`, `collapsed` (required; the atom shows what it is given), `spacing`, `toggleTestID` (the title button); a collapsed section keeps its children in the tree and hides them | `onToggle()`, called inside an animation; the owner flips `collapsed` | atoms |
| `Panel` | `spacing`, `fill`, `fillOpacity`, `cornerRadius`, `capsule`, `stroke`, `strokeOpacity`, `strokeWidth`, `dash`, `align` (`leading` default or `center`), `combine`. A composite atom, shorthand for a column `Stack` with `group` and a surface whose defaults differ: `fill` `primary` at `fillOpacity` 0.05, `cornerRadius` 8, `align` `leading`, the common `padding` 12, and a border only when it has a `stroke`. Its view is that Stack's (`PanelProps.stack`) | | atoms |
| `Meter` | `fraction` (0…1, required), `color` (`accent` default), `thickness` (3 default), `trackOpacity` (0.12 default), `minFill` (shortest fill in points, 0 default); decorative unless it has a `label` | | |
| `Scroll` | `spacing`, `maxHeight` (shrinks to its content up to it; the common `height` fixes it), `inset` (padding inside the scroll view), `lazy` (builds only the children in view), `scrollTo` and `scrollRequest` (each new `scrollRequest` scrolls, animated, until the descendant `Stack` whose `scrollID` is `scrollTo` sits at the top; the Skills modal's anchors use it); a vertical scroll view around a leading column that fills its width | `onEndReached()`: raised each time the end of its content comes into view, and once when the content fits (the Done archive appends its next page). It isn't raised again while the end stays in view, so an owner whose page doesn't fill the view loads the next one itself | atoms |
| `Divider` | none; a thin separator across its stack | | |
| `ChoiceBar` | `options` (`[{value, label, testID?}]`), `selected`; one button per option, the selected one highlighted and marked selected. Its capabilities are reachable through a decorated row `Stack` of `Button`s (`selected`) each on a decorated `Stack` with a `Text`, as the ChoiceBar page composes it beside the atom (see Composite atoms below) | `onChange(value)`, not raised for the option already selected | |
| `Toggle` | `isOn` (required; the atom shows what it is given), `size` (`mini`, `small`, `regular` default), `disabled`; a switch with no visible label, so give it a `label` | `onToggle()`; the owner flips `isOn` | |
| `TextField` | `text` (required), `placeholder`, `autoFocus` (takes the keyboard focus when it appears), `style` (`rounded` default, `plain`: no border, for a field on a decorated `Stack`); a one-line field that edits its own copy and takes `text` whenever the owner changes it | `onChange(text)` on every edit; `onSubmit()` for Return and `onArrow(direction)` (`up`, `down`) for the arrows, which keep their usual behavior when there is no handler | |
| `Segmented` | `options` (`[{value, label}]`), `selected`, `disabled`; a segmented control, as wide as its segments unless it has a `width` | `onChange(value)`, not raised for the segment already selected | |
| `Menu` | `icon` (SF Symbol), `text` (beside or instead of the symbol), `size`, `weight` (the symbol's), `textSize`, `textWeight`, `badgeIcon` (a second symbol before the text), `color` (`secondary` default), `indicator` (the pull-down chevron, hidden by default), `disabled`, `items` (groups `[[{id, title, destructive?, help?, testID?, checked?, icon?, disabled?}]]`, a separator between non-empty groups; a checked item shows a checkmark and a disabled one is dimmed and can't be chosen); a borderless pull-down whose common `width` and `height` frame its label | `onMenu(id)` | |
| `PressArea` | `spacing`, `pointer` (the pointing hand); a leading column that takes every click on its children, one accessibility container | `onPress()` for a click, `onLongPress()` for a press and hold | atoms |
| `Overlay` | `align` (`center` default, `top`, `bottom`, `leading`, `trailing`, `topLeading`, `topTrailing`, `bottomLeading`, `bottomTrailing`), `offsetX`, `offsetY`, `revealOnHover` (the overlay shows only while the pointer is over the atom); its first child laid out as usual and the rest drawn over it at `align`, moved by the offsets without changing its size; one accessibility container | | atoms |
| `Editor` | `text` (required), `placeholder`, `placeholderTestID`, `enabled`, `autofocus`, `focused`, `focusRequest` (each new value moves the keyboard in once), `inputTestID` and `inputLabel` (the text view's own accessibility identifier and label); a multiline message editor that grows with its text; the common `hint` is its accessibility help; a pasted image, and Escape when the owner handles it, reach native owners only | `onChange(text)`, `onSubmit()` (Return), `onSteerSubmit()` (Command-Return), `onFocusChange(isFocused)` | |
| `Popover` | `isPresented` (required), `arrowEdge` (`top` default, `bottom`, `leading`, `trailing`), `width`, `inset` (padding around the content, 14 default), `spacing` (between its children, 10 default), `hover` (also opens as a hint while the pointer rests on the anchor for `delay` seconds, and closes when it leaves; the Skills modal's rows show their details this way); shows the children after its first in a popover (a leading column) anchored to its first; its `testID` only names it to events | `onDismiss()` (a click outside or Escape; the owner sets `isPresented` false) | atoms: the anchor, then the content |
| `StepSlider` | `options` (`[{value, label}]`), `selected`; a discrete slider as wide as its container, driven by click, drag or arrow keys; its common `label` and `testID` name it | `onChange(value)` | |
| `Modal` | `isPresented` (required), `width`, `height` (fix the sheet's size, content at the top; it fits its content otherwise), `title`, `subtitle`, `icon` (SF Symbol), `inset` (padding around the header and content, 24 default), `spacing` (between the header and each child, 16 default), `dismissible` (false: no close button and Escape does nothing, so only the owner's own control closes it; true default); a sheet over the window presented from its first child, which stays laid out as usual, showing the rest in a leading column. With a `title` the sheet starts with the app's standard modal header: the accent `icon`, the 19-point semibold rounded title (`<testID>-title`), the secondary subtitle, and, unless `dismissible` is false, a close button (`<testID>-close`, or `modal-title` and `modal-close` without a `testID`); its `testID` and accessibility props name the sheet's content | `onDismiss()` (Escape or the header's close button; the owner sets `isPresented` false) | atoms: the presenter, then the content |
| `Page` | `isPresented` (required); slides in from the trailing edge over all of its first child, which stays laid out as usual (its accessibility tree untouched, with no container added around it) and sizes the atom, showing the rest in a leading column on the window background, like a page plugin over the board; its `testID` and accessibility props name the page; the owner closes it with its own control | | atoms: the covered view, then the page |
| `SidePanel` | `isPresented` (required), `edge` (`trailing` default, `leading`), `width` (340 default); a full-height panel sliding in over that edge of its first child, which stays laid out as usual (its accessibility tree untouched, with no container added around it) and sizes the atom, showing the rest in a column with no spacing on the window background, with a hairline along its inner edge and a shadow, like the Done archive; its `testID` and accessibility props name the panel; the owner closes it with its own control | | atoms: the covered view, then the panel |

### Defaults

Atoms look right with no styling props: a `Modal` pads its content 24
points and, given a `title`, draws the app's standard header (the same view,
`AtomModalHeader`, an installed plugin's surface starts with); a `Popover`
pads its content 14 points; a `Panel` is padded 12 points; a `Card` is padded
14 points; and presented children are spaced apart. Every default is a prop a plugin can override
(`inset`, `spacing`, `padding`). Native composites that size and pad their
own content opt out explicitly (`padding: 0` on a Panel, `inset: 0` on a
Modal or Popover), and their catalog copies pass the same values, so the
defaults never change the app's own views. `Stack` stays the bare primitive
with no defaults. `Page` and `SidePanel` deliberately have no inset: they
cover a whole view or edge and their owners lay out their own headers and
edges (an installed plugin's surface pads them itself). Paddings add up, as
on a Stack: a Panel given only `paddingX: 4` is padded 12 + 4 across and 12
along its height; give it `padding: 0` to use `paddingX` alone.

### Composite atoms

Most atoms do one thing. `Panel` is a composite atom: shorthand for a column
`Stack` with `group`, `padding` 12 and a surface (`primary` at 0.05, radius 8,
a border only when it has a `stroke`), drawn by that Stack's own view
(`PanelProps.stack`).

These are composites too, and still to settle:

| Atom | Made of | What is left |
| --- | --- | --- |
| `ChoiceBar` | A decorated row `Stack` of `Button`s marked `selected`, each label a decorated `Stack` around a `Text` | Every capability is reachable that way; its view is still its own, whose circular corners a Stack's continuous ones would change |
| `Label` | An `Icon` and a `Text` in a row `Stack` | Every capability is reachable that way; its view is SwiftUI's `Label`, which spaces and aligns them the platform's way |
| `Card` | A press surface, a shadowed rounded fill, a right-click menu and a usage bar | Its shadow, right-click menu and heatmap usage bar are reachable through no smaller atom |
| `Disclosure` | A `Button` (chevron `Icon` and `Text`) over a column `Stack` | Its animated collapse is reachable through no smaller atom |
| `Scroll` | A scroll view around a column `Stack` | `lazy`: a `Stack` is never lazy |
| `Menu` | A pull-down whose label is `Icon`s and a `Text` | Its label is symbol and text props, not atom children |
| `PressArea`, `Popover`, `Modal` | A press or presentation around a column `Stack`; a Popover's or Modal's `inset` and `spacing` are a padded nested `Stack`'s `padding` and `spacing`, and a titled Modal's header is a row `Stack` of the accent `Icon`, a column `Stack` of the title and subtitle `Text`s, a `Spacer` and a `Button` around an `xmark` `Icon` whose `onPress` closes it (`AtomModalHeader`, built from those atoms' views) | The column, padding and header are reachable through those atoms (give the Modal `inset: 0` and no `title`), but they draw their own |
| `Page`, `SidePanel` | A presentation around a column `Stack` on a `window`-filled surface | The column and the fill are reachable through a `Stack`; the shadow over what they cover and the SidePanel's one-edge hairline are reachable through no smaller atom |

To add an atom, add its case, its props struct (an `AtomProps` naming its
`atomType`) and its `propsType` to `Core/Plugins/Runtime/AtomProps.swift`, its
view to `Atoms/AtomViews.swift`, its registry entry to
`Atoms/AtomRegistry.swift`, and a catalog page `catalog/<Atom>.js`. Add one
only when a native composite needs it, and only when existing smaller atoms
(or a primitive prop on them) can't compose it: an atom does one thing, such
as laying out, drawing a surface or taking input. A composite atom, a
shorthand for a common composition of smaller atoms, is fine when the
composition is very common, as long as those smaller atoms stay exposed and
can do everything it does; build its view from their views and say in its
row of the table above and on its catalog page which atoms it stands for. Its view passes its type to
`atomCommon` (or applies `atomHighlight` itself) and its case says whether it
`isContainer`, so Debug ▸ Highlight Native Atoms outlines it: containers in
orange, leaves in green, with its type name on hover. The overlay is
debug-only; it shows where atoms are used, so plain SwiftUI left inside a
composite shows as a gap.

## Installed plugins

Users add plugins through Add Plugin mode. It is turned on from Plugins ▸ Add
Plugin Mode or `playhouse plugin mode --on`, and turned off with the banner's
Close button or `--off`. While it is on, each placement shows an "Add here"
placeholder, and the task sidebar shows expanded. Pressing a placeholder runs
`plugin author`, which creates a task whose agent builds the plugin with
Playhouse's bundled `playhouse-plugin` skill
(`Resources/PluginRuntime/skills/playhouse-plugin/SKILL.md`). Keep that skill
in step with this README.

A plugin is a folder `<data directory>/plugins/<id>/` holding `plugin.json`
and its script:

```json
{ "id": "word-count", "name": "Word Count", "icon": "textformat.123",
  "placement": "composerActions", "presentation": "popover", "entry": "index.js",
  "width": 320, "height": 200 }
```

Optional keys: `commands` (see "Slash commands"), and `events` and `mcpTools`
(see "Background halves").

`plugin refresh` validates every folder and makes the window reload. It checks
the manifest and renders each plugin once with sample context; any error marks
the plugin invalid. The Plugins menu lists every plugin with its placement;
an invalid one also shows its first error and gets no button. A plugin is
deleted with its Delete item in the Plugins menu, or with `plugin delete --id`.

Each plugin, built-in or installed, has Enable and Disable in its Plugins menu
submenu, as `plugin enable --id` and `plugin disable --id` do. The disabled ids
persist in settings (`WorkspaceSettings.disabledPluginIDsKey`, owned by
`WorkspaceSettingsManager.setPluginEnabled`); `plugin list` reports each plugin's
`enabled`. A disabled plugin gets no button or section and never runs (an open
surface closes when its plugin is disabled or deleted):
`plugin render` refuses it with `unavailable`. Enabling it again restores it,
and deleting a plugin forgets its disabled state.

| Placement | Where | Entry | Extra context in `Playhouse.props` |
| --- | --- | --- | --- |
| `mainSidebar` | The board's sidebar, after the built-in Scheduled Tasks entry | Labeled | `schedules` (`{tasks, needsLoginItemsApproval}`): `tasks` is what `schedule.list` returns (every scheduled task, soonest first, each with its `schedule` record), kept live from the window's task-store query, and `needsLoginItemsApproval` says macOS waits for the user to allow the scheduler in Login Items (always false in `plugin render`, which can't ask macOS) |
| `mainSidebarBottom` | The bottom of the board's sidebar, where sections stack in plugin order: the first sits on top, and expanding one grows it upward, pushing those above it up | None: always `section` | `agents` (`{usage, runningTasks}`): `usage` is what `usage.get` returns, kept live by the window's usage feed (`AgentUsageModel`, which runs only while a section is shown) or null before the first read, and `runningTasks` counts the In Progress tasks per provider, always listing `claude` and `codex` |
| `conversationSidebar` | The task sidebar: entry buttons first, then inline sections such as Changes | Labeled, or none when `inline` | `task`, `repositories`, `contextFolders`, `workspace` (`{revision, openDiff: {repository, path, group} or null}`) and `sidebar` (`{collapsed}`) |
| `conversationToolbar` | The task sidebar's bottom row, beside Terminal | Icon | `task`, `repositories`, `contextFolders` |
| `composerActions` | The composer's actions row, beside Skills (also in the standalone chat) | Icon | The above and `composer` (`{draft, selection: {location, length, text}}`) |
| `taskItem` | The bottom row of each task's card on the board, beside the built-in pull request controls once the task has started | Icon, or none when `inline` | `task`, `repositories`, `pastPullRequests`, `contextFolders` for the card's task |

`task` is `{id, title, status, provider, isStandaloneChat, scheduleSourceTaskID}`;
each of `repositories` is `{repositoryPath, worktreePath, branch, isPending,
awaitsPullRequest, pullRequest: {number, url, merged} or null}`, and
`pastPullRequests` lists `{repositoryPath, number, url, merged}` from worktrees
the task has removed.

Every plugin also gets `plugin` (`{id, name, placement, presentation}`),
`app` (`{appearance}`) and `state`, the plugin's own saved values.
`Playhouse.setState(key, value)` (the bridge's `plugin.state.set`, the CLI's
`plugin state --id <id> --key <key> --value <json>`) stores one, and `null`
removes it. They persist in settings (`WorkspaceSettings.pluginStatesKey`,
owned by `WorkspaceSettingsManager.setPluginState`), `plugin list` reports each
plugin's `state`, a change bumps the plugins revision so every mounted copy gets
the new props, and deleting a plugin forgets them. `presentation` is one of:

- `popover`: anchored to the entry button.
- `modal`: a sheet.
- `sidebar`: slides in from the trailing edge.
- `page`: covers the board or the conversation.
- `section`: only at, and always at, `mainSidebarBottom`. The host
  (`PluginSectionSlot` in `Host/PluginSlot.swift`) draws a collapsible header
  with the plugin's name (`plugin-section-<id>-toggle`) above the plugin, which
  stays mounted while collapsed. Whether it is collapsed is its plugin state
  `collapsed` (open by default). A section that renders nothing hides, header
  included: a built-in reports that through `PluginSectionContentKey`.
- `inline`: rendered in place as a section of the conversation sidebar, or in
  the task card's bottom row, with no entry button, header or padding of its
  own beyond a 10-point inset. It stays mounted while its task is open (or its
  card shown), so it can keep the task's state live. While the sidebar is
  hidden to its narrow rail, `sidebar.collapsed` is true and the plugin should
  show at most a compact count there. On a task card, keep it to an icon or a
  short label.
- `headless`: only at `composerActions`. The plugin has no button and no
  surface, only the `/` commands its manifest declares (see "Slash commands"),
  a background half (its `events`, see "Background halves"), or both.

Each presentation but `inline` and `section` starts with the app's standard modal header (the plugin's
icon and name, `plugin-surface-title`, and its close button,
`plugin-surface-close`) and pads the header and the script's atoms (24 points
in a modal or page, 20 in a sidebar, 16 in a popover), spacing its root atoms
12 points apart, so a plugin shows no title and adds no outer padding or
fixed width of its own.

The core builds the props (`PluginContext` in `Core/Plugins/Runtime/PluginLibrary.swift`).
They stay live: `Playhouse.useProps()` re-renders when they change, as when the
user edits the draft.

Installed plugins also get host calls. Each returns a Promise:

| Call | What it does |
| --- | --- |
| `Playhouse.bridge(command, arguments)` | Full app access: any bridge command the CLI sends (`"task.list"`, `"task.rename"`, `"conversation.send"`, …) except `plugin.render`, which would recurse. It resolves with the command's result, or rejects with an Error carrying `code` and `message`. In the app it goes through `DaemonClient`; in `plugin render`, through the daemon's own `PlayhouseBridgeRuntime` |
| `Playhouse.setState(key, value)` | Saves one of the plugin's values, which come back as `props.state`; `plugin.state.set` with the plugin's id |
| `Playhouse.ui.close()` | Closes the surface |
| `Playhouse.ui.openTask(taskID)` | Opens a task; a page plugin stays open behind it, so closing the task returns to the page |
| `Playhouse.ui.composer.setDraft(text)`, `.insertText(text)`, `.replaceSelection(text)`, `.focus()` | Edit the composer at the conversation placements; elsewhere they reject |
| `Playhouse.ui.composer.setMode(mode)` | Turns on the composer's `"plan"` mode or opens its `"goal"` entry (a read-only conversation rejects with `unavailable`); any other mode is `invalid_argument` |
| `Playhouse.ui.openSkills(focus)` | Opens the Skills page in the conversation: `{skillID}` on that skill's editor, `{mcpServerID}` on that MCP server's editor, or `{signIn: {name, provider}}` filtered to the server with that agent's sign-in started; `{}` opens it unfocused |
| `Playhouse.ui.editPlugin(pluginID)` | Opens the plugin's editor conversation, as its Edit item in the Plugins menu does |
| `Playhouse.ui.openDiff(entry)` | Opens the window's diff view for an entry of `task.changes.list` (`{repository, path, group, …}`) at the conversation placements |
| `Playhouse.ui.refreshWorkspace()` | Tells the window the task's folders changed: it bumps `workspace.revision` for every sidebar plugin and refreshes an open diff. The window also bumps it whenever its file watcher sees a change, while an inline sidebar plugin is shown |
| `Playhouse.ui.moveTask(taskID, status)` | Moves a task to a board column the way dragging its card does, including the window's own checks and alerts |
| `Playhouse.ui.alert(title, message)` | Shows an alert over the window, for a failure the user should see |
| `Playhouse.ui.confirm({title, message, confirm, destructive})` | Asks the user with the board's dialog (`PluginConfirmationModifier`), shown inside the popover for a popover plugin so it stays open (in the composer, an alert over the window), and resolves true when they confirm, false when they cancel; `plugin render` resolves null without asking, and `slash-commands run` resolves its `--confirm` |
| `Playhouse.ui.openURL(url)` | Opens an `http` or `https` link in the browser (a test build opens nothing) |
| `Playhouse.ui.newTask({schedule})` | Opens a new task on the board; with `schedule` `"recurring"` or `"once"` its schedule picker is already up |
| `Playhouse.ui.openLoginItems()` | Opens Login Items in System Settings, where the user allows scheduled runs |

`plugin render` records the `ui` calls in its `hostCalls` output. Both hosts refuse calls by the same rules, `PluginHostRules` in `Core/Plugins/Runtime/PluginLibrary.swift`: `plugin.render` is `invalid_argument`, a composer call from the board's sidebar or a task card is `unavailable`, an `openDiff` or `refreshWorkspace` call from the board's sidebar is `unavailable`, a `moveTask` or `alert` call from anywhere but a task card is `unavailable`, a `confirm` call from anywhere but the board (its sidebar, the sidebar's bottom or a task card) or the composer is `unavailable`, a `newTask` or `openLoginItems` call from anywhere but the board is `unavailable`, an `openSkills` or `editPlugin` call from the board is `unavailable`, an `editPlugin` call without a `pluginID` or a `composer.setMode` call whose mode is neither `"plan"` nor `"goal"` is `invalid_argument`, a `newTask` call whose `schedule` is neither null, `"once"` nor `"recurring"` is `invalid_argument`, and an `openURL` call whose `url` is not an `http` or `https` URL with a host is `invalid_argument`.

### Slash commands

Any plugin can expose `/` commands, which the composer's command menu lists
when the user types `/` where a word starts. A `headless` plugin (placement
`composerActions`) is one that exposes only commands. The manifest declares
them, so the menu lists them without running the plugin:

```json
{ "id": "notes", "name": "Notes", "icon": "note.text",
  "placement": "composerActions", "presentation": "headless",
  "commands": [
    { "name": "greet", "detail": "Greets the task", "icon": "hand.wave" },
    { "name": "notes", "detail": "Lists the task's notes", "list": true }
  ] }
```

A `name` is lowercase words joined by hyphens, can't be declared twice or take
a built-in command's name, and needs a `detail` (the row's second line); `icon`
defaults to the plugin's. A headless plugin with neither commands nor events is invalid, as is
a declared command the script never registers. The script registers each
command's handlers with `Playhouse.commands.register(name, {available, list,
run, choose, press})`; each gets one request object and returns a value or a
promise of one:

| Handler | Request | Returns |
| --- | --- | --- |
| `available` | `{}` | Optional. `true`, `false` or `{enabled, reason}`: a disabled command is listed greyed out with `reason` in place of its detail, and can't run |
| `run` | `{filter}` | For a command without `list`: run as soon as it is chosen. `{text}` replaces the typed command in the draft; nothing removes it |
| `list` | `{filter, complete}` | For a command with `list`: `{title, items, pending, empty, noMatch}`, the menu shown once the command is typed in full. Each item is `{id, title, detail, icon, help, keywords, buttons, data}`; the host filters items by what is typed after the command and a space (title, detail and keywords). A list with `pending` (such as `"Checking sign-in…"`) shows it beside the title while the host asks again with `complete` true for the slower details |
| `choose` | `{item, filter}` | An item chosen: `{text}` as for `run` |
| `press` | `{item, button}` | One of the item's `buttons` (`{id, label, help, icon, text, style: "icon" or "bordered", disabled, destructive}`) pressed: `{text}` as for `run` |

Each handler runs in a fresh runtime of the script (`JavaScriptCommandHandler`
in `Core/Plugins/Runtime/PluginCommands.swift`) with the composer placement's props, and its
`Playhouse.bridge`, `Playhouse.ui` and `fetch` calls are answered and refused
as a mounted composer plugin's are. A rejected promise shows its message under
the composer and removes the typed command.

`SlashCommandManager` (`Core/Catalogs/SlashCommandCatalog.swift`) runs them the same way
for the window, whose `PluginHost` answers the calls, and for the bridge
daemon's `slash.list` and `slash.run` (the CLI's `slash-commands list --task
<id> [--query <text>] [--complete]` and `slash-commands run --task <id>
--command <name> [--item <id> [--button <id>]] [--confirm]`). The daemon's
`PluginHeadlessHost` sends bridge calls to its own runtime and records `ui`
calls without acting on them; `slash-commands run` reports the command's
calls (listing its items, then running it) in `hostCalls`. The manager also
refuses, for both, a disabled command (`unavailable`), a command with a list run
without an item or one without a list given an item (`invalid_argument`), an
unknown item or button (`not_found`) and a disabled button (`unavailable`). A
plugin whose `available` handler fails has its commands listed disabled, with
the error as the reason. Commands come from the active plugins, the built-in ones first and
then the installed ones by id; a disabled or invalid plugin offers none.

### Events and throttling

`Playhouse.on(name, listener)` listens for app events (`PluginEvent` in
`Core/Plugins/Runtime/PluginEvents.swift`) and returns a function that stops listening:

| Event | Payload | When |
| --- | --- | --- |
| `task.statusChanged` | `{taskID, from, to}` (column names, such as `"In Progress"` and `"Review"`) | The plugin's task moved between board columns |
| `app.focus` | `{}` | The app became the active application |
| `plugin.stateChanged` | `{pluginID, key, value}` | One of the plugin's saved values changed; targeted at that plugin |
| `app.launched` | `{}` | Once per app launch, as the plugin first mounts. The window claims each plugin's launch once (`PluginLaunch.claim`); a launch no listener heard is kept, and the first listener the plugin adds later hears it |
| `agent.finished` | `{runID, status, result, error, context}` | Only in a background half: an agent the plugin started with `agent.run` ended (see "Background halves"); targeted at that plugin |

An event may be targeted at one plugin (`PluginEvent.pluginID`): it wakes only
that plugin's service and its mounted runtimes, so a state change or an agent's
result never reaches another plugin.

A mounted plugin hears them from its surface (`PluginSurfaceView` compares
its old and new props). A task card's plugin keeps running when its card is
rebuilt in another column (`PluginRuntimeKeepAlive`), so it hears its task's
moves; a change made while no card shows the task is not replayed, so work
that must happen on every move belongs in a service (below). `plugin render --event @<name>[:<json payload>]`
emits one headlessly and reports how many listeners heard it in `emitted`;
`--event +<seconds>` advances the clock between events.

`Playhouse.throttle(fn, seconds)` returns a function that runs `fn` at once
on its first call; the calls made while it runs (until a promise it returns
settles) or within `seconds` after it started collapse into one trailing call
with the latest arguments. Use it so that frequent events (every focus, every
move) don't flood a rate-limited service such as GitHub. Swift code has the
same helper, `PluginThrottle`.

A built-in plugin's background half is a `PluginService`
(`Services/PluginServiceHost.swift`): it hears the same events in the bridge
daemon, whether or not a window shows the plugin, and acts only through bridge
commands. The daemon raises `task.statusChanged` and `plugin.stateChanged` for
the changes its commands save; a window forwards the others (`app.focus`)
over `plugin.event` (`app.launched` too, so a service can act once per launch), which the CLI sends as
`plugin event <name> [--payload <json>]` (an unknown name is
`invalid_argument`; a `plugin.stateChanged` or `agent.finished` payload's
`pluginID` targets it). A built-in service hears every event not targeted at
another plugin.

### Background halves

A script plugin can have a background half too: handlers in its script that
run in the bridge daemon for app events, with or without a window open. Its
manifest lists the events they hear, and any presentation may declare them, so
a popover plugin gets a background half next to its UI; a `headless` plugin
may have only these:

```json
{ "id": "slack-dms", "name": "Slack DMs", "icon": "bubble.left.and.bubble.right",
  "placement": "mainSidebar", "presentation": "popover",
  "events": ["app.focus", "agent.finished"],
  "mcpTools": ["mcp__claude_ai_Slack__slack_search_public_and_private"] }
```

Each name must be one of `PluginEvent.names` and listed once. The same
`index.js` holds both halves. `Playhouse.service.on(name, handler)` registers a
background handler; it does nothing in a mounted UI, and `Playhouse.render`
does nothing in the background, so an event is never handled twice while the
popover is open (`Playhouse.service.active` says which runtime the script is
in). A handler gets `{name, payload}` with the payload's fields beside them
(`e.status`, `e.context`) and may return a promise:

```js
Playhouse.service.on("app.focus", async function () {
  var res = await Playhouse.mcp.call("mcp__claude_ai_Slack__slack_search_public_and_private", { query: "to:me" });
  await Playhouse.setState("people", parse(res));
});
```

The daemon's `PluginServiceHost` wakes only the services an event is for: a
targeted event only its plugin's, an untargeted one only the enabled, valid
plugins whose manifest lists it. It finds the script plugins afresh for each
event (`plugin.services`, the CLI's internal `plugin services`), so a plugin
saved, deleted, enabled or disabled is heard from its next event on.
`JavaScriptPluginService` (`Services/JavaScriptPluginService.swift`) delivers
one event: it runs `plugin.service` with the plugin's props (the plugin and its
state, as `JavaScriptCommandHandler` gives a command), which loads the script
into a fresh service runtime (`PluginServiceCommand` in
`Core/Plugins/Runtime/PluginServiceCommand.swift`), calls the event's handlers, waits for their
promises to settle (60 seconds, then an error in diagnostics,
`plugin.service.failed`) and throws the runtime away. Nothing but the plugin's
state carries over to the next event. `app.focus` is throttled per plugin
(`PluginThrottle`, 20 seconds), so coming back to the app over and over runs it
once; events that carry their own payload (a move, a state change, an agent's
result) are each delivered, since a throttle keeps only the latest call and
would drop the others. A service never hears its own state writes (its
handlers' bridge requests carry the internal `__pluginService` argument), so a
handler that saves state can't wake itself in a loop; a write made elsewhere,
by its popover or the CLI, does reach it. Services that wake each other (one
writes another plugin's state, which writes back) can't loop either: every
request a service makes carries the depth of the event it heard
(`__pluginEventDepth`), and an event raised past
`PluginServiceHost.maximumEventDepth` (8) is dropped and recorded as
`plugin.event.dropped` with reason `event-chain-too-deep`. Script handlers are background work
only: a move that waits for its services' reactions (`PluginServiceHost.settle`,
such as the pull request mode opening a pull request) never waits for them.
A plugin can't call `plugin.service` or `plugin.services` itself
(`invalid_argument`): only the daemon delivers events. In a handler, `Playhouse.bridge` and `fetch` are
answered as `PluginHeadlessHost` answers a command's, and every `ui` call is
`unavailable`. The two halves talk through the plugin's state: the service's
`Playhouse.setState` raises `plugin.stateChanged` and an open popover
re-renders from its props.

`plugin service (--file <index.js> | --plugin <id>) --event <name>[:<json>]...
[--props <json>] [--mock <command>[:<tool>]=<json>...]` runs the handlers
headlessly, as `plugin render --event` does for a UI, and reports each event's
handler count, the `hostCalls`, the `stateWritten` and the `errors` (exit 1 if
any). A file's `Playhouse.setState` writes a scratch `state`, which the report
returns. Bridge calls are answered by the daemon; `mcp.call`, `agent.run` and
`agent.cancel` are `unavailable` unless a `--mock` answers them, by command or
for one MCP tool (`mcp.call:<tool>`), and `{"error": {code, message}}` mocks a
failure. `agent.finished` is injected with a fake result as
`--event 'agent.finished:{"runID":…,"status":"done","result":…,"context":…}'`.
`plugin render` takes the same `--mock` and refuses the same calls without one.

#### Calling MCP tools

`Playhouse.mcp.call(tool, arguments, {provider, timeout})` (the bridge's
`mcp.call {tool, arguments, provider?, timeout?, pluginID?}`, the CLI's
`mcp call --tool <mcp__server__tool> [--arguments <json>]`) calls an MCP tool
directly and resolves with its `{content, structuredContent, isError}`, with no
model turn and no tokens. `ClaudeCodeClient.callMcpTool` sends Claude Code's
`mcp_call` control request (`result_not_for_model`) through the same session
runner as `mcp_status`. That request isn't part of Claude Code's documented
interface, so it is used only when Claude Code's `initialize` lists
`mcp_call_result_not_for_model_v1` in its `capabilities`. One session stays warm
60 seconds after its last call, so a burst of calls starts Claude Code once.
Errors: a tool name that isn't `mcp__<server>__<tool>` is `invalid_argument`,
Claude Code missing or without the capability is `unavailable`, an error
Claude Code returns (a server that isn't connected, an unknown tool) is
`tool_failed` with its message, and no answer within `timeout` (60 seconds) is
`timeout`. With `provider` `codex`, `CodexAppServerClient.callMcpTool` sends
the shared app-server's `mcpServer/tool/call` (`{threadId, server, tool,
arguments}`, the name split at its `__`s) on an ephemeral, read-only thread
(`thread/start` with `ephemeral`, never listed among the user's threads), kept
warm the same 60 seconds; a Codex without that method is `unavailable`. Claude
Code is the default, since a plugin's MCP servers (claude.ai connectors among
them) are configured per provider. A manifest's `mcpTools`, when present, lists
the only tools the plugin calls; any other is `permission_denied`. It catches
mistakes and is not a security boundary.

#### Running an agent

`Playhouse.agent.run({prompt, model, allowedTools, jsonSchema, context, cwd})`
(the bridge's `agent.run`, with `pluginID` filled from `Playhouse.props.plugin`
as `setState` does; the CLI's `agent run --plugin <id> --prompt <text> …`)
starts a background agent and resolves `{runID}` at once. `PluginAgentRuns`
(`Services/PluginAgentRuns.swift`) runs it in the daemon, in `cwd` or a folder
of its own beside the store, holding `BridgeBackgroundWork` so closing the
popover or the window doesn't stop it, for at most 15 minutes:

- On Claude Code (the default): one non-persisted turn, `claude -p
  --output-format json --no-session-persistence` with `--model`,
  `--allowedTools` and `--json-schema`; `result` is its `structured_output`.
- With `provider: "codex"`: one turn on an ephemeral thread of the shared
  app-server (`CodexAppServerClient.startPlainTurn`), read-only and with no
  approvals, with the model and the schema as `turn/start`'s `outputSchema`;
  its final message is parsed as the structured output. Its notifications go
  only to the run (`CodexPlainTurn`), never to a conversation, and the server
  counts it as work so it isn't stopped as idle. Codex has no per-turn tool
  list, so `allowedTools` applies to Claude Code only. Cancelling or timing out
  interrupts the turn (`turn/interrupt`).
- With `provider: "opencode"`: one turn in a read-only session of its own on
  OpenCode's shared `opencode serve` (`PluginAgentRuns.startOpenCode`), removed
  when it ends; `result` is the final answer's text. OpenCode's server has no
  structured output, so with a `jsonSchema` the prompt carries the schema and
  asks for an answer of only matching JSON (`PluginJSONSchema`); the JSON in the
  answer, taken out of a Markdown code block if it has one, is checked against
  the schema and is the `result`. An answer that doesn't match is asked for once
  more in the same session, naming what was wrong, and a second mismatch fails
  the run. Cancelling or timing out interrupts the session.

Model names are the provider's own (`opus`, `gpt-5.5`). When it ends, the
plugin's background half hears `agent.finished`, targeted at the plugin:

```
{runID, status: "done" | "failed" | "cancelled", result, error, context}
```

`result` is the schema's `structured_output` when `jsonSchema` was given, else
the final text. `context` is any small JSON value (16 KB at most) handed back
unchanged, which is how a fresh service runtime tells its runs apart (`{kind:
"slack-task", userId}`); `runID` lets it drop a stale result. The plugin must
list `agent.finished` in `events` (`invalid_argument` otherwise). Unfinished
runs are saved beside the store in `plugin-agent-runs.json`
(`PluginAgentRunStore`: `{runID, pluginID, context, startedAt, model, process}`). A daemon that starts
after one was cut off reports each of its runs `failed` with the error
`"interrupted"`, and stops its Claude Code if it is still running, or
interrupts its Codex turn on the shared app-server, which can outlive a daemon. A daemon
serves many stores and learns of each from a request, so it checks a store on
its first event (`plugin.services`, which every event asks) or `agent runs`,
not at launch; with the app open, the window's `app.launched` and `app.focus`
reach it at once. `Playhouse.agent.cancel(runID)` (`agent.cancel
{pluginID, runID}`, the CLI's `agent cancel`) stops a run, which ends
`cancelled`. Deleting a plugin stops its runs with no event. `agent runs
[--plugin <id>]` lists the unfinished runs with their provider and whether this
daemon is running them, so usage spent in the background is visible.

### Built-in plugins

A built-in plugin is an existing feature implemented as a plugin in Swift and
compiled into the app. It shares the whole plugin infrastructure, so a user
could write the same plugin in JavaScript: it has a manifest
(`BuiltInPlugins` in `Core/Plugins/Runtime/PluginLibrary.swift`) that `plugin list` reports
with `builtIn` true, it sits at a placement with a presentation, it reads the
same `Playhouse.props`, it composes only atoms, and it acts only through
`PluginHost`, which answers its `bridge` and `ui` calls exactly as it answers a
script's. `BuiltInPluginView` maps a built-in id to its view, which
`PluginInlineSlot`, `PluginSectionSlot` and `PluginPresentationModifier` mount
in place of `PluginSurfaceView`. A presented built-in (a page) draws its own
chrome instead of the installed plugins' standard header, and closes with
`ui.close`.
A built-in can be enabled or disabled from the Plugins menu's Built-in Plugins
section or the CLI, but not edited, rendered or deleted (`invalid_argument`),
and an installed plugin's folder can't take a built-in's id.

| Built-in | Placement | Presentation | What it is |
| --- | --- | --- | --- |
| `pull-request-mode` (`BuiltIn/PullRequestModePlugin.swift`, `Services/PullRequestModeService.swift`) | `taskItem` | `inline` | The task card's mode pill: Manual, PR, Green or Merge. The mode is this plugin's state, keyed by task id (none means Manual, or the recurring schedule's mode for a scheduled run; tasks saved while PR was the default had PR saved as theirs once), not a property of the task. Its service decides what each mode does: when the task reaches Review, or a mode is chosen for a task already in Review, it opens the pull request (`task.pr.create` with `ifNeeded`) unless the mode is Manual; in Green and Merge it then runs `task.pr.autopilot` passes (with `merge` in Merge mode) until the PR is green or merged, polling while checks run, again when the mode changes and, throttled, when the app comes to the front; a pass that finds no linked pull request stops instead of polling |
| `pull-requests` (`BuiltIn/PullRequestsPlugin.swift`) | `taskItem` | `inline` | The task card's pull request controls: the create button, the links coloured by health, the merged check (which moves the task to Done with `ui.moveTask`, passing `pullRequestsMerged` so the move trusts the merge its probe just saw instead of asking GitHub again; the window honors that only from a built-in plugin, since the move records the pull requests merged). Conflicts show only as a red link; the Green and Merge modes fix them. It probes `task.pr.status` with `shared` (a short cache with in-flight dedupe, so cards and windows share one GitHub read) on focus and when its task moves, through `PluginThrottle`, and raises a failed probe with `ui.alert` while the task is in Review |
| `changes` (`BuiltIn/ChangesPlugin.swift`) | `conversationSidebar` | `inline` | The Changes section: lists the task's Git changes with `task.changes.list`, reloads on `workspace.revision`, opens diffs with `ui.openDiff`, marks files with `task.changes.mark-viewed`, `mark-unviewed` and `mark-all-viewed`, and shows the pending count on the sidebar's rail. Disabling it hides the section and stops the window's file watching. Whether the section is collapsed is its plugin state, `state.collapsed` |
| `agents-info` (`BuiltIn/AgentsInfoPlugin.swift`) | `mainSidebarBottom` | `section` | The board's Agents info section: each installed agent's account and usage windows from `props.agents.usage`. It reads the usage again once per launch (`usage.get` with `refresh` on `app.launched`), signs in with `usage.login` and `ui.openURL`, and switches accounts with `usage.switch-account`, asking first with `ui.confirm` when that provider has running tasks (`props.agents.runningTasks`). With no agent CLI installed it renders nothing, so its section hides. Its collapsed state moved from `WorkspaceSettings.agentsInfoSectionCollapsedKey` into its plugin state, carried over once |
| `built-in-commands` (`Services/BuiltInCommandsPlugin.swift`) | `composerActions` | `headless` | The composer's `/mcp`, `/plan`, `/goal`, `/skill`, `/login` and `/plugin`, as Swift command handlers. `available` reads `conversation.provider.get` and disables `/goal` for an agent without goal mode; `/plan` and `/goal` call `ui.composer.setMode`. `/mcp` and `/skill` list the composer's mentions (`mentions.list`, with `mcp.status` for the sign-ins once asked with `complete`, and `skills.list` for which skills can be edited), choosing one mentions it, and their buttons call `ui.openSkills`. `/login` starts `usage.login` and opens its link with `ui.openURL`. `/plugin` lists Create Plugin (`plugin.mode`) and the installed plugins from `plugin.list`, with edit (`ui.editPlugin`) and delete (`ui.confirm`, then `plugin.delete`). Disabling it removes those commands |
| `scheduled-tasks` (`BuiltIn/ScheduledTasksPlugin.swift`) | `mainSidebar` | `popover` | The board's Scheduled Tasks popover, anchored to its sidebar button (400×460): recurring and one-time sections from `props.schedules.tasks`. It pauses and resumes with `schedule.pause` and `schedule.resume`, runs with `schedule.run-now`, deletes with `task.delete` after `ui.confirm`, opens a schedule's task or its last run with `ui.openTask` (a popover closes when its plugin opens a task or a new task), starts a recurring task with `ui.newTask`, and shows the Login Items notice from `props.schedules.needsLoginItemsApproval` with `ui.openLoginItems`. Disabling it removes the sidebar entry; schedules still run |

### Network

Every plugin, at every placement, has a `fetch(url, options)` global shaped
like the web's. `options` takes `method` (`GET` default), `headers` (an
object, an array of pairs, or anything with `forEach`), `body` (sent as text;
a `GET` or `HEAD` can't have one) and `timeout` (seconds, 30 default). It
resolves with a response carrying `ok`, `status`, `statusText`, `url` (after
redirects, which are followed), `redirected`, `headers` (`get` and `has`,
case-insensitive, `keys`, `forEach`), and `text()` and `json()`. Bodies are
text: a response is read as UTF-8, up to 10 MB. An HTTP error status still
resolves, with `ok` false. A request that can't be made rejects with an Error
whose `code` is `invalid_argument` (a URL that isn't absolute `http` or
`https`, a bad method, header or timeout) or `network_error` (no connection,
a timeout, a response over 10 MB).

`fetch` is the host call `net.fetch`. Both hosts answer it with
`PluginNetwork` in `Core/Plugins/Runtime/PluginNetwork.swift`, an ephemeral `URLSession` that
shares no cookies or cache, so the window and `plugin render` make the same
request; `plugin render` lists it in `hostCalls` with its arguments and
result. Validating a plugin answers it with `unavailable`, like any host
call. App Transport Security applies: plain `http` reaches IP addresses and
local hosts, while other hosts need `https`. To show a picture from the
network, give its URL to an `Image` atom rather than fetching it: `fetch`
bodies are text, and the window loads and caches an `Image`'s picture itself.

The runtime sends each host call through `__native.hostCall` and settles its
promise with `PluginRuntime.answerHostCall`. `PluginRuntime.updateProps`
replaces the props. Both are Foundation-only, so the core stays free of app
types.

## Op protocol

`prelude.js` implements a mutation-mode host config for `react-reconciler`. A
legacy (synchronous) root is used, so every update commits before the call
that caused it returns. The ops are collected while React renders and
commits. In `resetAfterCommit` they are handed to Swift as **one array per
commit** (`__native.commit(ops)`). Swift reads that JavaScript array directly
into `PluginOp`s (`PluginValue(javaScript:)`); no JSON string is built or
parsed. Values follow JSON.stringify's rules: only an object's own
enumerable keys are read, `undefined`, functions and symbols are dropped from
objects and become `null` in arrays, `NaN` and `Infinity` become `null`,
`toJSON()` is called once per value (a Date becomes its ISO string), and a circular value is an
error. Two differences: a boxed primitive (`new String("x")`) is read as an
object, and an exception thrown by a getter or `toJSON` is reported in the
plugin's errors while the commit still applies, with that field left out of
its object (or `null` in an array). The plugin's props and event values go the other way the same
way, as plain JavaScript values. The root container is node `0`.

| Op | Fields | Meaning |
| --- | --- | --- |
| `create` | `id`, `type`, `props`, `events` | A new atom node. `props` are the JSON props; function props are not sent, only their names in `events`. |
| `createText` | `id`, `text` | A raw string node, only inside a `Text` or a `Markdown`. |
| `update` | `id`, `props`, `events` | Replaces an atom's props. Only sent when its JSON props or event names changed. |
| `text` | `id`, `text` | Sets a raw string node's text. |
| `append` | `parent`, `child` | Appends (or moves to the end). |
| `insert` | `parent`, `child`, `before` | Inserts before a sibling. |
| `remove` | `parent`, `child` | Removes the child and its subtree. |
| `clear` | | Empties the root (React sends it before the first mount). |

Swift applies a commit with `PluginNodeTree.apply`. A malformed op rejects the
whole commit before any of it applies. Each `create` and
`update` is checked against the atom's props struct first.
`PluginValueDecoder` decodes the props struct straight from the
`PluginValue`s, with no JSON in between, once, for this check; the node
stores the decoded structs, so rendering never decodes (see "Typed and
dynamic props"). An invalid prop is reported with its path and what
is wrong, for example `<PillPicker> has an invalid prop: options.0.label: missing`. Every
`PluginNode` is observed on its own, so an op redraws only the SwiftUI view
of the node it changes. For example, toggling a label sends one `text` op,
and only that `Text` re-renders.

Timer callbacks run inside `batchedUpdates` too, so one tick commits once.

### Typed and dynamic props

A `PluginNode` holds its props one of two ways (`PluginNodeProps`):

- **Dynamic**, from a plugin: the op's `[String: PluginValue]` dictionary.
  `AtomType.validate` checks and decodes it once when the op applies, into
  the atom's props struct and `AtomCommon`, and the node stores them in
  `resolved`. An update with equal props changes nothing. A tree without
  validation decodes on its own and keeps the error in `resolved`, which the
  node's view shows as `plugin-node-error`; the error is computed when the op
  applies, not when the node renders.
- **Typed**, from native Swift: `PluginNode(id:props:common:)` takes the
  props struct itself (`PluginNode(id: 3, props: MeterProps(fraction: 0.4),
  common: AtomCommon(width: 80))`), its atom is the struct's `atomType`, and
  `setProps(_:common:)` replaces them, doing nothing when they are equal.
  There is no dictionary and nothing is decoded. Native code is trusted, so
  typed props skip the op checks (unknown keys, a Button's reserved shortcut,
  an Image's URL, a Markdown's frontmatter mode). Where an atom's own prop
  shares a name with a common one (`width` and `height` of `Popover`,
  `Modal` and `SidePanel`), one plugin key sets both, so typed props must set
  them alike (`PluginNodeProps.conflictingKeys`, asserted in debug builds).

Either way, a node's view reads only `resolved`, and `AtomRegistry` has one
entry per props type that builds the atom's view from it, so both kinds share
the same view code and rendering never decodes. Like the rest of `Core/`, the
node, its props and the typed API are Foundation-only, and props hold only
plain values (strings, numbers, booleans and string names such as `accent`),
never SwiftUI types. The props structs are `Codable`: `PluginNodeProps.values`
encodes typed props into the dictionary a plugin would send (the tree
snapshot shows them that way), so a tree can be serialized for a UI written
in another language.

`scripts/benchmark-atom-tree.sh` measures the renderer in a Release build (the
`PLAYHOUSE_ATOM_BENCHMARK` condition compiles in `Renderer/AtomTreeBenchmark.swift`
and its decode and body counters, never into a shipped app): a board of 300
card-like trees opened, streamed into and fully updated, a lazy 500-card list
scrolled, and the streaming on a typed board, which must decode nothing. It
prints the median of several fresh app runs. `scripts/unit/plugin-node-props-tests.swift`,
run by `scripts/test-e2e.sh`, checks the decode counts, typed nodes, stored
errors, the Codable round trip and the native event handlers.

Events go the other way. An atom view calls `dispatch(nodeID:event:value:)`
on the tree's `AtomEventHandler` (`Core/Plugins/Runtime/AtomEvents.swift`), which
`PluginNodeView` takes beside the node. For a plugin that is its
`PluginRuntime`, which runs `__playhouseDispatch(id, event, value)`. That finds
the node's current handler and calls it inside `batchedUpdates`, so its state
updates arrive as one commit. A native tree passes an `AtomEventHandlers`
instead and registers a Swift closure per node and event
(`handlers.on(node, "onPress") { _ in … }`), with no JavaScript runtime; the
typed board in the benchmark renders that way. Registering also lists the
event in the node's `events`, which a TextField's Return and arrows and a
Scroll's end read to decide whether to take them, so a native tree sets
`events` only through its handlers, never through ops. Either way `dispatch` returns
false when the node has no handler for the event.
