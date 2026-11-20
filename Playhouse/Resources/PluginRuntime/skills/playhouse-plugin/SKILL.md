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
  - `mainSidebar`: the board's sidebar, beside the built-in Scheduled Tasks.
    It gets no task context, but gets the scheduled tasks.
  - `mainSidebarBottom`: a collapsible section at the bottom of the board's
    sidebar, like the built-in Agents info. Its presentation is always
    `section`.
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
  - `section`: only at `mainSidebarBottom`, and the only one there. The app
    draws a collapsible header with the plugin's name and remembers whether
    it is collapsed (`state.collapsed`); render the section's content only.
    Render nothing to hide the section, header included.
  - `headless`: only at `composerActions`. No button and no surface: the
    plugin adds `/` commands to the composer's command menu (see "Slash
    commands" below), works in the background (see "Background work" below),
    or both. Pick it when the user wants a slash command or only background work.
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
and each presentation picks a size when they are absent. `commands`, `events`
and `mcpTools` are optional too (see "Slash commands" and "Background work").

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
  | `mainSidebar` | Adds `schedules` (`{tasks, needsLoginItemsApproval}`): `tasks` is what `"schedule.list"` returns (every scheduled task, soonest first; each task's `schedule` is `{kind: "once" or "recurring", scheduledAt, summary, prompt, paused, lastRunTaskID, …}`), kept live; `needsLoginItemsApproval` is true while macOS waits for the user to allow Playhouse in Login Items |
  | `mainSidebarBottom` | Adds `agents` (`{usage, runningTasks}`): `usage` is what `"usage.get"` returns (`{generatedAt, providers: [{provider, installed, loggedIn, account, plan, loginInProgress, snapshot}]}`), kept live, or null before the first read; `runningTasks` is `{claude, codex}`, each provider's count of running tasks |
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
  - `openTask(taskID)` opens a task. A page stays open behind it, so closing the task returns to the page.
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
  - `composer.setMode(mode)` turns on the composer's `"plan"` mode or opens
    its `"goal"` entry, in conversation placements.
  - `openSkills(focus)` opens the Skills page: `{skillID}`, `{mcpServerID}`, or
    `{signIn: {name, provider}}` to start an agent's sign-in to an MCP server.
    `editPlugin(pluginID)` opens a plugin's editor. Both work in conversation
    placements only.
  - `confirm({title, message, confirm, destructive})` asks the user and
    resolves true when they confirm, false when they cancel. It works on the
    board (`mainSidebar`, `mainSidebarBottom` and `taskItem`) and in
    `composerActions`; elsewhere it rejects with `unavailable`.
  - `openURL(url)` opens an `http` or `https` link in the browser, from any
    placement; any other URL rejects with `invalid_argument`.
  - `newTask({schedule})` opens a new task; with `schedule` `"recurring"` or
    `"once"` its schedule picker is already up. `openLoginItems()` opens Login
    Items in System Settings, where the user allows scheduled runs. Both work
    on the board only; elsewhere they reject with `unavailable`.
- `Playhouse.on(name, listener)` listens for an app event and returns a
  function that stops listening: `"task.statusChanged"` (`{taskID, from, to}`,
  when the plugin's task moves between board columns), `"app.focus"` (`{}`,
  when Playhouse comes to the front) and `"plugin.stateChanged"`
  (`{pluginID, key, value}`, when a saved value changes) and `"app.launched"`
  (`{}`, once per app launch; the first listener added after it still hears
  it). Subscribe in a
  `React.useEffect` and return the stop function from it. These are the mounted
  UI's listeners; work that must happen with no window open belongs in the
  background half (`Playhouse.service.on`, below).
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
- To show a picture (a profile picture, a thumbnail), use the `Image` atom
  with its `url` (`https`, local `http`, `file://` or `data:image/…`) rather
  than `fetch`, whose bodies are text: `h(Image, { url: avatarURL, size: 32,
  circle: true, placeholder: "person.crop.circle", label: name })`. The app
  loads and caches it, and shows the `placeholder` symbol while it loads or
  when it fails. Give it a `label` unless it is decorative.
- To show formatted text (notes, a summary an agent wrote, a README), use the
  `Markdown` atom rather than splitting it into `Text`s: `h(Markdown, { text:
  "# Title\n**bold** and `code`" })`. It renders headings, lists, quotes, code
  blocks, tables, rules and inline bold, italic, code and links; add
  `frontmatter: "table"` or `"hide"` for a file with a leading `---` block.
- `setTimeout`, `setInterval`, `console`.

Compose only atoms. Raw strings go only inside a `Text` or a `Markdown`. The atoms, their props
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

### Slash commands

A plugin can add `/` commands to the composer's command menu. Declare each in
`plugin.json`'s `commands`; a `headless` plugin has only commands, so it needs
at least one:

```json
{
  "id": "notes", "name": "Notes", "icon": "note.text",
  "placement": "composerActions", "presentation": "headless",
  "commands": [
    { "name": "greet", "detail": "Greets the task", "icon": "hand.wave" },
    { "name": "notes", "detail": "Lists the task's notes", "list": true }
  ]
}
```

A command's `name` is lowercase words joined by hyphens and can't be a
built-in command (`mcp`, `plan`, `goal`, `skill`, `login`, `plugin`); `detail`
is the row's second line and `icon` defaults to the plugin's. Then register
each command's handlers in `index.js`, which calls no `Playhouse.render`:

```js
Playhouse.commands.register("greet", {
  run: function () { return { text: "Hello from " + Playhouse.props.task.title + " " }; }
});
Playhouse.commands.register("notes", {
  list: function (request) {
    return Playhouse.bridge("task.get", { taskID: Playhouse.props.task.id }).then(function (task) {
      return { title: "Notes", items: [
        { id: "title", title: "Task title", detail: task.title, keywords: ["heading"],
          buttons: [{ id: "plan", label: "Plan it", icon: "list.bullet" }], data: { text: task.title } }
      ] };
    });
  },
  choose: function (request) { return { text: request.item.data.text + " " }; },
  press: function (request) { return Playhouse.ui.composer.setMode("plan"); }
});
```

Each handler gets one request object and returns a value or a Promise of one:

- `available()` (optional): `false` or `{enabled: false, reason}` greys the
  command out with `reason`.
- `run({filter})`, for a command without `list`, runs when it is chosen.
- `list({filter, complete})`, for a command with `list`, returns the menu
  shown once the command is typed in full: `{title, items, pending, empty,
  noMatch}`. Each item is `{id, title, detail, icon, help, keywords, buttons,
  data}`; the app filters the items by what the user types after the command
  and a space. Set `pending` (a short note such as `"Checking…"`) to have the
  app call `list` again with `complete` true for slower details.
- `choose({item, filter})` runs when an item is chosen, and `press({item,
  button})` when one of its `buttons` (`{id, label, help, icon, text, style:
  "icon" or "bordered", disabled, destructive}`) is pressed.

`run`, `choose` and `press` may return `{text}`, which replaces the typed
command in the draft; otherwise the typed command is removed. Each handler
runs in a fresh copy of the script with the `composerActions` props, so keep
nothing between calls except through `Playhouse.setState`. Check the commands
with `playhouse-cli slash-commands list --task <task-id> --query <name>` and
`playhouse-cli slash-commands run --task <task-id> --command <name> [--item <id>
[--button <id>]]` once the plugin is saved.

### Background work

A plugin can also work in the background, in Playhouse's daemon, whether or not
its window or popover is open: react to app events, call MCP tools, and run an
agent and hear its result. List the events its background half hears in
`plugin.json`'s `events` (`"app.focus"`, `"app.launched"`,
`"task.statusChanged"`, `"plugin.stateChanged"`, `"agent.finished"`); any
presentation may have them. Optionally list the only MCP tools it calls in
`mcpTools` (any other is refused with `permission_denied`):

```json
{ "id": "slack-dms", "name": "Slack DMs", "icon": "bubble.left.and.bubble.right",
  "placement": "mainSidebar", "presentation": "popover",
  "events": ["app.focus", "agent.finished"],
  "mcpTools": ["mcp__claude_ai_Slack__slack_search_public_and_private"] }
```

The same `index.js` holds both halves:

- `Playhouse.service.on(name, handler)` registers a background handler for an
  event the manifest lists. It does nothing in the mounted UI, and
  `Playhouse.render` does nothing in the background, so nothing runs twice.
  The handler gets `{name, payload}` with the payload's fields beside them and
  may return a Promise. Each event runs in a fresh copy of the script with the
  plugin's props (`plugin` and `state`), then is thrown away: keep everything
  between events in `Playhouse.setState`. `Playhouse.bridge` and `fetch` work;
  `Playhouse.ui` calls reject with `unavailable`. `app.focus` runs at most once
  per 20 seconds. A `plugin.stateChanged` reaches only the plugin whose state
  changed, so the two halves talk through state: the background half saves,
  and the popover re-renders from `Playhouse.props.state`.
- `Playhouse.mcp.call(tool, arguments, {provider})` calls an MCP tool (a full
  name such as `mcp__claude_ai_Slack__slack_read_channel`) with no model turn,
  through Claude Code, or Codex with `{provider: "codex"}` (each reaches the MCP
  servers configured for it), and resolves `{content, structuredContent, isError}`. It rejects with
  `unavailable` when Claude Code can't, `tool_failed` with Claude Code's
  message, or `timeout`.
- `Playhouse.agent.run({prompt, provider, model, allowedTools, jsonSchema,
  context, cwd})` starts an agent in the background, Claude Code by default or
  Codex with `provider: "codex"` (use that provider's model names; Codex runs
  read-only and ignores `allowedTools`), and resolves `{runID}` at once; it
  needs `"agent.finished"` in `events`. When it ends, the background
  half hears `agent.finished` with `{runID, status: "done", "failed" or
  "cancelled", result, error, context}`: `result` is the `jsonSchema`'s
  structured output, or the final text without one, and `context` is the small
  JSON value you passed, unchanged, so the handler knows what the run was for
  (`{kind: "slack-task", userId}`). A run cut off by Playhouse quitting ends
  `failed` with the error `"interrupted"`. `Playhouse.agent.cancel(runID)` stops
  one.

```js
Playhouse.service.on("app.focus", async function () {
  var res = await Playhouse.mcp.call("mcp__claude_ai_Slack__slack_search_public_and_private", { query: "to:me" });
  await Playhouse.setState("people", res.content.map(function (block) { return block.text; }));
});
Playhouse.service.on("agent.finished", async function (e) {
  if (e.context.kind !== "slack-task" || e.status !== "done") return;
  await Playhouse.bridge("task.create", { title: e.result.title, prompt: e.result.prompt, roots: [], repositories: [] });
});
```

Check the background half with `playhouse-cli plugin service --file
<draft-folder>/<plugin-id>/index.js --event app.focus` (repeat `--event`; give
a payload as `--event 'agent.finished:{"runID":"r1","status":"done","result":{…},"context":{…}}'`).
It reports the handlers' bridge calls, the state they wrote and their errors.
`mcp.call` and `agent.run` reject with `unavailable` there unless you fake
them with `--mock 'mcp.call={"content":[…]}'`, `--mock
'mcp.call:<tool>={…}'` or `--mock 'agent.run={"runID":"r1"}'`; `plugin render`
takes the same `--mock`.

## 3. Check the draft

Run `playhouse-cli plugin render --file <draft-folder>/<plugin-id>/index.js` and
fix errors. To check how it reacts to app events, add
`--event '@task.statusChanged:{"taskID":"…","from":"In Progress","to":"Review"}'`,
`--event @app.focus` or `--event +<seconds>` (which advances the clock); the
output's `emitted` says how many listeners heard each event. The editor
previews the draft automatically. Tell the user how the
plugin works and let them choose Save in the editor to publish it. Do not edit
the installed plugin or use `plugin refresh` to publish draft changes.
