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
- **Presentation**: how it opens. Pick one of:
  - `popover`: anchored to the button. Best for small tools.
  - `modal`: a sheet.
  - `sidebar`: a panel that slides in from the right.
  - `page`: a full page over the board or the conversation.
- **Name and icon**: a short name and an SF Symbol name for its button.

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
  | Every placement | `plugin` (`{id, name, placement, presentation}`) and `app` (`{appearance}`) |
  | Conversation placements | Add `task` (`{id, title, status, provider, isStandaloneChat}`), `repositories` (`[{repositoryPath, worktreePath, branch}]`) and `contextFolders` |
  | `composerActions` | Adds `composer` (`{draft, selection: {location, length, text}}`) |

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
- `Playhouse.ui`, for what only the window can do. Each call returns a
  Promise:
  - `close()` closes the surface.
  - `openTask(taskID)` opens a task.
  - `composer.setDraft(text)`, `composer.insertText(text)`,
    `composer.replaceSelection(text)` and `composer.focus()` work on the
    composer, in conversation placements. From `mainSidebar` they reject with
    `unavailable`.
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

```js
function WordCount() {
  var props = Playhouse.useProps();
  var draft = props.composer ? props.composer.draft : "";
  var words = draft.trim() ? draft.trim().split(/\s+/).length : 0;
  return h(Stack, { spacing: 8, padding: 12 },
    h(Text, { size: 13, weight: "semibold", testID: "count" }, String(words), " words"),
    h(Button, { style: "bordered", testID: "upper", onPress: function () {
      Playhouse.ui.composer.replaceSelection(props.composer.selection.text.toUpperCase());
    } }, h(Text, { size: 11 }, "Uppercase selection")));
}
Playhouse.render(h(WordCount));
```

## 3. Check and install

1. Run `playhouse-cli plugin render --plugin <plugin-id> [--task <task-id>]`.
   - It renders the plugin headlessly with the real context of `--task`, and
     reports the tree, its errors and any `hostCalls`.
   - Press a button with `--event <testID>:onPress`.
   - Fix every error it reports.
2. Run `playhouse-cli plugin refresh`.
   - It validates every plugin and makes the app reload, so the user sees the
     new button at its placement right away.
   - An invalid plugin is listed with its errors and is not shown.
3. Tell the user where the button is and how to use it. They can delete the
   plugin from the Plugins menu.
