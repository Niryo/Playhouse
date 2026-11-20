import Foundation

/// Who a Playhouse CLI command is for. `playhouse help --for <audience>` lists only that
/// agent's commands, and each agent's instructions point it there instead of listing commands.
/// The CLI, the daemon and the app each compile this file.
enum CLIAudience: String, CaseIterable {
    /// The standalone chat, which manages the board for the user.
    case chat
    /// A read-only side chat beside a task's conversation. `SideChatReadOnlyPolicy` lets it
    /// run exactly these commands, so this audience is also its permission list.
    case sideChat = "side-chat"
    /// A task's own agent.
    case task
    /// The agent of the standalone plugin editor.
    case pluginEditor = "plugin-editor"
}

/// One CLI command: what the parser accepts and what `help` shows for it.
struct CLICommand {
    /// The command words, such as `task create`. A word may list alternatives that share the
    /// rest of the declaration, as in `schedule clear|pause|resume|run-now`.
    let path: String
    /// Everything after the command words.
    let arguments: String
    /// One line on what the command does.
    let summary: String
    /// The agents whose help lists it. Empty for an internal command, which the app, the
    /// daemon or the scheduler runs: help lists it for people and marks it internal.
    let audiences: Set<CLIAudience>

    /// Each word's alternatives.
    var words: [[String]] { path.split(separator: " ").map { $0.split(separator: "|").map(String.init) } }
    var group: String { words[0][0] }
    var usage: String { arguments.isEmpty ? path : "\(path) \(arguments)" }
    var isInternal: Bool { audiences.isEmpty }

    /// Every command the path spells out: `schedule clear`, `schedule pause`, and so on.
    var expandedPaths: [String] {
        words.reduce([""]) { paths, alternatives in
            paths.flatMap { path in alternatives.map { path.isEmpty ? $0 : "\(path) \($0)" } }
        }
    }

    /// Whether `args` start with this command's words.
    func matches(_ args: [String]) -> Bool { matchesPrefix(args, length: words.count) }

    /// Whether the first `length` words of `args` match this command's first words.
    func matchesPrefix(_ args: [String], length: Int) -> Bool {
        guard length <= words.count, args.count >= length else { return false }
        return zip(words.prefix(length), args.prefix(length)).allSatisfy { $0.contains($1) }
    }
}

/// The Playhouse CLI's commands, declared once. The CLI accepts only a command declared here
/// and `help` prints these declarations, so a command can't exist without its help entry.
/// Agent instructions describe behavior and send agents to `help --for <audience>` for
/// capabilities, so a new command reaches the agents in its audiences with no other change.
enum CLICommandCatalog {
    /// The name help and usage messages use for the CLI.
    static let name = "playhouse"

    private static let all = Set(CLIAudience.allCases)
    /// The board as an agent that manages it sees it: the standalone chat and a task's agent.
    private static let board: Set<CLIAudience> = [.chat, .task]
    /// The read-only board commands a side chat can also run.
    private static let readBoard: Set<CLIAudience> = [.chat, .sideChat, .task]
    private static let chat: Set<CLIAudience> = [.chat]
    private static let task: Set<CLIAudience> = [.task]
    private static let plugin: Set<CLIAudience> = [.pluginEditor, .task]
    private static let internalUse: Set<CLIAudience> = []

    private static func command(_ path: String, _ arguments: String, _ summary: String, _ audiences: Set<CLIAudience>) -> CLICommand {
        CLICommand(path: path, arguments: arguments, summary: summary, audiences: audiences)
    }

    static let commands: [CLICommand] = [
        command("help", "[<group> ...] [--for <\(CLIAudience.allCases.map(\.rawValue).joined(separator: "|"))>]",
                "Show these commands; name a group (also `<group> --help`) or an audience to narrow the list.", all),
        command("status", "", "Show that the bridge daemon answers, with its version and process ID.", board),
        command("version", "", "Show the installed Playhouse version, build and release channel.", all),

        command("board list", "", "List every task on the board.", board),
        command("task list", "", "List every task with its ID, title, status and repositories.", readBoard),
        command("task get|show", "<task-id>", "Show one task: status, description, repositories, worktrees, pull requests and schedule.", readBoard),
        command("task create", "--title <title> --prompt <text> [--root <path>...] [--provider <codex|claude>]",
                "Create a task in Backlog with its full description; --root adds a context folder. Creating a task does not start it.", readBoard),
        command("task create", "--title <title> --prompt <text> --repo <path> [--repo <path>...] [--branch <repo-path>=<name>] [--branch-from <repo-path>=<ref>] [--merge-target <repo-path>=<local-branch>] [--provider <codex|claude>]",
                "Create a task that works in repositories, each checked out into its own worktree.", readBoard),
        command("task rename", "<task-id> --title <title>", "Rename a task.", readBoard),
        command("task prompt", "<task-id> --text <prompt>", "Replace a task's saved description without starting it.", readBoard),
        command("task prompt", "<task-id> --text <prompt> --status \"In Progress\" --submitted true", "Save a task's description and start the task with it.", board),
        command("task move", "<task-id> <Backlog|In Progress|Blocked|Waiting Response|Review|Done> [--allow-unmerged]",
                "Move a task to another column. Done archives it and removes its worktrees; --allow-unmerged allows that with an unmerged pull request.", board),
        command("task move", "<task-id> Done --discard-changes", "Move a task to Done although its worktrees have uncommitted changes, discarding them.", task),
        command("task delete", "<task-id>", "Delete a task with its conversation and worktrees.", chat),
        command("task delete-check", "<task-id>", "Report whether deleting a task needs the user's confirmation.", internalUse),
        command("task token-usage", "<task-id>", "Show a task's token usage by turn and tool.", board),
        command("task token-waste", "<task-id>", "Show where a task's tokens went on repeated or cache-missed input.", board),
        command("task cpu-usage", "<task-id>", "Show the CPU time a task's agents used.", board),
        command("task raw-input", "<task-id> [--agent <id>] [--scope final|all|request] [--request <n>] [--order transcript|size|rent] [--query <text>] [--offset <n>] [--limit <n>] [--focus <item>]",
                "List the raw input items a task sent its provider.", internalUse),
        command("task raw-input-export", "<task-id> [--agent <id>] [--request <n>] [--format text|json]", "Export a task's raw provider input.", internalUse),
        command("task raw-input-text", "<task-id> --item <n> [--agent <id>] [--offset <n>] [--length <n>]", "Read one raw provider input item's text.", internalUse),
        command("task draft", "<task-id> --text <draft> [--image <path>...]", "Save the composer draft: its text and every attached image.", internalUse),
        command("task comments", "<task-id> --json <comments-array> [--append]",
                "Save unsent review comments with the draft; [] clears them and --append adds only new ones.", internalUse),
        command("task comments", "<task-id> edit <comment-id> --text <text>", "Change an unsent comment; empty text deletes it.", internalUse),
        command("task roots get|set", "<task-id> [--root <path>...]", "Read or replace a task's context folders.", internalUse),
        command("task terminal", "<task-id>", "Open a terminal in the task's workspace.", internalUse),
        command("task changes list", "<task-id>", "List the task's changed files and whether each was viewed.", internalUse),
        command("task changes diff", "<task-id> --repository <path> --path <relative-path> --group <unviewed|viewed>", "Show one changed file's diff.", internalUse),
        command("task changes mark-viewed|mark-unviewed", "<task-id> --repository <path> --path <relative-path>", "Mark one changed file viewed or unviewed.", internalUse),
        command("task changes mark-all-viewed", "<task-id>", "Mark every changed file viewed.", internalUse),
        command("task title", "<task-id> --prompt <text>", "Generate a task title from a prompt.", internalUse),
        command("task reconcile", "<task-id>", "Reconcile a task's stored turn state with its provider.", internalUse),

        command("task progress publish", "<task-id> --type <planning|searching|building|running|testing|reviewing|writing|committing> [--detail <text>]",
                "Show what the task's agent is doing on its card.", task),
        command("task progress custom", "<task-id> --label <label> [--detail <text>]", "Show a custom progress label on the task's card.", task),
        command("task progress clear", "<task-id>", "Clear the task's progress report.", task),
        command("task outcome", "<task-id> <completed|waiting-response|blocked> [--reason <text>]",
                "Report how the turn ended: completed moves the task to Review, blocked (which needs --reason) to Blocked.", task),

        command("task repository add", "<task-id> --repo <path>", "Add a repository to a task, creating its worktree.", task),
        command("task repository add-batch|replace", "<task-id> --repo <path> [--repo <path>...]", "Add several repositories, or replace the task's repositories.", task),
        command("task repository add-worktree", "<task-id> --repo <path> [--branch <name>] [--branch-from <ref>]",
                "Add another worktree, on its own new branch, of a repository the task already has.", task),
        command("task repository edit", "<task-id> (--repo <path>|--worktree <path>) --branch <name> --branch-from <ref> [--merge-target <ref>]",
                "Change a worktree's branch, base and merge target before it starts.", task),
        command("task repository remove", "<task-id> (--repo <path>|--worktree <path>) [--worktree-branch <branch>]",
                "Remove a repository's worktree from the task; with several worktrees of one repository, pass --worktree.", task),
        command("task repository renew", "<task-id> (--repo <path>|--worktree <path>) [--worktree-branch <branch>]",
                "After a worktree's pull request merged, start a fresh worktree from the latest merge target.", task),
        command("task repository recent", "<task-id>", "List repositories recently used with tasks.", internalUse),

        command("task pr create", "<task-id> [--if-needed] [--title <title>] [--body <text>]", "Open pull requests for the task's worktrees.", task),
        command("task pr link", "<task-id> (--worktree <path>|--repo <path>) --url <pr-url>",
                "Register a pull request opened outside Playhouse; its head must be the worktree's branch.", task),
        command("task pr status", "<task-id> [--review-threads] [--shared]", "Show the task's pull requests, their checks and, with --review-threads, review threads.", board),
        command("task pr verify|sync|conflicts", "<task-id>", "Verify, refresh, or check for conflicts the task's pull requests.", board),
        command("task pr resolve", "<task-id> <resolve-and-push|resolve-only|keep>", "Act on the task's pull request conflicts.", internalUse),
        command("task pr autopilot", "<task-id> [--merge] [--reset-attempts] [--confirm-with <plugin-id>]",
                "Run one pass of pull request autopilot: keep the task's pull requests green, and merge them with --merge.", task),

        command("schedule list", "", "List scheduled tasks and when each runs next.", board),
        command("schedule set", "<task-id> --prompt <text> --once <ISO8601> [--title <title>] [--image <path>...] [--mode default|plan] [--model <id>]",
                "Schedule a task to start once with this prompt, at a time such as 2026-11-20T09:00:00+02:00. Create the task first.", board),
        command("schedule set", "<task-id> --prompt <text> --repeat <hourly|daily|weekdays|weekly> --title <title> [--time HH:MM] [--minute MM] [--weekday mon] [--image <path>...] [--mode default|plan] [--model <id>]",
                "Start a task with this prompt on a repeating schedule, at local time; a repeating task needs a title.", board),
        command("schedule set", "<task-id> (--once <ISO8601> | --repeat <hourly|daily|weekdays|weekly> [--time HH:MM] [--minute MM] [--weekday mon])",
                "Without --prompt, move a scheduled task's next run and keep its saved prompt.", board),
        command("schedule clear|pause|resume|run-now", "<task-id>", "Remove, pause, resume, or immediately run a task's schedule.", board),
        command("schedule tick", "[--now <ISO8601>]", "Start every scheduled task that is due; the scheduler runs this each minute.", internalUse),

        command("chat open", "", "Open the standalone chat in the app.", internalUse),
        command("chat status", "", "Show the standalone chat's turn state.", internalUse),
        command("chat page list", "[--limit <n>] [--title <text>]", "List the chat's pages, newest first.", chat),
        command("chat page search", "<query>", "Search the chat's pages.", chat),
        command("chat page read", "<page-id>", "Load one page's messages.", chat),
        command("chat page new", "--title <title>", "Start a new page; close-turn starts one itself when the topic changes.", internalUse),
        command("chat page close-turn", "<chat-id> --continues <true|false> [--new-title <title>] [--summary-hint <text>]",
                "File this turn under the current page, or under a new titled page.", chat),

        command("workspace repos list", "", "List the repositories under the configured repository root.", readBoard),
        command("workspace suggest", "--parent <path>", "Suggest repository folders under a parent folder.", internalUse),

        command("plugin mode", "[--on|--off]", "Show or set Add Plugin mode, in which the user picks where a new plugin's button goes.", chat),
        command("plugin list", "", "List installed plugins.", [.chat, .task, .pluginEditor]),
        command("plugin enable|disable|delete", "--id <plugin-id>", "Enable, disable, or delete an installed plugin.", chat),
        command("plugin state", "--id <plugin-id> [--key <key> --value <json>]", "Read a plugin's saved state, or set one key (null removes it).", plugin),
        command("plugin event", "<task.statusChanged|app.focus|plugin.stateChanged|app.launched|agent.finished> [--payload <json>]", "Send an app event to plugins.", plugin),
        command("plugin render", "(--file <plugin.js> | --page <catalog-page> | --plugin <plugin-id> [--task <task-id>]) [--props <json>] [--event <testID>:<event>[:<value>] | @<app-event>[:<json>] | +<seconds>...] [--advance <seconds>] [--mock <command>[:<tool>]=<json>...]",
                "Render a plugin without the app and report its node tree and errors.", plugin),
        command("plugin service", "(--file <index.js> | --plugin <plugin-id>) --event <name>[:<json payload>]... [--props <json>] [--mock <command>[:<tool>]=<json>...]",
                "Run a plugin's background handlers for events and report their bridge calls, state writes and errors.", plugin),
        command("plugin services", "", "List the plugins with a background half and the events each hears.", internalUse),
        command("mcp call", "--tool <mcp__server__tool> [--arguments <json>] [--plugin <plugin-id>] [--provider <claude|codex>] [--timeout <seconds>]",
                "Call an MCP tool directly through Claude Code or Codex, with no model turn.", plugin),
        command("agent run", "--plugin <plugin-id> --prompt <text> [--provider <claude|codex>] [--model <model-id>] [--allowed-tool <tool>...] [--json-schema <json>] [--context <json>] [--cwd <path>]",
                "Start a plugin's background agent; its service hears agent.finished.", plugin),
        command("agent cancel", "--plugin <plugin-id> --run <run-id>", "Stop a plugin's background agent.", plugin),
        command("agent runs", "[--plugin <plugin-id>]", "List plugins' background agents that are still running.", plugin),
        command("plugin refresh|sessions", "", "Reload plugins from disk, or list open plugin editor sessions.", internalUse),
        command("plugin edit|save|discard|versions", "--id <plugin-id>", "Open, save, discard, or list versions of a plugin's editor draft.", internalUse),
        command("plugin restore", "--id <plugin-id> --version <n>", "Restore a saved plugin version into its draft.", internalUse),
        command("plugin author", "--placement <mainSidebar|conversationSidebar|conversationToolbar|composerActions|taskItem> [--provider <codex|claude>] [--name <name> --presentation <popover|modal|sidebar|page|inline>]",
                "Start authoring a new plugin at a placement.", internalUse),

        command("conversation history", "<task-id> [--limit <messages>] [--before <message-id> | --after <message-id> | --page <chat-page-id>] [--defer-images] [--include-task]",
                "Read a task's conversation; --include-task also returns the task as the read reconciled it.", board),
        command("conversation outline", "<task-id>",
                "Map a task's conversation by position: each turn's user message, its agent messages and tool calls, and its final answer.", readBoard),
        command("conversation read", "<task-id> [--at <position>[,<position>...]] [--from <position>] [--to <position>] [--kinds <user,steer,agent,final,plan,subagent,playhouse,tool>] [--include-tools]",
                "Read entries of a task's conversation by position: whole numbers are messages, decimals (12.3) are the tool calls after message 12.", readBoard),
        command("conversation send", "<task-id> --message <text> [--image <path>]... [--mode <default|plan>] [--model <model-id>] [--answer <question-id>=<answer>...] [--context-page <page-id>]... [--defer-images]",
                "Send a message to a task's agent, starting a turn; prints JSON event lines and then a final response.", chat),
        command("conversation queue", "<task-id> --message <text> [--image <path>]...", "Queue a message to send when the task's current turn ends.", chat),
        command("conversation queue-list", "<task-id>", "List a task's queued messages.", chat),
        command("conversation queue-retry|queue-remove|queue-steer", "<task-id> <message-id>", "Retry, remove, or steer with a queued message.", internalUse),
        command("conversation steer", "<task-id> --message <text> [--image <path>]...", "Add a message to the task's running turn.", chat),
        command("conversation stop", "<task-id>", "Stop the task's running turn.", chat),
        command("conversation models", "<task-id> [--cached]", "List the models the task's provider offers; --cached reads the last saved list.", chat),
        command("conversation model", "<task-id> [set <model-id>]", "Show or set the task's model.", chat),
        command("conversation effort", "<task-id> [set <low|medium|high|xhigh>]", "Show or set the task's reasoning effort.", chat),
        command("conversation context-mode", "<task-id> [set <full|optimized>]",
                "Show or set whether the task's follow-ups resume the whole conversation (full) or start fresh, seeded sessions (optimized).", chat),
        command("conversation provider", "<task-id> [set <codex|claude>|capabilities]", "Show or set the task's provider, or show what it supports.", chat),
        command("conversation goal", "<task-id> <get|set|pause|resume|clear> [--text <objective>]", "Manage a Codex task's goal.", chat),
        command("conversation present-image", "<task-id> --image <path> [--caption <text>]", "Show an image in the task's conversation.", task),
        command("conversation images", "<task-id> --message <message-id> [--message <message-id>]...", "Load images deferred from history.", internalUse),
        command("conversation runtime|cpu-usage", "[--watch]", "Show which turns are running, or their CPU use.", internalUse),
        command("conversation watch", "<task-id>", "Stream a task's conversation events.", internalUse),
        command("conversation answered-async", "<task-id>", "List asynchronous questions already answered.", internalUse),
        command("conversation answer-async", "<task-id> <item-id> --answer <text> [--answer <text>]...", "Answer an asynchronous question.", internalUse),
        command("conversation answer-user-input", "<task-id> <request-id> --answer <question-id>=<answer> [--answer <question-id>=<answer>]...", "Answer an agent's question.", internalUse),
        command("conversation repair-user-input", "<task-id> --from-task <source-task-id>", "Repair a question's answers from another task.", internalUse),
        command("conversation subagent-history", "<task-id> --activity <activity-json>", "Read a subagent's history.", internalUse),
        command("conversation side-chat", "<task-id> --message <text> (--selection <text> [--source <json>] | --side-chat <side-chat-id>) [--model <model-id>] [--effort <low|medium|high|xhigh>]",
                "Start or continue a side chat about selected text.", internalUse),
        command("conversation side-chats", "<task-id>", "List a task's side chats.", internalUse),
        command("conversation side-chat-close", "<task-id> <side-chat-id>", "Close a side chat's live session.", internalUse),

        command("skills list", "[--task <task-id>] [--include-bundled true]", "List skills: a task's repository skills, global skills and built-ins.", board),
        command("skills get", "--skill <skill-id> [--task <task-id>] [--include-bundled true]", "Read one skill's SKILL.md.", board),
        command("skills create", "--scope <repo|private|global> --name <name> --description <text> [--body <text>] [--field <name>=<value>...] [--task <task-id>] [--root <repo-path>]",
                "Create a skill.", chat),
        command("skills update", "--skill <skill-id> (--content <text>|--content-file <path>|[--description <text>] [--body <text>] [--field <name>=<value>...]) [--task <task-id>]",
                "Change a skill.", chat),
        command("skills move", "--skill <skill-id> --scope <repo|private|global> [--root <repo-path>] [--task <task-id>]", "Move a skill to another scope.", chat),
        command("skills enable|disable|link|unlink", "--skill <skill-id> [--task <task-id>]",
                "Turn a skill on or off in Playhouse sessions, or link it into both providers' layouts or unlink it.", chat),
        command("skills delete", "--skill <skill-id> [--skill <skill-id>...] [--task <task-id>]", "Delete skills.", chat),
        command("skills fix", "--task <task-id> --skill <skill-id> [--skill <skill-id>...]", "Start a task's agent fixing invalid skills.", internalUse),
        command("skills bridge", "--task <task-id> [--message <text>]", "Bridge a task's skills between providers.", internalUse),
        command("rules list", "[--task <task-id>]", "List instruction rules: a task's repository rules and global rules.", board),
        command("rules get", "--rule <rule-id> [--task <task-id>]", "Read one rule.", board),
        command("rules create", "--scope <repo|global> [--name <name>] [--path <glob>...] --body <text> [--task <task-id>] [--root <repo-path>]", "Create a rule.", chat),
        command("rules update", "--rule <rule-id> (--content <text>|--content-file <path>) [--task <task-id>]", "Change a rule.", chat),
        command("rules enable|disable|link|unlink", "--rule <rule-id> [--task <task-id>]", "Turn a rule on or off, or link or unlink it for both providers.", chat),
        command("rules delete", "--rule <rule-id> [--rule <rule-id>...] [--task <task-id>]", "Delete rules.", chat),
        command("rules fix", "--task <task-id> --rule <rule-id> [--rule <rule-id>...]", "Start a task's agent fixing rules.", internalUse),
        command("rules bridge", "--task <task-id>", "Bridge a task's rules between providers.", internalUse),
        command("mcp list", "[--task <task-id>]", "List MCP servers: a task's repository servers and global servers.", board),
        command("mcp get", "--server <server-id> [--task <task-id>]", "Read one MCP server's definition.", board),
        command("mcp status", "[--task <task-id>] [--provider <claude|codex>]", "Show whether each MCP server connects and is signed in.", board),
        command("mcp create", "--scope <repo|global> --name <name> (--command <command> [--arg <arg>...] [--env NAME=value...] | --url <url> [--header \"Name: value\"...] | --config-json <json>) [--task <task-id>] [--root <repo-path>]",
                "Add an MCP server.", chat),
        command("mcp update", "--server <server-id> (--command ... | --url ... | --config-json <json>) [--task <task-id>]", "Change an MCP server.", chat),
        command("mcp enable|disable|link", "--server <server-id> [--task <task-id>]", "Turn an MCP server on or off, or link it for both providers.", chat),
        command("mcp delete", "--server <server-id> [--server <server-id>...] [--task <task-id>]", "Delete MCP servers.", chat),
        command("mcp fix", "--task <task-id> --server <server-id> [--server <server-id>...]", "Start a task's agent fixing MCP servers.", internalUse),
        command("mcp bridge", "--task <task-id>", "Bridge a task's MCP servers between providers.", internalUse),
        command("mcp authenticate|authenticate-wait", "--provider <claude|codex> --name <server-name> [--task <task-id>]", "Sign in to an MCP server, or wait for that sign-in.", internalUse),
        command("mentions list", "--task <task-id> [--query <text>]", "List what the composer's @-mention menu offers.", internalUse),
        command("slash-commands list", "--task <task-id> [--query <text>] [--complete] [--draft <text>]", "List the composer's slash commands.", internalUse),
        command("slash-commands run", "--task <task-id> --command <name> [--item <item-id> [--button <button-id>]] [--confirm] [--draft <text>]", "Run a composer slash command.", internalUse),

        command("settings get", "", "Show Playhouse's settings, such as the repository root and default provider.", board),
        command("settings set-appearance", "<dark|light>", "Set the app's appearance.", chat),
        command("settings set-default-provider", "<codex|claude>", "Set the provider new tasks and chats use.", chat),
        command("settings set-token-usage-color-max", "<tokens>", "Set the token count that colors a task's usage fully.", chat),
        command("settings set-cpu-usage-color-max", "<percent>", "Set the CPU percentage that colors a task's usage fully.", chat),
        command("settings set-status-sounds", "<on|off>", "Turn status change sounds on or off.", chat),
        command("settings set-auto-compaction", "[--enabled <true|false>] [--idle-minutes <minutes>] [--minimum <tokens>]", "Configure automatic context compaction of idle tasks.", chat),
        command("settings set-parent", "<path>", "Set the repository root folder.", chat),
        command("settings clear-parent", "", "Clear the repository root folder.", internalUse),
        command("settings set-last-repositories", "--repo <path>...", "Remember the repositories the next new task starts with.", internalUse),
        command("usage get", "[--refresh|--watch]", "Show Codex and Claude account usage and limits.", chat),
        command("usage login|switch-account", "<codex|claude>", "Sign in to a provider, or switch its account.", internalUse),
        command("archive search", "<query>", "Search archived Codex conversations.", internalUse),

        command("update status", "", "Show the app update's state.", chat),
        command("update check", "[--automatic true]", "Check for an app update.", chat),
        command("update download|cancel|launched|dismiss-notice", "", "Download an update, cancel it, or record a launch or dismissed notice.", internalUse),
        command("update install", "[--when-idle true]", "Install a downloaded update and relaunch.", internalUse),
        command("update set-auto-check", "<on|off>", "Turn automatic update checks on or off.", internalUse),
        command("update verify-bundle", "--bundle <app> [--replacing <installed app>] [--version <x.y.z>]", "Verify a downloaded app bundle's signature and version.", internalUse),
        command("update apply", "--staged <app> --target <app> --state-dir <path> [--service-name <name>] [--socket-path <path>] [--relaunch-env <NAME=value>...]",
                "Install a staged update; the daemon runs this.", internalUse),
        command("daemon info|shutdown", "", "Show the bridge daemon's details, or stop it.", internalUse),
        command("hook side-chat-pre-tool-use", "", "Claude Code's read-only side chat hook, which reads one tool call on standard input.", internalUse),
    ]

    /// The groups in the order help shows them.
    static var groups: [String] {
        commands.map(\.group).reduce(into: []) { groups, group in if !groups.contains(group) { groups.append(group) } }
    }

    /// The declaration `args` invoke, if any.
    static func command(matching args: [String]) -> CLICommand? {
        commands.first { $0.matches(args) }
    }

    /// Whether the CLI declares this path or one of its alternatives.
    static func declares(_ path: String) -> Bool {
        commands.contains { $0.path == path || $0.expandedPaths.contains(path) }
    }

    /// `executable <path>` for a declared command path, such as `task progress clear`. Agent
    /// instructions build their protocol commands with it; a debug build stops on a path the
    /// CLI doesn't declare, and the CLI's unit checks cover every path the instructions use.
    static func invocation(_ path: String, executable: String) -> String {
        assert(declares(path), "The CLI declares no command \(path).")
        return "\(executable) \(path)"
    }

    /// The commands `help` lists for the leading command `words` and `audience`.
    static func commands(selecting words: [String], for audience: CLIAudience?) -> [CLICommand] {
        commands.filter { command in
            (words.isEmpty || command.matchesPrefix(words, length: words.count))
                && (audience.map { command.audiences.contains($0) } ?? true)
        }
    }

    /// The help for `help [<words>...] [--for <audience>]`; `executable` is the CLI's path.
    static func helpText(selecting words: [String], for audience: CLIAudience?, executable: String) -> String {
        let selected = commands(selecting: words, for: audience)
        let scope = words.isEmpty ? "" : " \(words.joined(separator: " "))"
        var lines = [
            "Playhouse CLI\(scope) commands\(audience.map { " for the \($0.rawValue) audience" } ?? ""). `\(name)` stands for this CLI: \(executable)",
            "Run `\(name) help <group>` or `\(name) <group> --help` for one group, and add `--for <\(CLIAudience.allCases.map(\.rawValue).joined(separator: "|"))>` for the commands one agent can use.",
            "Results are JSON. Conversation commands use the task's provider; tasks without one use Codex.",
        ]
        if selected.isEmpty {
            lines.append("")
            lines.append("No\(scope) commands are available\(audience.map { " to the \($0.rawValue) audience" } ?? "").")
        }
        for group in groups {
            let entries = selected.filter { $0.group == group }
            guard !entries.isEmpty else { continue }
            lines.append("")
            lines.append("\(group):")
            for entry in entries {
                lines.append("  \(name) \(entry.usage)")
                lines.append("      \(entry.summary)\(entry.isInternal ? " (internal)" : "")")
            }
        }
        if audience == nil, selected.contains(where: \.isInternal) {
            lines.append("")
            lines.append("Internal commands are run by the Playhouse app, its daemon or its scheduler; agents never need them.")
        }
        return lines.joined(separator: "\n")
    }
}
