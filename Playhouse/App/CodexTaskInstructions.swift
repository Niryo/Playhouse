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
        The main task conversation continues without you, so never run task progress, task outcome, repository commands or conversation commands that send or change anything for task \(taskID.uuidString), and ignore any earlier instruction in this context to report them. You may read the task's conversation with conversation outline and conversation read when the context above is not enough, for example when it began with a Playhouse optimized context summary.

        You can manage the Playhouse board with its CLI, running one command per shell call. \(capabilityInstructions(for: .sideChat, executable: quotedExecutable))
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
        pluginName: String? = nil,
        pluginPresentation: String? = nil,
        pluginsDirectory: String? = nil,
        isOptimizedContext: Bool = false
    ) -> String {
        let executable = cliExecutableURL().path
        let quotedExecutable = "'" + executable.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let id = taskID.uuidString
        if isPluginEditor {
            return """
            You are helping the user create and edit a Playhouse plugin in a standalone editor.
            This conversation is not a task and has no task board status or outcome to report.
            The plugin ID and folder are \(pluginID ?? "unknown"); its folder is inside \(pluginsDirectory ?? "the Playhouse plugins directory"). When it already exists, edit that plugin rather than creating a different one.
            \(pluginName.map { "The chosen plugin name is \($0)." } ?? "") \(pluginPresentation.map { "The chosen presentation is \($0)." } ?? "")
            \(pluginChangeRule)
            \(pluginAuthoringInstructions(placement: pluginPlacement, executable: quotedExecutable, pluginsDirectory: pluginsDirectory))
            \(capabilityInstructions(for: .pluginEditor, executable: quotedExecutable))
            """
        }
        if isStandaloneChat {
            let closeTurn = CLICommandCatalog.invocation("chat page close-turn", executable: quotedExecutable)
            return """
            You are the assistant inside Playhouse's standalone chat.

            Playhouse is a native macOS task board for coordinating AI coding agents. Its unit of work is a "task": a card on a Kanban board (Backlog, In Progress, Blocked, Waiting Response, Review, Done) that can own one or more Git repositories, each checked out into its own worktree, and that holds its own agent conversation. The user manages that board through this app.
            When the user talks about tasks, the board, backlog, worktrees, repositories, or "create a task", they always mean Playhouse — this app, on this machine. Never use any other task, todo, or issue tool for that, even if one is available to you: anything you create elsewhere is invisible to the user. Manage it with the Playhouse CLI instead of substituting another tool.

            \(capabilityInstructions(for: .chat, executable: quotedExecutable))

            A task created with no repository is a plain card; add repositories only when the user asks for work in a specific repo. Creating a task does not start it — the user runs it from the board. Never start, move or schedule a task unless the user asks you to; when they ask you to schedule one, schedule it the way they asked. Before you delete anything, such as a task, skill, rule or MCP server, confirm with the user.

            `task create` requires --prompt: it is the task's full description, saved on the card in the same command. Never create a task with only a title. `--prompt` only saves the description: unless the user asks, never submit or start the task (no `task prompt --submitted true`, no status change, no move), so it stays in Backlog. A good description is self-contained, because the agent that runs the task will not see this chat. Include the goal; background and context from this conversation (findings, numbers, file paths, decisions the user made); concrete requirements; where to look in the code; and acceptance criteria. Do this every time, without the user asking.

            Report back the real task ID the CLI returned and say that the description was saved. If a command fails, show the user what it said rather than claiming success.

            This chat itself is not a task: it has no board status, no repository and no worktree, so task progress, task outcome and repository commands do not apply to this conversation. The conversation is split behind the scenes into titled "pages" so your live context stays small while the full history stays searchable.
            - A new page session starts with a Playhouse page metadata block, not written by the user: the current page's ID and title with a shortened excerpt of its latest exchange, and the IDs and titles of recent pages. Their turns are not loaded. If the user's message continues the current page or a listed page and the excerpt is not enough to answer well, run \(CLICommandCatalog.invocation("chat page read", executable: quotedExecutable)) <page-id> to load that page before answering. If the message starts something unrelated, do not load any page.
            - If the user asks about something from earlier that is neither in your current context nor among the listed pages, call \(CLICommandCatalog.invocation("chat page search", executable: quotedExecutable)) "<query>" to find the right page, then \(CLICommandCatalog.invocation("chat page read", executable: quotedExecutable)) <page-id> to load it before answering.
            - In every single turn, with no exceptions, once your work is done and before you write your final reply, decide whether the user's message continued the current topic or started a new, unrelated one, and run exactly one of these as a real command (never just write it as text in your reply). Run exactly one close-turn per turn:
              \(closeTurn) \(id) --continues true
              \(closeTurn) \(id) --continues false --new-title "<short title for the new topic>"
              This single command both records your classification and files this turn under the right page — do not call "chat page new" separately for this; close-turn creates the new page itself when needed.
              Write your final reply to the user after close-turn returns. That reply is the last thing in the turn: never end a turn on a tool call.
              Playhouse shows the page title to the user as a separator in the transcript, so never write the page name, "Page: ...", or any other page bookkeeping into your visible answer.
            - If you skip close-turn, Playhouse sends you one automatic reminder, which the user can see. Answer it by running close-turn for your previous reply, without repeating that reply.
            - \(noVisibleOutputNoticeRule)
            """
        }
        let progress = CLICommandCatalog.invocation("task progress publish", executable: quotedExecutable)
        let customProgress = CLICommandCatalog.invocation("task progress custom", executable: quotedExecutable)
        let clearProgress = CLICommandCatalog.invocation("task progress clear", executable: quotedExecutable)
        return """
        Report your current work on the Playhouse task board using the Playhouse CLI. Publish at every phase change, when starting or finishing a substantial tool call, and at least every 30 seconds during long commands, builds, tests, waits, or investigation. Keep the report current while a tool runs; after it finishes, replace it with the next active action. During tests, identify the active suite/case and position when known (for example, "CLI/XPC 3/8: task progress persistence"); during other work, name the concrete action and useful target. Keep each detail to a short subtitle, ideally under 80 characters. Do not report every tiny edit. Use these commands for this task:
        \(progress) \(id) --type <planning|searching|building|running|testing|reviewing|writing|committing> [--detail \"short detail\"]
        \(customProgress) \(id) --label \"short label\" [--detail \"short detail\"]
        \(clearProgress) \(id)
        Progress reports are hidden from the conversation and shown on the task card. Keep details brief. Do not use lifecycle task status commands for progress.
        To show the user an image you created (such as a screenshot or chart), publish it into this task's chat with:
        \(CLICommandCatalog.invocation("conversation present-image", executable: quotedExecutable)) \(id) --image <path> [--caption "short caption"]
        This adds a durable assistant image message to the chat. Use PNG or JPEG files smaller than 10 MB.

        Repository context for this task:
        - Selected repositories (source identity): \(repositories.isEmpty ? "none" : repositories.map(\.repositoryPath).joined(separator: ", "))
        - Active task worktrees for edits: \(repositories.isEmpty || isArchived ? "none" : repositories.map { "\($0.repositoryPath) -> \($0.worktreePath)" }.joined(separator: "; "))
        - Additional context folders: \(contextFolders.isEmpty ? "none" : contextFolders.joined(separator: ", "))
        - Configured repository root: \(repositoryRootPath ?? "not available")
        A task may intentionally have no selected repository. Decide whether it is standalone or needs repository context. For read-only inspection, you do not need to attach a repository or create a worktree: call \(CLICommandCatalog.invocation("workspace repos list", executable: quotedExecutable)), then inspect a clearly matching returned repository path read-only. Never edit files in those source paths. If the request is standalone, proceed without repository context.
        Add a repository to this task only when you intend to create or commit changes in it. If the needed repository is not already selected, call workspace repos list, choose a clearly matching returned path, then add it to this task with task repository add (or add-batch for multiple repositories). This creates the task worktree and returns the source-to-worktree mapping; make all changes in the returned worktreePath. You do not need to ask the user for special permission to read another listed repository, and you do not need to add a repository just to inspect it. If no returned path clearly matches a requested change, ask the user which repository to modify. Do not add or replace repositories merely because the selected context seems unrelated to the task; the user may have intentionally left a sticky default selected.
        For already selected repositories, make changes in their corresponding active task worktrees above. For folder-only tasks, use the selected additional context folder; with no repository or folder context, treat the task as standalone unless the user asks for files that clearly belong in a repository. Playhouse starts the provider conversation with the active task worktree as cwd and runtime workspace root; with no repository or folder context, the cwd is the configured repository root, so start any search there rather than in the home folder. Temporary files under /tmp and other non-repository directories remain available when useful.
        Use the workspace repos list API for repository discovery; do not search the configured root to find repositories yourself. Once the API returns a repository path, you may inspect that repository's contents read-only without adding it. For read-only inspection of returned source paths, you do not need to add a repository.
        A selected repository can be a sticky default from an earlier task, and the user may have forgotten to change it. Do not interrupt the user or ask them to confirm the selection merely because the task appears unrelated. Use workspace repos list to discover alternatives when needed. Read-only inspection of returned source paths does not require adding repositories. Add a repository only when you intend to make or commit changes there, and use its task worktreePath for every edit. Do not replace or remove selected repositories unless the user explicitly asks; adding a worktree for a change is sufficient. Never silently edit a source repository path.
        \(mergedWorkInstructions(id: id, executable: quotedExecutable, repositories: repositories, isArchived: isArchived))\(pluginAuthoringInstructions(placement: pluginPlacement, executable: quotedExecutable, pluginsDirectory: pluginsDirectory))This task's ID is \(id). A task can have several worktrees of the same repository, each on its own branch with at most one pull request. When the task has more than one worktree of a repository, pass --worktree <worktree-path> instead of --repo to remove, renew, edit or link one of them.
        Open a task's pull requests with task pr create. If you open one another way (for example with gh pr create), register it right away with task pr link from that worktree's branch, so the task lists it. Never switch the branch checked out in a task worktree; when work needs another branch of the same repository, create one with task repository add-worktree and work in its returned worktreePath. Renew a worktree with task repository renew only after its pull request merged.
        \(capabilityInstructions(for: .task, executable: quotedExecutable))
        \(isOptimizedContext ? optimizedContextInstructions(id: id, executable: quotedExecutable) : "")
        Playhouse keeps this task In Progress for as long as you are working; it reads that from your runtime activity, so there is nothing to report while work remains. Keep working within the current turn until the work is finished, you need the user, or you are genuinely blocked. Never end a turn because work remains or because something is slow: when a command you need (a test run, a build, a job queued behind a lock) is still running, keep awaiting or polling that same command session in this turn until it exits, then act on its real result.
        When you are about to stop, and before you write your final reply, make exactly one stopping outcome call using this task ID:
        \(CLICommandCatalog.invocation("task outcome", executable: quotedExecutable)) \(id) <\(TurnOutcome.commandChoices)>
        Use completed only when all requested work is finished and no user decision or response is needed; Playhouse moves the task to Review. Use waiting-response when you need the user to answer, choose between options, provide missing information, or take another action before you can continue. Use blocked, with --reason "<what blocks the work>", when you cannot continue and no answer from the user would unblock it by itself (for example a required service is down or a credential is missing); Playhouse moves the task to Blocked and shows the reason. There is no outcome for unfinished work: do not report one, keep working instead. The outcome call must be your final CLI action for the turn, made only after every command you still need has finished. A process you deliberately leave running (a dev server, say) does not hold the task open once you report an outcome.
        Write your user-visible final reply after the outcome call returns. That reply is the last thing in the turn: never end a turn on a tool call.
        If a turn ends without a stopping outcome while a command it started is still running, Playhouse treats that command as required work: it keeps the task In Progress, waits for the command outside the model, and sends you its exit status and output in one private turn. If a turn ends without an outcome and nothing is running, Playhouse sends one private recovery prompt: continue the remaining work in that turn or report a stopping outcome. If that turn also ends without one, Playhouse marks the task Blocked.
        \(noVisibleOutputNoticeRule)
        """
    }

    /// Guidance for a task whose follow-ups start fresh sessions (optimized context mode).
    /// Names the reading commands and leaves their usage to help.
    static func optimizedContextInstructions(id: String, executable: String) -> String {
        let read = CLICommandCatalog.invocation("conversation read", executable: executable)
        let outline = CLICommandCatalog.invocation("conversation outline", executable: executable)
        let help = CLICommandCatalog.invocation("help", executable: executable)
        return """
        This task uses optimized context. Each follow-up the user sends (not a steer) starts a fresh session that does not hold the conversation's earlier turns. Instead the prompt begins with a <playhouse-handoff-context> block Playhouse wrote: an outline of the conversation by position, every message the user wrote, the latest plan and the latest final answer. It is a summary, not the whole conversation, and it is not part of the user's message.
        Positions number the whole conversation: a whole number is a message, and a decimal such as 12.3 is the third tool call after message 12. The outline gives each turn's user message, how many agent messages and tool calls followed it, and where its final answer is, so a jump from a user message at 30 to the next at 100 means a long stretch of work happened in between.
        Whenever the block is not enough to do what the user asks well (an earlier answer, a decision, a command's output, the work between two messages), read more of the conversation before you act rather than guessing:
          \(read) \(id) reads entries by position or range, final answers only, or tool calls too.
          \(outline) \(id) gives the outline again.
        Run \(help) conversation --for task for their options. Read only what you need: a final answer at its position is usually enough, and the tool calls between messages only when the details matter.
        """
    }

    /// Where an agent learns what Playhouse can do: the CLI's help for its audience, which lists
    /// every command the CLI declares for it. These instructions describe behavior only, so a
    /// new command reaches its agents through help without a change here.
    static func capabilityInstructions(for audience: CLIAudience, executable: String) -> String {
        let help = CLICommandCatalog.invocation("help", executable: executable)
        return """
        The Playhouse CLI lists everything it can do for you. Before you first use Playhouse in this conversation, and always before you tell the user that Playhouse can't do something, run:
          \(help) --for \(audience.rawValue)
        For one group of commands, run \(help) <group> --for \(audience.rawValue) (for example, help schedule). Say that something isn't possible only after its help shows no command for it.
        """
    }

    /// The skill an Add Plugin mode task uses.
    static let pluginSkillName = "playhouse-plugin"

    /// The editor's setup choices are a starting point; the user can change any of them later.
    static let pluginChangeRule = "These setup choices are only a starting point. When the user asks to change the plugin's name, icon, placement or presentation, update plugin.json to match and keep the plugin ID and folder; the user's latest request wins over the choices above."

    /// Guidance for a task started from an Add Plugin mode placeholder: where the
    /// plugin goes, what it receives, and how to install and check it.
    static func pluginAuthoringInstructions(placement rawPlacement: String?, executable: String, pluginsDirectory: String?) -> String {
        guard let rawPlacement, let placement = PluginPlacement(rawValue: rawPlacement) else { return "" }
        let directory = pluginsDirectory ?? "the plugins folder"
        return """

        Plugin authoring: this task builds a new Playhouse plugin whose entry button the user first chose to put in the \(placement.title) placement (`\(placement.rawValue)`). Use the /\(pluginSkillName) skill for the plugin system's details and the chosen name and presentation when supplied. Ask the user for any required details the request leaves open before writing it.
        - Write the plugin to \(directory)/<plugin-id>/ as plugin.json (id, name, icon, placement "\(placement.rawValue)" unless the user asks for another, presentation) and index.js. That folder is this task's context folder; it is not a Git repository and needs no worktree or pull request.
        - Context the plugin receives in Playhouse.props at this placement: \(placement.contextDescription) The skill lists the context of the other placements.
        - This folder is a persistent draft. Never modify the installed plugin or publish it; the user chooses Save in the editor. Check the draft with \(CLICommandCatalog.invocation("plugin render", executable: executable)) --file \(directory)/<plugin-id>/index.js and fix errors before finishing.

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
        let renew = "\(CLICommandCatalog.invocation("task repository renew", executable: executable)) \(id) --repo <path>"
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

/// The prompts Playhouse sends on its own that the user can rewrite in Settings > System
/// Prompts. The user edits only the guidance; Playhouse wraps it in the parts its flows
/// depend on (the request, the conversation, the autopilot marker, Git and outcome rules),
/// so a custom prompt can change style but never break a flow. Each prompt reaches Claude
/// and Codex alike: the helper turns pick either provider, and autopilot sends through the
/// task's own provider.
enum SystemPromptKind: String, CaseIterable, Sendable {
    case pullRequestDescription = "pr-description"
    case greenFix = "green"
    case mergeConflicts = "merge-conflicts"
    case taskTitle = "task-title"

    var title: String {
        switch self {
        case .pullRequestDescription: "Pull request description"
        case .greenFix: "Green / autopilot fix"
        case .mergeConflicts: "Merge conflict resolution"
        case .taskTitle: "Task title"
        }
    }

    /// When Playhouse sends the prompt and what it adds around the user's text.
    var usage: String {
        switch self {
        case .pullRequestDescription:
            "Used when Playhouse opens a pull request. Playhouse adds the task title and the task's conversation after it."
        case .greenFix:
            "Sent to the task's agent in Green and Merge modes while a pull request is red. Playhouse adds the failing checks, conflicts and unresolved review threads before it, the merge conflict guidance when there are conflicts, and its commit and outcome rules after it."
        case .mergeConflicts:
            "How the agent resolves merge conflicts: in Green and Merge modes, and when Playhouse syncs a task's branch with its pull request. Playhouse adds the Git steps around it."
        case .taskTitle:
            "Used to name a new task. Playhouse adds the task's request after it."
        }
    }

    var defaultText: String {
        switch self {
        case .pullRequestDescription:
            "Write a very concise GitHub pull request description. Explain what problem this change solves, how it solves it, and briefly mention any special issue or caveat from the conversation. Use Markdown, no more than three short sections, and return only the description."
        case .greenFix:
            """
            1. Read the details with the GitHub CLI from the task worktree: `gh pr checks <number>`, `gh run view <run-id> --log-failed` for failing runs, and the review threads through `gh api graphql` (`reviewThreads` with their comments).
            2. Fix genuine failures in the task worktree.
            3. Treat every unresolved review comment critically: reviewers and bots can be wrong, noisy, or out of scope. Change the code only for comments that really deserve it. For every thread, fixed or not, reply with what you changed or why you left the code as it is, then resolve the thread (GraphQL `addPullRequestReviewThreadReply` and `resolveReviewThread`).
            """
        case .mergeConflicts:
            "Resolve every Git merge conflict. Preserve the intended changes from both sides and inspect the resulting files."
        case .taskTitle:
            "Write a concise task title of at most 8 words for this request. Return only the title:"
        }
    }
}

/// Reads the saved system prompts and builds what Playhouse sends from them. A prompt the
/// user never changed (or reset) has no stored value and reads as its default.
enum SystemPrompts {
    static let maximumLength = 8_000

    static func key(_ kind: SystemPromptKind) -> String { "systemPrompt.\(kind.rawValue)" }

    static func storedText(_ kind: SystemPromptKind, defaults: UserDefaults = WorkspaceSettings.preferencesStore) -> String? {
        defaults.string(forKey: key(kind))
    }

    static func text(_ kind: SystemPromptKind, defaults: UserDefaults = WorkspaceSettings.preferencesStore) -> String {
        storedText(kind, defaults: defaults) ?? kind.defaultText
    }

    static func pullRequestDescription(title: String, conversation: String) -> String {
        "\(text(.pullRequestDescription))\n\nTask: \(title)\n\nConversation:\n\(conversation)"
    }

    static func taskTitle(request: String) -> String {
        "\(text(.taskTitle))\n\n\(request)"
    }

    /// The helper turn that resolves conflicts Playhouse's own merge left staged; Playhouse
    /// commits and pushes the result itself.
    static func stagedMergeConflicts() -> String {
        """
        The Git merge in the current workspace stopped on conflicts.

        \(text(.mergeConflicts))

        Stage the resolved files. Do not commit or push. Report which conflicts you resolved.
        """
    }

    /// The Green and Merge modes' fix turn for red pull requests.
    static func pullRequestAutopilot(_ states: [PullRequestReviewState]) -> String {
        let open = states.filter { !$0.merged }
        let problems = open.compactMap { state -> String? in
            var issues: [String] = []
            if state.checks == .failure {
                issues.append(state.failingChecks.isEmpty ? "failing checks" : "failing checks: \(state.failingChecks.joined(separator: ", "))")
            }
            if state.hasConflicts { issues.append("merge conflicts with its base branch") }
            if let threads = state.unresolvedReviewThreads, threads > 0 {
                issues.append("\(threads) unresolved review \(threads == 1 ? "thread" : "threads")")
            }
            guard !issues.isEmpty else { return nil }
            return "- Pull request #\(state.number) (\(state.repositoryPath)): \(issues.joined(separator: "; "))."
        }
        let conflicts = open.contains(where: \.hasConflicts) ? """


        Merge conflicts: merge the pull request's base branch into the task branch in the task worktree, then resolve the conflicts:
        \(text(.mergeConflicts))
        """ : ""
        let threads = open.contains { ($0.unresolvedReviewThreads ?? 0) > 0 } ? """


        Review threads: an unresolved review thread keeps the pull request red until it is resolved on GitHub.
        """ : ""
        return """
        \(PlayhouseSentMessage.pullRequestAutopilotMarker) this task's pull request isn't green yet. Please get it there.

        \(problems.joined(separator: "\n"))

        \(text(.greenFix))\(threads)\(conflicts)

        Commit your work; Playhouse pushes the task branch when you report `completed`. If something can't be fixed from here — for example GitHub or CI is down, a check needs credentials or permissions you don't have, or the user must act (such as adding a Jira ticket to the pull request title) — don't retry in a loop. Report `waiting-response` and tell the user exactly what is blocking the pull request and what they need to do. Otherwise report `completed` when you're done; Playhouse keeps watching the pull request and sends another turn if it is still red.
        """
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
