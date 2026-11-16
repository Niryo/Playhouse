---
name: playhouse-plugin
description: Create, change or fix a Playhouse plugin, a small JavaScript UI built from Playhouse's native atoms whose button sits in one of the app's plugin placements. Use when asked to build a Playhouse plugin or when Add Plugin mode opened this task.
---

# Playhouse plugins

A Playhouse plugin is one folder in the Playhouse plugins folder (the task's
context folder; the developer instructions name it). Playhouse shows its entry
button at its placement, and pressing the button opens the plugin's surface,
rendered from its script.

## 1. Gather what is missing

Before writing anything, make sure you know each of these. Ask the user, in one
message, for any the request leaves open. Don't guess:

- **What it does**: the plugin's purpose and what it shows or changes.
- **Placement**: where its button goes. The task's instructions name the
  placement the user picked. If none was picked, ask which of these:
  - `mainSidebar`: the board's sidebar. It gets no task context.
  - `conversationSidebar`: a section of the task sidebar.
  - `conversationToolbar`: an icon beside the Terminal button.
  - `composerActions`: an icon beside the composer's Skills button.
  - `taskItem`: the bottom row of each task's card on the board, beside
    its pull request controls once the task has started. Room for an icon or a short label.
- **Presentation**: how it opens. Pick one of:
  - `popover`: anchored to the button. Best for small tools.
  - `modal`: a sheet.
  - `sidebar`: a panel that slides in from the right.
  - `page`: a full page over the board or the conversation.
  - `inline`: only at `conversationSidebar` or `taskItem`. No button: the
    plugin renders in place, as a section of the task sidebar like the
    built-in Changes, or in the task card's row like its pull request controls.
- **Name and icon**: a short name and an SF Symbol name for its button.

The name, placement and presentation the user picked when the editor opened are
a starting point, not fixed. When the user later asks to change any of them, or
the icon, update `plugin.json` to match. Keep the plugin id and folder.

## 2. Write the plugin

Create `<plugins folder>/<plugin-id>/`. The plugin id is lowercase words
joined by hyphens, and it is also the folder name. The folder holds two files.

`plugin.json`:

```json
{
  "id": "word-count",
  "name": "Word Count",
  "icon": "textformat.123",
  "placement": "composerActions",
  "presentation": "popover",
  "entry": "index.js",
  "width": 320,
  "height": 200
}
```

`entry`, `width` and `height` are optional. `entry` defaults to `index.js`,
and each presentation picks a size when they are absent.

`index.js` is plain JavaScript, with no JSX, TypeScript, imports or bundler.
It uses these globals:

- `React`, `h` (`React.createElement`), and one constant per atom (`Stack`,
  `Text`, `Button`, …).
- `Playhouse.props`, the placement's context:

  | Placement | Context |
  | --- | --- |
  | Every placement | `plugin` (`{id, name, placement, presentation}`), `app` (`{appearance}`) and `state` (the plugin's saved values, see `Playhouse.setState`) |
  | Conversation placements and `taskItem` | Add `task` (`{id, title, status, provider, isStandaloneChat, scheduleSourceTaskID}`), `repositories` (`[{repositoryPath, worktreePath, branch, isPending, awaitsPullRequest, pullRequest: {number, url, merged} or null}]`), `pastPullRequests` (`[{repositoryPath, number, url, merged}]`) and `contextFolders` |
  | `composerActions` | Adds `composer` (`{draft, selection: {location, length, text}}`) |
  | `conversationSidebar` | Adds `workspace` (`{revision, openDiff: {repository, path, group} or null}`; `revision` grows whenever the task's files may have changed) and `sidebar` (`{collapsed}`, true on the hidden sidebar's narrow rail) |

- `Playhouse.useProps()`, a hook that returns the current props and re-renders
  when they change, such as while the user edits the draft.
- `Playhouse.render(element)`, which mounts the plugin.
- `Playhouse.bridge(command, arguments)`, which returns a Promise and gives
  full access to Playhouse. It runs any bridge command the CLI uses and
  resolves with the command's result. For example, `"task.list"` takes `{}`,
  `"task.get"` takes `{taskID}`, and `"task.create"` takes
  `{title, prompt, roots: [], repositories: []}`. Others include
  `"task.rename"`, `"task.move"`, `"conversation.send"` and `"settings.get"`.
  `"plugin.render"` is refused.
  A failure rejects with an Error that has `code` and `message`.
- `Playhouse.setState(key, value)`, which saves one of the plugin's own values
  (any JSON value; `null` removes it) across launches and returns a Promise.
  The saved values come back as `Playhouse.props.state` in every mounted copy
  of the plugin, so keep a plugin's settings, such as whether a section is
  collapsed, there. It is `Playhouse.bridge("plugin.state.set", {pluginID,
  key, value})`.
- `Playhouse.ui`, for what only the window can do. Each call returns a
  Promise:
  - `close()` closes the surface.
  - `openTask(taskID)` opens a task.
  - `composer.setDraft(text)`, `composer.insertText(text)`,
    `composer.replaceSelection(text)` and `composer.focus()` work on the
    composer, in conversation placements. From `mainSidebar` they reject with
    `unavailable`.
  - `openDiff(entry)` opens the diff view for an entry of
    `"task.changes.list"`, and `refreshWorkspace()` tells the window the
    task's files changed, which bumps `workspace.revision`. Both work in
    conversation placements only.
  - `moveTask(taskID, status)` moves a task to a board column as dragging its
    card does, `resolveConflicts(taskID)` starts resolving its pull request's
    conflicts, and `alert(title, message)` shows an alert. They work only from
    `taskItem`; elsewhere they reject with `unavailable`.
- `Playhouse.on(name, listener)` listens for an app event and returns a
  function that stops listening: `"task.statusChanged"` (`{taskID, from, to}`,
  when the plugin's task moves between board columns), `"app.focus"` (`{}`,
  when Playhouse comes to the front) and `"plugin.stateChanged"`
  (`{pluginID, key, value}`, when a saved value changes). Subscribe in a
  `React.useEffect` and return the stop function from it.
- `Playhouse.throttle(fn, seconds)` returns a function that runs `fn` at once,
  then collapses the calls made while it runs or within `seconds` into one
  trailing call with the latest arguments. Wrap anything an event triggers
  that reaches a rate-limited service, such as GitHub, in it.
- `fetch(url, {method, headers, body, timeout})`, like the web's, for `http`
  and `https` URLs from any placement. It resolves with a response that has
  `ok`, `status`, `statusText`, `url`, `redirected`, `headers.get(name)`,
  `text()` and `json()`; bodies are text, up to 10 MB. An HTTP error status
  still resolves with `ok` false. A request that can't be made rejects with an
  Error whose `code` is `invalid_argument` (not an `http`/`https` URL) or
  `network_error`. Plain `http` only reaches IP addresses and local hosts; use
  `https` for other hosts. While `plugin refresh` validates a plugin, `fetch`
  rejects with `unavailable`, so handle the rejection.
- `setTimeout`, `setInterval`, `console`.

Compose only atoms. Raw strings go only inside a `Text`. The atoms, their props
and their events are listed in the README inside the Playhouse source,
`Playhouse/App/Plugins/README.md` ("Atoms"). When the source isn't available,
run `plugin render` on a small script to learn what an atom accepts. An unknown
prop or atom is reported as an error.

Lean on the atoms' defaults, which match the app's look:

- The surface already shows the plugin's icon and name as a standard header
  with a close button, and pads its content. Don't repeat the plugin's name as
  a title, and don't give the root a `padding` or a fixed `width`; it fills the
  surface (a fixed width wider than the surface is clipped).
- Group related content in a `Panel`: it is padded 12 points, rounded and
  lightly filled by default. A `Stack` is bare: it adds no padding or surface
  unless asked.
- A `Modal` atom given a `title` (and optional `subtitle` and `icon`) draws
  the same standard header with a close button that calls `onDismiss`, and
  pads its content 24 points; a `Popover` pads its content 14 points. Their
  children need no padding Stack.
- Every default can be overridden (`padding`, `inset`, `spacing`), but only do
  so for a reason.

```js
function WordCount() {
  var props = Playhouse.useProps();
  var draft = props.composer ? props.composer.draft : "";
  var words = draft.trim() ? draft.trim().split(/\s+/).length : 0;
  return h(Stack, { spacing: 8, align: "leading" },
    h(Text, { size: 13, weight: "semibold", testID: "count" }, String(words), " words"),
    h(Button, { style: "bordered", testID: "upper", onPress: function () {
      Playhouse.ui.composer.replaceSelection(props.composer.selection.text.toUpperCase());
    } }, h(Text, { size: 11 }, "Uppercase selection")));
}
Playhouse.render(h(WordCount));
```

## 3. Check the draft

Run `playhouse-cli plugin render --file <draft-folder>/<plugin-id>/index.js` and
fix errors. To check how it reacts to app events, add
`--event '@task.statusChanged:{"taskID":"…","from":"In Progress","to":"Review"}'`,
`--event @app.focus` or `--event +<seconds>` (which advances the clock); the
output's `emitted` says how many listeners heard each event. The editor
previews the draft automatically. Tell the user how the
plugin works and let them choose Save in the editor to publish it. Do not edit
the installed plugin or use `plugin refresh` to publish draft changes.
