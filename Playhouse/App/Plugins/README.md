# Plugins

A plugin is plain JavaScript that builds UI with React. A custom React
renderer running in JavaScriptCore turns each commit into mutation ops. Swift
applies them to an observable node tree, and SwiftUI draws that tree from
native **atoms**. Plugins compose only atoms. Composites such as the task
item, a board column's frame, the board's Agents info section, the Token Stats modal, the Skills
page's header and gallery, the task header's repository chips and Add
repository picker, the conversation composer's box and the board's Done
archive exist only as native SwiftUI built from the same atoms
(`Playhouse/App/TaskItemView.swift`, `DoneArchivePanel` in
`Playhouse/App/DoneArchiveView.swift`,
`KanbanColumnSection` in `Playhouse/App/KanbanColumnSection.swift`,
`ComposerView` in `Playhouse/App/ComposerView.swift`, `AgentsInfoSection` in
`Playhouse/App/AgentsInfoView.swift`, `TokenStatsView` in
`Playhouse/App/TokenStatsView.swift`, `SkillsPageHeader` and
`SkillGalleryView` in `Playhouse/App/SkillGalleryView.swift`,
`RepositoryChipsView` and `RepositoryPickerView` in
`Playhouse/App/RepositoryChipsView.swift`).

| Path | What it is |
| --- | --- |
| `Core/` | Foundation + JavaScriptCore only: `PluginRuntime` (the JS context), `PluginNodeTree` (ops → nodes), `AtomProps` (atom names and props), `PluginRenderCommand` (`playhouse plugin render`). Also compiled into the bridge daemon. |
| `Atoms/` | The atoms' SwiftUI views and `AtomRegistry`, which maps each atom name to a builder that decodes the node's props. |
| `Renderer/` | `PluginSurface` (runs one script and renders its tree) and the Plugin Catalog window. |
| `Host/` | Installed plugins in the app: `PluginRegistry` (the plugins `plugin list` reports), `PluginSlot` (a placement's entry buttons and Add Plugin mode's "Add here" placeholder), `PluginSurfaceView` (a mounted plugin with live props and host calls), its popover, modal, sidebar and page presentations, and the mode's banner. |
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
page's header and skill gallery (`SkillsPageHeader` and `SkillGalleryView`),
opened by the composer's Skills button (`SkillsButton`); `SkillsPageView`
owns their state and keeps the delete and link confirmations, the editor and
New Skill panels, and the Rules and MCP lists native. Change it whenever the
header or gallery changes; `test_plugin_skills_page_renders_from_atoms_like_native`
compares those two. `catalog/RepositoryChips.js` does the same for the task
header's repository chips (`RepositoryChipsView`) and the Add repository
picker their + button opens (`RepositoryPickerView`); the header presents
the picker and each chip's settings as popovers, and the settings stay
native. Change it whenever the chips or the picker change;
`test_plugin_repository_chips_renders_from_atoms_like_native` compares those
two. `catalog/Composer.js` does the same for `ComposerView`, the conversation
composer's box: the editor, the Skills button, the + mode menu, Start
Implementing, the provider menu, the model button with its popover, the
schedule button and the send, stop, continue or schedule control. The
conversation (`TaskConversationView.composer`) derives a `ComposerModel` and
`ComposerActions` and passes the notices, images, queued follow-ups and goal
row above the box as the view's native `header`, and the schedule popover's
content as its native `scheduleContent`. Change `ComposerView` and
`Composer.js` together; `test_plugin_composer_renders_from_atoms_like_native`
compares them. `catalog/KanbanColumn.js` does the same for `KanbanColumnSection`, a board
column's header (status dot, title, count, the Backlog's Add button), Blocked
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
Stats modal), `Page` (slides in over all of its first child; the Scheduled
Tasks page) and `SidePanel` (slides in over one edge; the Done archive). The
owner closes a Page or SidePanel with its own control, as the board's Back
and close buttons do. A Page or SidePanel keeps an empty AppKit view behind what it covers so
accessibility hit tests reach its controls (without one the board's archive
rows took clicks but XCUITest couldn't find them), and a SidePanel orders its
panel ahead of the covered view, so its controls stay reachable even when
that view is one accessibility group (a plugin's base Stack with `group`). On a Modal or SidePanel, `width` (and a Modal's `height`) sizes what it
presents, not the atom: those keys are its own props there, not the common
frame props. A Popover's `width` still frames its anchor too; a follow-up is
to keep atom and common prop names apart. The board presents those three through the same
atom views (`atomModal`, `atomPage` and `atomSidePanel`).

Smaller native views are also built straight from atoms, with no catalog
copy because they have no state or layout a plugin would need to match: the
board's header, sidebar button, worktree notice and Rename Task sheet (`KanbanBoardView.swift`), the Scheduled Tasks
page apart from its delete alert (`ScheduledTasksPageView.swift`), and in the
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

Raw strings may only appear inside a `Text`, and only `Stack`, `Button`,
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
Token Stats modal, the Skills page, the repository chips and picker, the composer and the Done archive are built from, and that present the board's modal, page and side panel. Every atom also takes these common props:

| Common prop | |
| --- | --- |
| `testID` | Accessibility identifier |
| `label`, `value`, `hint` | Accessibility label, value and hint |
| `help` | Hover tooltip |
| `width`, `height`, `minWidth`, `minHeight` | Frame, in points (a Button's is its label's slot, and its hover capsule spills past it without growing the layout; a Link's surrounds the capsule) |
| `fillWidth` | Stretch to the available width, content leading |
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
| `Stack` | `axis` (`"v"` default, `"h"`), `spacing`, `align` (column: leading/center/trailing; row: top/center/bottom/baseline), `group` (one accessibility container), `combine` (one accessibility element joining its children's labels); a surface, in either axis: `fill` (a color, `primary` default) at `fillOpacity` (1 default), drawn when either is set, a border inside its edge drawn when any of `stroke` (a color, `primary` default), `strokeOpacity` (1 default), `strokeWidth` (1 default) or `dash` (`[on, off]`, solid default) is set, in a rectangle rounded by `cornerRadius` (0 default) or, with `capsule`, with fully rounded ends (a circle when square). With no surface prop it draws nothing. With one, its frame and padding size the surface and its children sit inside it at the start of its axis and at `align` across it (a `minHeight` column with `align: "leading"` keeps them at the top leading corner), or, with `align` center or unset (the default), centered both ways, also when `fillWidth` stretches it, so give a Stack you decorate the `align` its children had. A fixed `width` or `height` centers them, as it does any atom's content. An unknown color draws `primary` | | atoms |
| `Text` | `text` (or string children), `size`, `weight`, `design` (`monospaced`, `rounded`), `color`, `lineLimit`, `tracking`, `lineSpacing`, `wrap` (grow vertically), `numeric` (animate digits), `truncation` (`head`, `middle`, `tail` default), `monospacedDigits` | | strings |
| `Icon` | `name` (SF Symbol) or `asset` (template image), `size`, `weight`, `color`, `original` (draw the asset in its own colors, as the board's logo) | | |
| `Label` | `text`, `icon` (SF Symbol), `size`, `weight`, `color`; SwiftUI's label for an `Icon` and a `Text` in a row `Stack` (see Composite atoms below) | | |
| `Button` | `style` (`plain` default, `borderless`, `bordered` push button, `prominent` accent push button, `link` accent text like a hyperlink, `automatic` the platform default), `emphasis` (hover capsule padding), `overhang` (capsule spills past the layout of a Button without a fixed size), `disabled`, `controlSize` (`small` or `large`; inherited otherwise), `shortcut` (`default`: Return presses it; `cancel`: Escape presses it; window-wide, so only a window's primary or dismissing action sets one), `destructive` (the destructive role), `selected` (marked selected to accessibility: the current choice in a row of buttons) | `onPress()` | atoms (its label) |
| `Link` | `url`, `emphasis` | | atoms (its label) |
| `Spinner` | `size` (`small` default, `mini`, `regular`) | | |
| `Spacer` | `minLength` | | |
| `PillPicker` | `options` (`[{value, label, help?, testID?}]`), `selected`; the `help` tooltip may contain `{help}`, which is replaced by the shown option's help | `onChange(value)` | |
| `Card` | `menu` (`[{id, title, icon?, destructive?, testID?}]`), `meter` (0…1 usage bar), `meterLabel`, `meterTestID`; `testID`, `label` and `hint` describe its open button | `onPress()`, `onMenu(id)` | atoms |
| `Disclosure` | `title`, `collapsed` (required; the atom shows what it is given), `spacing`, `toggleTestID` (the title button); a collapsed section keeps its children in the tree and hides them | `onToggle()`, called inside an animation; the owner flips `collapsed` | atoms |
| `Panel` | `spacing`, `fill`, `fillOpacity`, `cornerRadius`, `capsule`, `stroke`, `strokeOpacity`, `strokeWidth`, `dash`, `align` (`leading` default or `center`), `combine`. A composite atom, shorthand for a column `Stack` with `group` and a surface whose defaults differ: `fill` `primary` at `fillOpacity` 0.05, `cornerRadius` 8, `align` `leading`, and a border only when it has a `stroke`. Its view is that Stack's (`PanelProps.stack`) | | atoms |
| `Meter` | `fraction` (0…1, required), `color` (`accent` default), `thickness` (3 default), `trackOpacity` (0.12 default), `minFill` (shortest fill in points, 0 default); decorative unless it has a `label` | | |
| `Scroll` | `spacing`, `maxHeight` (shrinks to its content up to it; the common `height` fixes it), `inset` (padding inside the scroll view), `lazy` (builds only the children in view); a vertical scroll view around a leading column that fills its width | `onEndReached()`: raised each time the end of its content comes into view, and once when the content fits (the Done archive appends its next page). It isn't raised again while the end stays in view, so an owner whose page doesn't fill the view loads the next one itself | atoms |
| `Divider` | none; a thin separator across its stack | | |
| `ChoiceBar` | `options` (`[{value, label, testID?}]`), `selected`; one button per option, the selected one highlighted and marked selected. Its capabilities are reachable through a decorated row `Stack` of `Button`s (`selected`) each on a decorated `Stack` with a `Text`, as the ChoiceBar page composes it beside the atom (see Composite atoms below) | `onChange(value)`, not raised for the option already selected | |
| `Toggle` | `isOn` (required; the atom shows what it is given), `size` (`mini`, `small`, `regular` default), `disabled`; a switch with no visible label, so give it a `label` | `onToggle()`; the owner flips `isOn` | |
| `TextField` | `text` (required), `placeholder`, `autoFocus` (takes the keyboard focus when it appears), `style` (`rounded` default, `plain`: no border, for a field on a decorated `Stack`); a one-line field that edits its own copy and takes `text` whenever the owner changes it | `onChange(text)` on every edit; `onSubmit()` for Return and `onArrow(direction)` (`up`, `down`) for the arrows, which keep their usual behavior when there is no handler | |
| `Segmented` | `options` (`[{value, label}]`), `selected`, `disabled`; a segmented control, as wide as its segments unless it has a `width` | `onChange(value)`, not raised for the segment already selected | |
| `Menu` | `icon` (SF Symbol), `text` (beside or instead of the symbol), `size`, `weight` (the symbol's), `textSize`, `textWeight`, `badgeIcon` (a second symbol before the text), `color` (`secondary` default), `indicator` (the pull-down chevron, hidden by default), `disabled`, `items` (groups `[[{id, title, destructive?, help?, testID?, checked?, icon?, disabled?}]]`, a separator between non-empty groups; a checked item shows a checkmark and a disabled one is dimmed and can't be chosen); a borderless pull-down whose common `width` and `height` frame its label | `onMenu(id)` | |
| `PressArea` | `spacing`, `pointer` (the pointing hand); a leading column that takes every click on its children, one accessibility container | `onPress()` for a click, `onLongPress()` for a press and hold | atoms |
| `Overlay` | `align` (`center` default, `top`, `bottom`, `leading`, `trailing`, `topLeading`, `topTrailing`, `bottomLeading`, `bottomTrailing`), `offsetX`, `offsetY`, `revealOnHover` (the overlay shows only while the pointer is over the atom); its first child laid out as usual and the rest drawn over it at `align`, moved by the offsets without changing its size; one accessibility container | | atoms |
| `Editor` | `text` (required), `placeholder`, `placeholderTestID`, `enabled`, `autofocus`, `focused`, `focusRequest` (each new value moves the keyboard in once), `inputTestID` and `inputLabel` (the text view's own accessibility identifier and label); a multiline message editor that grows with its text; the common `hint` is its accessibility help; a pasted image, and Escape when the owner handles it, reach native owners only | `onChange(text)`, `onSubmit()` (Return), `onSteerSubmit()` (Command-Return), `onFocusChange(isFocused)` | |
| `Popover` | `isPresented` (required), `arrowEdge` (`top` default, `bottom`, `leading`, `trailing`), `width`; shows the children after its first in a popover (a leading column) anchored to its first; its `testID` only names it to events | `onDismiss()` (a click outside or Escape; the owner sets `isPresented` false) | atoms: the anchor, then the content |
| `StepSlider` | `options` (`[{value, label}]`), `selected`; a discrete slider as wide as its container, driven by click, drag or arrow keys; its common `label` and `testID` name it | `onChange(value)` | |
| `Modal` | `isPresented` (required), `width`, `height` (fix the sheet's size; it fits its content otherwise); a sheet over the window presented from its first child, which stays laid out as usual, showing the rest in a leading column; its `testID` and accessibility props name the sheet's content | `onDismiss()` (Escape; the owner sets `isPresented` false) | atoms: the presenter, then the content |
| `Page` | `isPresented` (required); slides in from the trailing edge over all of its first child, which stays laid out as usual and sizes the atom, showing the rest in a leading column on the window background, like the Scheduled Tasks page; its `testID` and accessibility props name the page; the owner closes it with its own control | | atoms: the covered view, then the page |
| `SidePanel` | `isPresented` (required), `edge` (`trailing` default, `leading`), `width` (340 default); a full-height panel sliding in over that edge of its first child, which stays laid out as usual and sizes the atom, showing the rest in a column with no spacing on the window background, with a hairline along its inner edge and a shadow, like the Done archive; its `testID` and accessibility props name the panel; the owner closes it with its own control | | atoms: the covered view, then the panel |

### Composite atoms

Most atoms do one thing. `Panel` is a composite atom: shorthand for a column
`Stack` with `group` and a surface (`primary` at 0.05, radius 8, a border only
when it has a `stroke`), drawn by that Stack's own view (`PanelProps.stack`).

These are composites too, and still to settle:

| Atom | Made of | What is left |
| --- | --- | --- |
| `ChoiceBar` | A decorated row `Stack` of `Button`s marked `selected`, each label a decorated `Stack` around a `Text` | Every capability is reachable that way; its view is still its own, whose circular corners a Stack's continuous ones would change |
| `Label` | An `Icon` and a `Text` in a row `Stack` | Every capability is reachable that way; its view is SwiftUI's `Label`, which spaces and aligns them the platform's way |
| `Card` | A press surface, a shadowed rounded fill, a right-click menu and a usage bar | Its shadow, right-click menu and heatmap usage bar are reachable through no smaller atom |
| `Disclosure` | A `Button` (chevron `Icon` and `Text`) over a column `Stack` | Its animated collapse is reachable through no smaller atom |
| `Scroll` | A scroll view around a column `Stack` | `lazy`: a `Stack` is never lazy |
| `Menu` | A pull-down whose label is `Icon`s and a `Text` | Its label is symbol and text props, not atom children |
| `PressArea`, `Popover`, `Modal` | A press or presentation around a column `Stack` | The column is reachable through a nested `Stack`, but they draw their own |
| `Page`, `SidePanel` | A presentation around a column `Stack` on a `window`-filled surface | The column and the fill are reachable through a `Stack`; the shadow over what they cover and the SidePanel's one-edge hairline are reachable through no smaller atom |

To add an atom, add its case and props struct to `Core/AtomProps.swift`, its
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

`plugin refresh` validates every folder and makes the window reload. It checks
the manifest and renders each plugin once with sample context; any error marks
the plugin invalid. The Plugins menu lists every plugin with its placement;
an invalid one also shows its first error and gets no button. A plugin is
deleted with its Delete item in the Plugins menu, or with `plugin delete --id`.

| Placement | Where | Entry | Extra context in `Playhouse.props` |
| --- | --- | --- | --- |
| `mainSidebar` | The board's sidebar, below Scheduled Tasks | Labeled | None: it is standalone |
| `conversationSidebar` | The task sidebar, below Changes | Labeled | `task`, `repositories`, `contextFolders` |
| `conversationToolbar` | The task sidebar's bottom row, beside Terminal | Icon | `task`, `repositories`, `contextFolders` |
| `composerActions` | The composer's actions row, beside Skills (also in the standalone chat) | Icon | The above and `composer` (`{draft, selection: {location, length, text}}`) |

Every plugin also gets `plugin` (`{id, name, placement, presentation}`) and
`app` (`{appearance}`). `presentation` is one of:

- `popover`: anchored to the entry button.
- `modal`: a sheet.
- `sidebar`: slides in from the trailing edge.
- `page`: covers the board or the conversation.

The core builds the props (`PluginContext` in `Core/PluginLibrary.swift`).
They stay live: `Playhouse.useProps()` re-renders when they change, as when the
user edits the draft.

Installed plugins also get host calls. Each returns a Promise:

| Call | What it does |
| --- | --- |
| `Playhouse.bridge(command, arguments)` | Full app access: any bridge command the CLI sends (`"task.list"`, `"task.rename"`, `"conversation.send"`, …) except `plugin.render`, which would recurse. It resolves with the command's result, or rejects with an Error carrying `code` and `message`. In the app it goes through `DaemonClient`; in `plugin render`, through the daemon's own `PlayhouseBridgeRuntime` |
| `Playhouse.ui.close()` | Closes the surface |
| `Playhouse.ui.openTask(taskID)` | Opens a task |
| `Playhouse.ui.composer.setDraft(text)`, `.insertText(text)`, `.replaceSelection(text)`, `.focus()` | Edit the composer at the conversation placements; elsewhere they reject |

`plugin render` records the `ui` calls in its `hostCalls` output. Both hosts refuse calls by the same rules, `PluginHostRules` in `Core/PluginLibrary.swift`: `plugin.render` is `invalid_argument`, and a composer call from the board's sidebar is `unavailable`.

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
| `createText` | `id`, `text` | A raw string node, only inside a `Text`. |
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
`PluginValue`s, with no JSON in between, both for this check and on every
render in `AtomRegistry`. An invalid prop is reported with its path and what
is wrong, for example `<PillPicker> has an invalid prop: options.0.label: missing`. Every
`PluginNode` is observed on its own, so an op redraws only the SwiftUI view
of the node it changes. For example, toggling a label sends one `text` op,
and only that `Text` re-renders.

Timer callbacks run inside `batchedUpdates` too, so one tick commits once.

Events go the other way. An atom view calls
`PluginRuntime.dispatch(nodeID:event:value:)`, which runs
`__playhouseDispatch(id, event, value)`. That finds the node's current
handler and calls it inside `batchedUpdates`, so its state updates arrive as
one commit.
