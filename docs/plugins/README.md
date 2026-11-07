# Playhouse plugins

A plugin is a folder that adds a view to Playhouse. Its logic is JavaScript, run by JavaScriptCore on the plugin's own thread; its UI is a JSON tree that Playhouse draws with native SwiftUI components. Installed plugins live in `<data>/Plugins/<plugin-id>/` (`~/Library/Application Support/Playhouse/Plugins` for the primary profile) and open from the app menu: **Plugins ▸ <plugin> ▸ Open "<view>"**.

```
my-plugin/
  plugin.json   manifest
  view.json     view trees keyed by view id
  logic.js      initialState and actions (optional for a static view)
```

## plugin.json

```json
{
  "id": "pr-radar",
  "name": "PR Radar",
  "version": "0.1.0",
  "description": "What the plugin does.",
  "contributes": { "views": [ { "id": "main", "title": "PR Radar" } ] }
}
```

The id is lowercase letters, digits and dashes. `contributes.buttons` and a view `placement` are reserved for a later version and are rejected by `plugin validate`.

## view.json

Each view is a tree of `{ "type", "props", "children" }`. `playhouse-cli plugin components` lists every component with its typed props and events, and **Plugins ▸ Component Catalog…** shows each one live.

```json
{
  "main": {
    "type": "vstack",
    "props": { "spacing": 12, "padding": 16 },
    "children": [
      { "type": "text", "props": { "text": "Clicked {{count}} times" } },
      { "type": "button", "props": { "title": "Click me", "onTap": { "action": "increment", "payload": { "by": 1 } } } },
      { "type": "if", "props": { "cond": "{{!count}}" }, "children": [ { "type": "text", "props": { "text": "Not clicked yet." } } ] },
      { "type": "list", "props": { "items": "{{entries}}" }, "children": [ { "type": "text", "props": { "text": "{{index}}: {{item.title}}" } } ] }
    ]
  }
}
```

- **Bindings** are `{{path}}` lookups into state, with `!` to negate and `.length` on arrays and strings. A prop that is exactly one binding gets the bound value itself (a number, array or boolean); bindings inside longer text are interpolated. Anything more is computed in logic.js and stored in state.
- **Structural nodes:** `if` shows its children while `cond` is truthy; `list` repeats its children per item of `items`, with the item as `item` (or the name in `as`) and its position as `index`. Rows are keyed by the item's `id` (or the field in `key`).
- **Events** are `{ "action": "<name>", "payload": … }`, with bindings in the payload resolved when the view renders. `onTap` and `onAppear` work on every component; inputs such as `textfield` fire `onChange` with `{ value }` merged into the payload. The `value` has the kind the control reports: text for fields, pickers and date pickers (dates are ISO 8601), a boolean for `toggle`, a number for `slider`. A `segmented` control or `picker` only reports one of its `options` (`[{ "value", "title", "icon"? }]` or plain strings). Other events: `onSubmit` (fields), `onRemove` (`chip`), `onCopy` (`copy-button`), and `onDismiss`, `onConfirm` and `onCancel` on overlays.
- **Common props** on every component: `width`, `height`, `minWidth`, `maxWidth`, `minHeight`, `maxHeight`, `grow`, `align`, `padding`, `background`, `foreground`, `border`, `radius`, `opacity`, `shadow`, `hidden`, `disabled`, `tooltip`, `cursor` (`pointer`). Colors are `accent`, `primary`, `secondary`, `muted`, `success`, `warning`, `danger`, `info`, `purple`, `clear`, the app surfaces `window`, `panel` and `input`, or `#RRGGBB`.
- **Overlays** (`popover`, `sheet`, `alert`, `confirm-dialog`) are shown while their `open` prop is true, so `open` is bound to state and the dismissal event (`onDismiss`, `onCancel`) is where the action sets it back to false. A popover is anchored to its first child and shows the rest as its content; a sheet's children are its content. While an overlay is closed its content is not in the tree, and its events are refused. `menu` takes `menu-item` and `divider` children; `context-menu` takes menu entries plus the content they belong to.
- **Files.** `src` props (`image`, `avatar`, `icon`) name a file inside the plugin folder; `plugin validate` reports a missing file or a path that leaves the folder.

## logic.js

```js
export const initialState = { count: 0, entries: [] };

export const actions = {
  increment(state, payload) {
    state.count += payload.by;
  },
  async load(state, payload, api) {
    state.loading = true;
    state.entries = (await api.call("task.list")).map((task) => ({ id: task.id, title: task.title }));
    state.loading = false;
  }
};
```

Actions mutate `state`; the view re-renders after every turn of JavaScript, including in the middle of an async action, so `loading = true` shows while it waits. `setTimeout`, `setInterval` and `console` are available. `api.call(command, args)` sends any `playhouse-cli` bridge command to the daemon (see `docs/bridge.md`) and resolves with its result. There is no DOM, file access or network module. An action that runs for more than 10 seconds without yielding marks the plugin hung; reloading it starts a fresh copy.

## Developing a plugin

```bash
playhouse-cli plugin new --id my-plugin                 # scaffold into the plugins folder
playhouse-cli plugin validate --id my-plugin            # file and JSON path for every problem
playhouse-plugin-dev "<data>/Plugins/my-plugin"         # run it live, without the app
```

`playhouse-plugin-dev` (beside `playhouse-cli` in `Playhouse.app/Contents/MacOS`) loads the plugin, reloads it whenever its files change, and reads commands on stdin:

| Command | Does |
| --- | --- |
| `view` | Prints the resolved tree, one element per line with its number: `[5] button title="Start" onTap→start` |
| `tap <id>` | Runs element `<id>`'s `onTap` action and returns once it settles; a disabled element refuses |
| `type <id> <text>` | Runs element `<id>`'s `onChange` action with `{ value: <text> }`, read as the control's value kind (`true`/`false` for a toggle, a number for a slider) |
| `fire <id> <event> [json]` | Runs any event of element `<id>` (`onSubmit`, `onConfirm`, …) with `{ value: <json> }` when given; a value of the wrong kind, an option the control doesn't have, or an overlay that isn't open is refused |
| `components` | The component catalog as JSON |
| `state` | The current state as JSON |
| `log [n]` | Console output, exceptions and the `api` call trace |
| `reload` | Load the folder again; state resets to `initialState` |

Add `--json` for one JSON object per reply. `api` calls go to the real daemon, so a plugin under development really reads and changes your tasks. Element numbers match the app: each element's accessibility identifier is `plugin-node-<n>`, and the Catalog's **Show Node IDs** overlays them.

## Where the code lives

- `Playhouse/App/Plugins/Core`: the plugin core (manifest, loader, validator, component catalog, bindings, JavaScriptCore host, session, showcases). It uses only Foundation and JavaScriptCore, and is compiled into the app, the daemon and `playhouse-plugin-dev`.
- `Playhouse/App/Plugins/Renderer`: the SwiftUI renderer, component renderers, plugin windows, the Component Catalog and the Plugins menu (app only).
- `Playhouse/PluginDev`: `playhouse-plugin-dev`.
- `Playhouse/Resources/Showcase`: the Catalog's showcases; adding a component is described in `adding-a-component.md`.
