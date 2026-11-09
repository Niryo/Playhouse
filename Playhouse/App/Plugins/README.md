# Plugins

A plugin is plain JavaScript that builds UI with React. A custom React
renderer running in JavaScriptCore turns each commit into mutation ops. Swift
applies them to an observable node tree, and SwiftUI draws that tree from
native **atoms**. Plugins compose only atoms. Composites such as the task
item and the board's Agents info section exist only as native SwiftUI built
from the same atoms (`Playhouse/App/TaskItemView.swift`,
`AgentsInfoSection` in `Playhouse/App/AgentsInfoView.swift`).

| Path | What it is |
| --- | --- |
| `Core/` | Foundation + JavaScriptCore only: `PluginRuntime` (the JS context), `PluginNodeTree` (ops → nodes), `AtomProps` (atom names and props), `PluginRenderCommand` (`playhouse plugin render`). Also compiled into the bridge daemon. |
| `Atoms/` | The atoms' SwiftUI views and `AtomRegistry`, which maps each atom name to a builder that decodes the node's props. |
| `Renderer/` | `PluginSurface` (runs one script and renders its tree) and the Plugin Catalog window. |
| `Playhouse/Resources/PluginRuntime/` | `prelude.js` (the React host config), `vendor/` (prebuilt react 18.3.1, react-reconciler 0.29.2, scheduler 0.23.2), `catalog/` (one page per atom, `TaskItem.js`, `AgentsInfo.js`, and their `sample-*.json` data). |

`catalog/TaskItem.js` is a demo that copies `TaskItemView` atom for atom, so the
catalog can show the two side by side. It is not a composite exposed to
plugins. Change it whenever `TaskItemView` changes;
`test_plugin_task_item_renders_from_atoms_like_native` compares the two.
`catalog/AgentsInfo.js` does the same for `AgentsInfoSection`, including its
collapsing title (the `Disclosure` atom); change it whenever that section
changes. `test_plugin_agents_info_renders_from_atoms_like_native` compares
those two. Each composite reads a display model that is already derived
(`TaskItemModel`, `AgentsInfoModel`), so the JavaScript copy formats nothing
the native one doesn't.

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
  `blockedStatusMessage` for the task item, `agentsInfo` for Agents info).
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
`Link`, `Card`, `Disclosure` and `Panel` take atom children. An unknown atom, an unknown prop, a prop
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

These are exactly the atoms the task item and the Agents info section are
built from. Every atom also takes these common props:

| Common prop | |
| --- | --- |
| `testID` | Accessibility identifier |
| `label`, `value`, `hint` | Accessibility label, value and hint |
| `help` | Hover tooltip |
| `width`, `height`, `minWidth`, `minHeight` | Frame, in points (a Button's is its label's slot, and its hover capsule spills past it without growing the layout; a Link's surrounds the capsule) |
| `fillWidth` | Stretch to the available width, content leading |
| `padding` | Uniform padding |
| `paddingX` | Extra horizontal padding (a Button's sits inside its hover capsule) |
| `passThrough` | Let clicks through to what is behind it (the card) |

Colors are `primary`, `secondary`, `tertiary`, `accent`, `text`, `red`,
`green`, `orange`, `blue`, `purple`, or `#RRGGBB`. Weights are `regular`,
`medium`, `semibold` and `bold`.

| Atom | Props | Events | Children |
| --- | --- | --- | --- |
| `Stack` | `axis` (`"v"` default, `"h"`), `spacing`, `align` (column: leading/center/trailing; row: top/center/bottom), `group` (one accessibility container), `combine` (one accessibility element joining its children's labels) | | atoms |
| `Text` | `text` (or string children), `size`, `weight`, `design` (`monospaced`), `color`, `lineLimit`, `tracking`, `lineSpacing`, `wrap` (grow vertically), `numeric` (animate digits), `truncation` (`head`, `middle`, `tail` default), `monospacedDigits` | | strings |
| `Icon` | `name` (SF Symbol) or `asset` (template image), `size`, `weight`, `color` | | |
| `Label` | `text`, `icon` (SF Symbol), `size`, `weight`, `color` | | |
| `Button` | `style` (`plain` default, `borderless`), `emphasis` (hover capsule padding), `overhang` (capsule spills past the layout of a Button without a fixed size), `disabled` | `onPress()` | atoms (its label) |
| `Link` | `url`, `emphasis` | | atoms (its label) |
| `Spinner` | `size` (`small` default, `mini`) | | |
| `Spacer` | `minLength` | | |
| `PillPicker` | `options` (`[{value, label, help?, testID?}]`), `selected`; the `help` tooltip may contain `{help}`, which is replaced by the shown option's help | `onChange(value)` | |
| `Card` | `menu` (`[{id, title, icon?, destructive?, testID?}]`), `meter` (0…1 usage bar), `meterLabel`, `meterTestID`; `testID`, `label` and `hint` describe its open button | `onPress()`, `onMenu(id)` | atoms |
| `Disclosure` | `title`, `collapsed` (required; the atom shows what it is given), `spacing`, `toggleTestID` (the title button); a collapsed section keeps its children in the tree and hides them | `onToggle()`, called inside an animation; the owner flips `collapsed` | atoms |
| `Panel` | `spacing`, `fill` (a color, `primary` default), `fillOpacity` (0.05 default), `cornerRadius` (8 default); a rounded filled background behind a leading column, one accessibility container | | atoms |
| `Meter` | `fraction` (0…1, required), `color` (`accent` default), `thickness` (3 default); decorative unless it has a `label` | | |

To add an atom, add its case and props struct to `Core/AtomProps.swift`, its
view to `Atoms/AtomViews.swift`, its registry entry to
`Atoms/AtomRegistry.swift`, and a catalog page `catalog/<Atom>.js`. Add one
only when a native composite needs it.

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
