# Plugins

A plugin is plain JavaScript that builds UI with React. A custom React
renderer running in JavaScriptCore turns each commit into mutation ops. Swift
applies them to an observable node tree, and SwiftUI draws that tree from
native **atoms**. Plugins compose only atoms. Composites such as the task
item, a board column's frame, the board's Agents info section, the Token Stats modal, the Skills
page's header and gallery, the task header's repository chips and Add
repository picker, and the conversation composer's box exist only as native
SwiftUI built from the same atoms (`Playhouse/App/TaskItemView.swift`,
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
| `Playhouse/Resources/PluginRuntime/` | `prelude.js` (the React host config), `vendor/` (prebuilt react 18.3.1, react-reconciler 0.29.2, scheduler 0.23.2), `catalog/` (one page per atom, `TaskItem.js`, `AgentsInfo.js`, `TokenStats.js`, `SkillsPage.js`, `RepositoryChips.js`, `Composer.js`, and their `sample-*.json` data). |

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
notice and empty state; the column's cards stay native `TaskCardView`s passed in
as content. Change it whenever the column's frame changes;
`test_plugin_kanban_column_renders_from_atoms_like_native` compares the two.
Each composite reads a display model that is already derived
(`TaskItemModel`, `AgentsInfoModel`, `TokenStatsModel`, `SkillsPageModel`,
`RepositoryChipsModel`, `RepositoryPickerModel`, `ComposerModel`, `KanbanColumnModel`), so the JavaScript copy
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
  page, `repositoryChips` and `repositoryPicker` for the repository chips, `kanbanColumns` for the Kanban Column page).
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
`Link`, `Card`, `Disclosure`, `Panel`, `Scroll`, `PressArea` and `Overlay` take atom children. An unknown atom, an unknown prop, a prop
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
Token Stats modal, the Skills page and the repository chips and picker and the composer are built from. Every atom also takes these common props:

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
| `Stack` | `axis` (`"v"` default, `"h"`), `spacing`, `align` (column: leading/center/trailing; row: top/center/bottom/baseline), `group` (one accessibility container), `combine` (one accessibility element joining its children's labels) | | atoms |
| `Text` | `text` (or string children), `size`, `weight`, `design` (`monospaced`, `rounded`), `color`, `lineLimit`, `tracking`, `lineSpacing`, `wrap` (grow vertically), `numeric` (animate digits), `truncation` (`head`, `middle`, `tail` default), `monospacedDigits` | | strings |
| `Icon` | `name` (SF Symbol) or `asset` (template image), `size`, `weight`, `color` | | |
| `Label` | `text`, `icon` (SF Symbol), `size`, `weight`, `color` | | |
| `Button` | `style` (`plain` default, `borderless`, `bordered` push button, `prominent` accent push button, `automatic` the platform default), `emphasis` (hover capsule padding), `overhang` (capsule spills past the layout of a Button without a fixed size), `disabled`, `controlSize` (`small`; inherited otherwise), `shortcut` (`default`: Return presses it; `cancel`: Escape presses it; window-wide, so only a window's primary or dismissing action sets one), `destructive` (the destructive role) | `onPress()` | atoms (its label) |
| `Link` | `url`, `emphasis` | | atoms (its label) |
| `Spinner` | `size` (`small` default, `mini`, `regular`) | | |
| `Spacer` | `minLength` | | |
| `PillPicker` | `options` (`[{value, label, help?, testID?}]`), `selected`; the `help` tooltip may contain `{help}`, which is replaced by the shown option's help | `onChange(value)` | |
| `Card` | `menu` (`[{id, title, icon?, destructive?, testID?}]`), `meter` (0…1 usage bar), `meterLabel`, `meterTestID`; `testID`, `label` and `hint` describe its open button | `onPress()`, `onMenu(id)` | atoms |
| `Disclosure` | `title`, `collapsed` (required; the atom shows what it is given), `spacing`, `toggleTestID` (the title button); a collapsed section keeps its children in the tree and hides them | `onToggle()`, called inside an animation; the owner flips `collapsed` | atoms |
| `Panel` | `spacing`, `fill` (a color, `primary` default), `fillOpacity` (0.05 default), `cornerRadius` (8 default), `capsule` (fully rounded ends instead, a circle when square), `stroke` (a border color), `strokeOpacity` (1 default), `strokeWidth` (1 default), `dash` (`[on, off]`, solid default), `align` (`leading` default, whose `minHeight` keeps children at the top, or `center`), `combine` (one accessibility element joining its children's labels); a rounded filled background behind a leading column, one accessibility container | | atoms |
| `Meter` | `fraction` (0…1, required), `color` (`accent` default), `thickness` (3 default), `trackOpacity` (0.12 default), `minFill` (shortest fill in points, 0 default); decorative unless it has a `label` | | |
| `Scroll` | `spacing`, `maxHeight` (shrinks to its content up to it; the common `height` fixes it), `inset` (padding inside the scroll view), `lazy` (builds only the children in view); a vertical scroll view around a leading column that fills its width | | atoms |
| `Divider` | none; a thin separator across its stack | | |
| `ChoiceBar` | `options` (`[{value, label, testID?}]`), `selected`; one button per option, the selected one highlighted and marked selected | `onChange(value)`, not raised for the option already selected | |
| `Toggle` | `isOn` (required; the atom shows what it is given), `size` (`mini`, `small`, `regular` default), `disabled`; a switch with no visible label, so give it a `label` | `onToggle()`; the owner flips `isOn` | |
| `TextField` | `text` (required), `placeholder`, `autoFocus` (takes the keyboard focus when it appears); a rounded one-line field that edits its own copy and takes `text` whenever the owner changes it | `onChange(text)` on every edit; `onSubmit()` for Return and `onArrow(direction)` (`up`, `down`) for the arrows, which keep their usual behavior when there is no handler | |
| `Segmented` | `options` (`[{value, label}]`), `selected`, `disabled`; a segmented control, as wide as its segments unless it has a `width` | `onChange(value)`, not raised for the segment already selected | |
| `Menu` | `icon` (SF Symbol), `text` (beside or instead of the symbol), `size`, `weight` (the symbol's), `textSize`, `textWeight`, `badgeIcon` (a second symbol before the text), `color` (`secondary` default), `indicator` (the pull-down chevron, hidden by default), `disabled`, `items` (groups `[[{id, title, destructive?, help?, testID?, checked?, icon?}]]`, a separator between non-empty groups; a checked item shows a checkmark); a borderless pull-down whose common `width` and `height` frame its label | `onMenu(id)` | |
| `PressArea` | `spacing`, `pointer` (the pointing hand); a leading column that takes every click on its children, one accessibility container | `onPress()` for a click, `onLongPress()` for a press and hold | atoms |
| `Overlay` | `align` (`center` default, `top`, `bottom`, `leading`, `trailing`, `topLeading`, `topTrailing`, `bottomLeading`, `bottomTrailing`), `offsetX`, `offsetY`, `revealOnHover` (the overlay shows only while the pointer is over the atom); its first child laid out as usual and the rest drawn over it at `align`, moved by the offsets without changing its size; one accessibility container | | atoms |
| `Editor` | `text` (required), `placeholder`, `placeholderTestID`, `enabled`, `autofocus`, `focused`, `focusRequest` (each new value moves the keyboard in once), `inputTestID` and `inputLabel` (the text view's own accessibility identifier and label); a multiline message editor that grows with its text; the common `hint` is its accessibility help; a pasted image reaches native owners only | `onChange(text)`, `onSubmit()` (Return), `onSteerSubmit()` (Command-Return), `onFocusChange(isFocused)` | |
| `Popover` | `isPresented` (required), `arrowEdge` (`top` default, `bottom`, `leading`, `trailing`), `width`; shows the children after its first in a popover (a leading column) anchored to its first; its `testID` only names it to events | `onDismiss()` (a click outside or Escape; the owner sets `isPresented` false) | atoms: the anchor, then the content |
| `StepSlider` | `options` (`[{value, label}]`), `selected`; a discrete slider as wide as its container, driven by click, drag or arrow keys; its common `label` and `testID` name it | `onChange(value)` | |

To add an atom, add its case and props struct to `Core/AtomProps.swift`, its
view to `Atoms/AtomViews.swift`, its registry entry to
`Atoms/AtomRegistry.swift`, and a catalog page `catalog/<Atom>.js`. Add one
only when a native composite needs it. Its view passes its type to
`atomCommon` (or applies `atomHighlight` itself) and its case says whether it
`isContainer`, so Debug ▸ Highlight Native Atoms outlines it: containers in
orange, leaves in green, with its type name on hover. The overlay is
debug-only; it shows where atoms are used, so plain SwiftUI left inside a
composite shows as a gap.

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
