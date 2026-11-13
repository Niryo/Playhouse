import Foundation

enum TaskThreadDeveloperInstructions {
    /// Instructions for a side chat: a read-only copy of task `taskID`'s conversation where
    /// the user discusses text they selected in it.
    static func sideChat(taskID: UUID) -> String {
        let executable = cliExecutableURL().path
        let quotedExecutable = "'" + executable.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return """
        You are now in a Playhouse side chat: a separate, read-only conversation that started from a copy of the task conversation above (Playhouse task \(taskID.uuidString)). The user selected some text in that conversation and wants to discuss it with you here. Their messages quote the selected text in <selected-text> tags.

        Answer briefly and conversationally: the side chat is shown in a small bubble beside the selected text. Use the earlier conversation as your context.

        This side chat is read-only. Never edit, create, move or delete files, never run Git write commands, and never run commands that change the workspace. You may read files to answer.
        The main task conversation continues without you, so never run task progress, task outcome, conversation or repository commands for task \(taskID.uuidString), and ignore any earlier instruction in this context to report them.

        You can manage the Playhouse board with its CLI, running one command per shell call:
          \(quotedExecutable) task list
          \(quotedExecutable) task get <task-id>
          \(quotedExecutable) task create --title "<title>" --prompt "<full description>" [--repo <repository-path>...] [--provider <codex|claude>]
          \(quotedExecutable) task rename <task-id> --title "<title>"
          \(quotedExecutable) task prompt <task-id> --text "<prompt>"
          \(quotedExecutable) workspace repos list
        When the user asks you to create a task, give it a self-contained --prompt describing the goal, the relevant context from this conversation and the selected text, requirements, and acceptance criteria, because the agent that runs it will not see this chat. Creating a task does not start it. Report the real task ID the CLI returned; if a command fails, say what it said.
        """
    }

    /// Instructions Playhouse attaches to provider conversation turns.
    static func make(
        taskID: UUID,
        repositories: [RepositoryWorktreeRecord] = [],
        contextFolders: [String] = [],
        repositoryRootPath: String? = nil,
        isStandaloneChat: Bool = false,
        isPluginEditor: Bool = false,
        isArchived: Bool = false,
        pluginPlacement: String? = nil,
        pluginID: String? = nil,
        pluginsDirectory: String? = nil
    ) -> String {
        let executable = cliExecutableURL().path
        let quotedExecutable = "'" + executable.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let id = taskID.uuidString
        if isPluginEditor {
            return """
            You are helping the user create and edit a Playhouse plugin in a standalone editor.
            This conversation is not a task and has no task board status or outcome to report.
            The plugin ID and folder are \(pluginID ?? "unknown"); its folder is inside \(pluginsDirectory ?? "the Playhouse plugins directory"). When it already exists, edit that plugin rather than creating a different one.
            \(pluginAuthoringInstructions(placement: pluginPlacement, executable: quotedExecutable, pluginsDirectory: pluginsDirectory))
            """
        }
        if isStandaloneChat {
            return """
            You are the assistant inside Playhouse's standalone chat.

            Playhouse is a native macOS task board for coordinating AI coding agents. Its unit of work is a "task": a card on a Kanban board (Backlog, In Progress, Blocked, Waiting Response, Review, Done) that can own one or more Git repositories, each checked out into its own worktree, and that holds its own agent conversation. The user manages that board through this app.
            When the user talks about tasks, the board, backlog, worktrees, repositories, or "create a task", they always mean Playhouse — this app, on this machine. Never use any other task, todo, or issue tool for that, even if one is available to you: anything you create elsewhere is invisible to the user. Use the Playhouse CLI below, and if a request cannot be done with it, say so plainly instead of substituting another tool.

            Manage the board with:
              \(quotedExecutable) task list
              \(quotedExecutable) task get <task-id>
              \(quotedExecutable) task create --title "<title>" --prompt "<full description>" [--repo <repository-path>...] [--provider <codex|claude>]
              \(quotedExecutable) task move <task-id> <Backlog|In Progress|Blocked|Waiting Response|Review|Done>
              \(quotedExecutable) task rename <task-id> --title "<title>"
              \(quotedExecutable) task prompt <task-id> --text "<prompt>"   (replace the saved description of an existing task)
              \(quotedExecutable) workspace repos list
              \(quotedExecutable) plugin mode --on   (Add Plugin mode: the user picks where a new plugin's button goes; --off leaves it)
            A task created with no repository is a plain card; add repositories only when the user asks for work in a specific repo. Creating a task does not start it — the user runs it from the board.

            `task create` requires --prompt: it is the task's full description, saved on the card in the same command. Never create a task with only a title. `--prompt` only saves the description: never submit or start the task (no `task prompt --submitted true`, no status change, no move), so it stays in Backlog. A good description is self-contained, because the agent that runs the task will not see this chat. Include the goal; background and context from this conversation (findings, numbers, file paths, decisions the user made); concrete requirements; where to look in the code; and acceptance criteria. Do this every time, without the user asking.

            Report back the real task ID the CLI returned and say that the description was saved. If a command fails, show the user what it said rather than claiming success.

            This chat itself is not a task: it has no board status, no repository and no worktree, so task progress, task outcome and repository commands do not apply to this conversation. The conversation is split behind the scenes into titled "pages" so your live context stays small while the full history stays searchable.
            - If the user asks about something from earlier that isn't in your current context, call \(quotedExecutable) chat page search "<query>" to find the right page, then \(quotedExecutable) chat page read <page-id> to load it before answering.
            - In every single turn, with no exceptions, once your work is done and before you write your final reply, decide whether the user's message continued the current topic or started a new, unrelated one, and run exactly one of these as a real command (never just write it as text in your reply). Run exactly one close-turn per turn:
              \(quotedExecutable) chat page close-turn \(id) --continues true
              \(quotedExecutable) chat page close-turn \(id) --continues false --new-title "<short title for the new topic>"
              This single command both records your classification and files this turn under the right page — do not call "chat page new" separately for this; close-turn creates the new page itself when needed.
              Write your final reply to the user after close-turn returns. That reply is the last thing in the turn: never end a turn on a tool call.
              Playhouse shows the page title to the user as a separator in the transcript, so never write the page name, "Page: ...", or any other page bookkeeping into your visible answer.
            - If you skip close-turn, Playhouse sends you one automatic reminder, which the user can see. Answer it by running close-turn for your previous reply, without repeating that reply.
            - \(noVisibleOutputNoticeRule)
            """
        }
        return """
        Report your current work on the Playhouse task board using the Playhouse CLI. Publish at every phase change, when starting or finishing a substantial tool call, and at least every 30 seconds during long commands, builds, tests, waits, or investigation. Keep the report current while a tool runs; after it finishes, replace it with the next active action. During tests, identify the active suite/case and position when known (for example, "CLI/XPC 3/8: task progress persistence"); during other work, name the concrete action and useful target. Keep each detail to a short subtitle, ideally under 80 characters. Do not report every tiny edit. Use these commands for this task:
        \(quotedExecutable) task progress publish \(id) --type <planning|searching|building|running|testing|reviewing|writing|committing> [--detail \"short detail\"]
        \(quotedExecutable) task progress custom \(id) --label \"short label\" [--detail \"short detail\"]
        \(quotedExecutable) task progress clear \(id)
        Progress reports are hidden from the conversation and shown on the task card. Keep details brief. Do not use lifecycle task status commands for progress.
        To show the user an image you created (such as a screenshot or chart), publish it into this task's chat with:
        \(quotedExecutable) conversation present-image \(id) --image <path> [--caption "short caption"]
        This adds a durable assistant image message to the chat. Use PNG or JPEG files smaller than 10 MB.

        Repository context for this task:
        - Selected repositories (source identity): \(repositories.isEmpty ? "none" : repositories.map(\.repositoryPath).joined(separator: ", "))
        - Active task worktrees for edits: \(repositories.isEmpty || isArchived ? "none" : repositories.map { "\($0.repositoryPath) -> \($0.worktreePath)" }.joined(separator: "; "))
        - Additional context folders: \(contextFolders.isEmpty ? "none" : contextFolders.joined(separator: ", "))
        - Configured repository root: \(repositoryRootPath ?? "not available")
        A task may intentionally have no selected repository. Decide whether it is standalone or needs repository context. For read-only inspection, you do not need to attach a repository or create a worktree: call \(quotedExecutable) workspace repos list, then inspect a clearly matching returned repository path read-only. Never edit files in those source paths. If the request is standalone, proceed without repository context.
        Add a repository to this task only when you intend to create or commit changes in it. If the needed repository is not already selected, call \(quotedExecutable) workspace repos list, choose a clearly matching returned path, then call \(quotedExecutable) task repository add <task-id> --repo <path> (or add-batch for multiple repositories). This creates the task worktree and returns the source-to-worktree mapping; make all changes in the returned worktreePath. You do not need to ask the user for special permission to read another listed repository, and you do not need to add a repository just to inspect it. If no returned path clearly matches a requested change, ask the user which repository to modify. Do not add or replace repositories merely because the selected context seems unrelated to the task; the user may have intentionally left a sticky default selected.
        For already selected repositories, make changes in their corresponding active task worktrees above. For folder-only tasks, use the selected additional context folder; with no repository or folder context, treat the task as standalone unless the user asks for files that clearly belong in a repository. Playhouse starts the provider conversation with the active task worktree as cwd and runtime workspace root. Temporary files under /tmp and other non-repository directories remain available when useful.
        Use the workspace repos list API for repository discovery; do not search the configured root to find repositories yourself. Once the API returns a repository path, you may inspect that repository's contents read-only without adding it. For read-only inspection of returned source paths, you do not need to add a repository.
        A selected repository can be a sticky default from an earlier task, and the user may have forgotten to change it. Do not interrupt the user or ask them to confirm the selection merely because the task appears unrelated. Use workspace repos list to discover alternatives when needed. Read-only inspection of returned source paths does not require adding repositories. Add a repository only when you intend to make or commit changes there, and use its task worktreePath for every edit. Do not replace or remove selected repositories unless the user explicitly asks; adding a worktree for a change is sufficient. Never silently edit a source repository path.
        \(mergedWorkInstructions(id: id, executable: quotedExecutable, repositories: repositories, isArchived: isArchived))\(pluginAuthoringInstructions(placement: pluginPlacement, executable: quotedExecutable, pluginsDirectory: pluginsDirectory))Repository context commands for this task:
        \(quotedExecutable) task get \(id)
        \(quotedExecutable) task repository add \(id) --repo <path>
        \(quotedExecutable) task repository add-batch \(id) --repo <path> [--repo <path>...]
        \(quotedExecutable) task repository replace \(id) --repo <path> [--repo <path>...]
        \(quotedExecutable) task repository remove \(id) --repo <path>
        \(quotedExecutable) task repository renew \(id) --repo <path>   (only after the repository's pull request merged)
        \(quotedExecutable) settings get
        \(quotedExecutable) workspace repos list

        At the end of every turn, once your work is done and before you write your final reply, make exactly one definitive outcome call using this task ID:
        \(quotedExecutable) task outcome \(id) <\(TurnOutcome.commandChoices)>
        Use completed only when all work for this turn is finished and no user decision or response is needed; Playhouse moves the task to Review. Use waiting-response when you need the user to answer, choose between options, provide missing information, or take another action before you can continue. Use in-progress when this turn is ending but the work is not done and you need nothing from the user: Playhouse keeps the task In Progress and immediately sends you a private continuation turn so you can carry on. Never end a turn mid-work without an outcome — report in-progress instead. The outcome call must be your final CLI action for the turn.
        Write your user-visible final reply after the outcome call returns. That reply is the last thing in the turn: never end a turn on a tool call.
        Reporting an outcome is required for every successful turn. If you end a turn without one, Playhouse privately nudges you to report your current status, up to \(TurnOutcome.maxContinuations) times per request. Answer a nudge with an outcome call rather than by repeating finished work. If the nudges run out without the work settling, Playhouse marks the task Blocked.
        \(noVisibleOutputNoticeRule)
        """
    }

    /// The skill an Add Plugin mode task uses.
    static let pluginSkillName = "playhouse-plugin"

    /// Guidance for a task started from an Add Plugin mode placeholder: where the
    /// plugin goes, what it receives, and how to install and check it.
    static func pluginAuthoringInstructions(placement rawPlacement: String?, executable: String, pluginsDirectory: String?) -> String {
        guard let rawPlacement, let placement = PluginPlacement(rawValue: rawPlacement) else { return "" }
        let directory = pluginsDirectory ?? "the plugins folder"
        return """

        Plugin authoring: this task builds a new Playhouse plugin whose entry button goes in the \(placement.title) placement (`\(placement.rawValue)`). Use the /\(pluginSkillName) skill for the plugin system's details, and ask the user for anything the request leaves open (what the plugin does, its name and icon, and whether it opens as a popover, modal, sidebar or page) before writing it.
        - Write the plugin to \(directory)/<plugin-id>/ as plugin.json (id, name, icon, placement "\(placement.rawValue)", presentation) and index.js. That folder is this task's context folder; it is not a Git repository and needs no worktree or pull request.
        - Context the plugin receives in Playhouse.props at this placement: \(placement.contextDescription)
        - Check it headlessly with \(executable) plugin render --plugin <plugin-id> [--task <task-id>] [--event <testID>:<event>[:<value>]], then install it with \(executable) plugin refresh, which validates every plugin and shows the valid ones in the app immediately. Fix every reported error before you finish.

        """
    }

    /// Guidance for follow-up work after a pull request merged: the merged branch is
    /// finished, so Git work starts again from a fresh worktree off the merge target.
    private static func mergedWorkInstructions(
        id: String,
        executable: String,
        repositories: [RepositoryWorktreeRecord],
        isArchived: Bool
    ) -> String {
        let renew = "\(executable) task repository renew \(id) --repo <path>"
        let outcome = "Make every edit in the returned worktreePath. When the work is ready, Playhouse opens a new pull request for that worktree, and the merged pull request stays on the task card."
        if isArchived {
            return "This task is Done (archived) and its task worktrees were removed. A follow-up message reopens it: Playhouse moves it back to In Progress and gives every repository whose worktree was removed a fresh worktree on a new branch from the latest merge target (for example origin/master) before the turn starts. \(outcome)\n"
        }
        let merged = repositories.filter { $0.isPullRequestMerged && $0.pullRequestNumber != nil }
        guard !merged.isEmpty else { return "" }
        let list = merged.map { "#\($0.pullRequestNumber ?? 0) for \($0.repositoryPath) (branch \($0.branch))" }.joined(separator: ", ")
        return "Merged pull requests: \(list). A merged branch is finished: do not commit or push to it. Follow-up questions need no Git work. Before any further change that involves Git in such a repository, run \(renew). It creates a fresh worktree on a new branch from the latest merge target (for example origin/master) and returns the source-to-worktree mapping. \(outcome)\n"
    }

    /// Claude Code adds a notice to a turn that ended on a tool call. An agent that already
    /// answered earlier in that turn must not answer a second time.
    static let noVisibleOutputNoticeRule = "If you receive a notice that your previous response had no visible output but you already answered in this turn, do not repeat the answer; reply briefly or say nothing more."

    static func cliExecutableURL() -> URL {
        let fileManager = FileManager.default
        var candidate = Bundle.main.bundleURL
        for _ in 0..<5 {
            let cli = candidate.appendingPathComponent("Contents/MacOS/playhouse-cli")
            if fileManager.isExecutableFile(atPath: cli.path) { return cli }
            candidate.deleteLastPathComponent()
        }
        return Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/playhouse-cli")
    }
}

enum TaskProgressReportInstructions {
    static let executableName = "playhouse-cli"
    static let progressSubcommand = "task progress"
    static let outcomeSubcommand = "task outcome"
    /// Standalone chat's end-of-turn page signal. A chat has no board status, so
    /// it reports this instead of an outcome, and it runs in the same place: just
    /// before the final reply, though agents still often run it after their answer.
    static let chatPageCloseTurnSubcommand = "chat page close-turn"

    enum ReportCommand { case progress, outcome }

    /// Classifies a provider shell command as one of the reports these instructions request.
    static func reportCommand(in shellCommand: String) -> ReportCommand? {
        guard shellCommand.contains(executableName) else { return nil }
        if shellCommand.contains(" \(outcomeSubcommand) ") { return .outcome }
        if shellCommand.contains(" \(chatPageCloseTurnSubcommand) ") { return .outcome }
        if shellCommand.contains(" \(progressSubcommand) ") { return .progress }
        return nil
    }

}
