import Foundation

/// Where an installed plugin's entry button sits. Each placement hands the
/// plugin a different context in `Playhouse.props`.
enum PluginPlacement: String, CaseIterable, Codable, Sendable {
    /// The board's sidebar. Standalone (no task), plus `schedules`.
    case mainSidebar
    /// The conversation task sidebar's first section, above Changes.
    case conversationSidebar
    /// The task sidebar's bottom row, beside the Terminal button.
    case conversationToolbar
    /// The composer's actions row, beside the Skills button.
    case composerActions
    /// The bottom row of each task card on the board, beside its pull request controls.
    case taskItem
    /// The bottom of the board's sidebar. Standalone, like the main sidebar,
    /// plus `agents`. Every plugin here is a collapsible section
    /// (`PluginPresentation.section`): the host draws its header, and the
    /// sections stack upward from the sidebar's bottom edge.
    case mainSidebarBottom

    var title: String {
        switch self {
        case .mainSidebar: "Main sidebar"
        case .conversationSidebar: "Conversation sidebar"
        case .conversationToolbar: "Conversation sidebar toolbar"
        case .composerActions: "Chat input actions"
        case .taskItem: "Task card"
        case .mainSidebarBottom: "Main sidebar bottom"
        }
    }

    /// The entry and its "Add here" placeholder show only an icon here.
    var isIconOnly: Bool {
        self == .conversationToolbar || self == .composerActions || self == .taskItem
    }

    var hasTask: Bool { self != .mainSidebar && self != .mainSidebarBottom }

    /// On the board, whose window answers `ui.confirm`.
    var isOnBoard: Bool { self == .mainSidebar || self == .mainSidebarBottom || self == .taskItem }

    /// What this placement adds to `Playhouse.props`, for the authoring agent.
    var contextDescription: String {
        switch self {
        case .mainSidebar:
            "Standalone (no task): `plugin`, `app`, and `schedules` ({tasks, needsLoginItemsApproval}): `tasks` is what `schedule.list` returns (every scheduled task, one-time and recurring, soonest first; each task's `schedule` holds {kind, scheduledAt, summary, prompt, paused, lastRunTaskID, …}), kept live as schedules change; `needsLoginItemsApproval` says macOS is waiting for the user to allow Playhouse in Login Items, which scheduled runs need while the app is closed (`ui.openLoginItems` opens that setting). `ui.newTask({schedule: \"recurring\" or \"once\"})` opens a new task with its schedule picker up."
        case .conversationSidebar, .conversationToolbar:
            "`plugin`, `app`, `task` ({id, title, status, provider, isStandaloneChat, scheduleSourceTaskID}), `repositories` ([{repositoryPath, worktreePath, branch, isPending, awaitsPullRequest, pullRequest: {number, url, merged, closed, state} or null}], one per worktree; a repository may have several, each on its own branch), `pastPullRequests` ([{repositoryPath, worktreePath, branch, number, url, merged, closed, state}], from worktrees the task has removed or switched to another branch) and `contextFolders` ([path])."
        case .taskItem:
            "The same `plugin`, `app`, `task`, `repositories`, `pastPullRequests` and `contextFolders` as the conversation placements, for the card's task. The card is small: show an icon or a short label, and listen with `Playhouse.on(\"task.statusChanged\", …)` and `Playhouse.on(\"app.focus\", …)` for when to refresh what it shows."
        case .composerActions:
            "`plugin`, `app`, `task`, `repositories`, `contextFolders`, and `composer` ({draft, selection: {location, length, text}}), the composer's current draft and the text selected in it."
        case .mainSidebarBottom:
            "Standalone (no task): `plugin`, `app`, and `agents` ({usage, runningTasks}): `usage` is what `usage.get` returns ({generatedAt, providers: [{provider, installed, loggedIn, account, plan, loginInProgress, snapshot}]}), kept live as the providers report, or null before the first read; `runningTasks` counts the running tasks per provider ({claude, codex}). The plugin is a collapsible section under a header the host draws with its name; it hides, header included, while it renders nothing. Listen with `Playhouse.on(\"app.launched\", …)` to refresh once per app launch."
        }
    }

    static func parse(_ value: String) throws -> PluginPlacement {
        guard let placement = PluginPlacement(rawValue: value) else {
            throw PluginTreeError(message: "Unknown placement \"\(value)\". Placements: \(allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        return placement
    }
}

/// How a plugin's surface opens when its entry button is pressed.
enum PluginPresentation: String, CaseIterable, Codable, Sendable {
    /// Anchored to the entry button.
    case popover
    /// A sheet over the window.
    case modal
    /// A panel that slides in from the trailing edge.
    case sidebar
    /// A full page over the board or the conversation.
    case page
    /// Rendered in place at its placement, without an entry button or a
    /// header: a section of the sidebar it sits in. Only the sidebars'
    /// placements have room for one.
    case inline
    /// Rendered in place under a collapsible header the host draws with the
    /// plugin's name, at the bottom of the board's sidebar: the only
    /// presentation of `PluginPlacement.mainSidebarBottom`, and only there.
    case section
    /// No surface at all: the plugin exposes `/` commands in the composer (its
    /// manifest's `commands`), whose menus the host draws, a background half in
    /// the daemon (its `events`), or both. Its placement is always
    /// `PluginPlacement.composerActions`.
    case headless

    var title: String {
        switch self {
        case .popover: "Popover"
        case .modal: "Modal"
        case .sidebar: "Side panel"
        case .page: "Page"
        case .inline: "Inline"
        case .section: "Collapsible section"
        case .headless: "Headless (slash commands only)"
        }
    }

    /// Rendered in place at its placement rather than opened from an entry button.
    var isInPlace: Bool { self == .inline || self == .section }

    /// Why a plugin can't open this way at `placement`, or nil when it can.
    func placementError(_ placement: PluginPlacement) -> String? {
        if self == .headless, placement != .composerActions {
            return "A headless plugin's commands run in the composer; its placement must be \"\(PluginPlacement.composerActions.rawValue)\", not \"\(placement.rawValue)\"."
        }
        if self == .inline, !Self.inlinePlacements.contains(placement) { return Self.inlinePlacementError(placement) }
        if self == .section, placement != .mainSidebarBottom {
            return "A section plugin can't sit at the \(placement.title) placement; only at the \(PluginPlacement.mainSidebarBottom.title)."
        }
        if self != .section, placement == .mainSidebarBottom {
            return "A plugin at the \(placement.title) placement is always a collapsible section; its presentation must be \"section\", not \"\(rawValue)\"."
        }
        return nil
    }

    /// The placements an inline plugin may sit in.
    static let inlinePlacements: Set<PluginPlacement> = [.conversationSidebar, .taskItem]

    static func inlinePlacementError(_ placement: PluginPlacement) -> String {
        "An inline plugin can't sit at the \(placement.title) placement; only in the conversation sidebar or on the task card."
    }
}

/// `plugin.json`, the manifest in each plugin's folder.
struct PluginManifest: Codable, Equatable, Sendable {
    var id: String
    var name: String
    /// Monotonically increasing published revision; absent in legacy plugins.
    var version: Int? = nil
    /// An SF Symbol.
    var icon: String?
    var placement: String
    var presentation: String
    /// The script, relative to the plugin's folder; `index.js` when absent.
    var entry: String?
    /// The surface's size in points; each presentation has a default.
    var width: Double?
    var height: Double?
    /// The `/` commands the plugin exposes in the composer, which its script
    /// registers with `Playhouse.commands.register`. Any plugin may declare
    /// them; a headless plugin has these, `events`, or both.
    var commands: [PluginCommandManifest]? = nil
    /// The app events (`PluginEvent.names`) the plugin's background half hears in
    /// the daemon through `Playhouse.service.on`, with or without a window open.
    /// Any presentation may declare them.
    var events: [String]? = nil
    /// The only MCP tools `Playhouse.mcp.call` may call, when present, such as
    /// `mcp__claude_ai_Slack__slack_read_channel`; it catches mistakes, it isn't a security boundary.
    var mcpTools: [String]? = nil
}

/// One plugin folder as `plugin list` reports it.
struct PluginRecord: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let version: Int
    let icon: String
    let placement: String
    let presentation: String
    let width: Double?
    let height: Double?
    let folder: String
    let entryPath: String
    /// Valid plugins are mounted; invalid ones are listed with their errors.
    let valid: Bool
    let errors: [String]
    /// Compiled into the app (`BuiltInPlugins`): it has no folder or script,
    /// can't be edited or deleted, and only be disabled.
    var builtIn = false
    /// A disabled plugin is listed but neither shown nor run.
    var enabled = true
    /// The plugin's own saved values (`plugin.state.set`), its `Playhouse.props.state`.
    var state: [String: PluginValue] = [:]
    /// The manifest's `/` commands.
    var commands: [PluginCommandManifest] = []
    /// The manifest's `events`: what its background half hears in the daemon.
    var events: [String] = []
    /// The manifest's `mcpTools`, nil when it allows any tool.
    var mcpTools: [String]? = nil

    /// Has a background half in the daemon (`Playhouse.service.on`).
    var hasService: Bool { !events.isEmpty }

    /// Mounted in the window: valid and not disabled.
    var isActive: Bool { valid && enabled }

    /// Has an entry button or an in-place surface; a headless plugin only has commands and a background half.
    var hasSurface: Bool { presentation != PluginPresentation.headless.rawValue }

    /// The same plugin at another placement: its commands run in the
    /// composer's context, whatever surface it has elsewhere.
    func at(_ placement: PluginPlacement) -> PluginRecord {
        var record = PluginRecord(
            id: id, name: name, version: version, icon: icon, placement: placement.rawValue, presentation: presentation,
            width: width, height: height, folder: folder, entryPath: entryPath, valid: valid, errors: errors
        )
        record.builtIn = builtIn
        record.enabled = enabled
        record.state = state
        record.commands = commands
        record.events = events
        record.mcpTools = mcpTools
        return record
    }
}

/// The plugins compiled into the app. Each is declared with the same manifest
/// an installed plugin's `plugin.json` holds, and the app renders it with a
/// native view (`BuiltInPluginView`) built from the same atoms, the same
/// `Playhouse.props` and the same host calls a JavaScript plugin gets, so a
/// user could write the same plugin as an installed one.
enum BuiltInPlugins {
    /// The conversation sidebar's Changes section.
    static let changesID = "changes"
    /// The task card's pull request mode pill: it owns each task's mode (its
    /// state, keyed by task id) and, in its daemon service, what the mode does
    /// when the task moves or the app comes to the front.
    static let pullRequestModeID = "pull-request-mode"
    /// The task card's pull request controls: create, links coloured by
    /// health, the merged check and the resolve-conflicts button.
    static let pullRequestsID = "pull-requests"
    /// The board sidebar's bottom section with each agent's usage and
    /// account, from `props.agents`.
    static let agentsInfoID = "agents-info"
    /// The board sidebar's Scheduled Tasks popover, listing `props.schedules`.
    static let scheduledTasksID = "scheduled-tasks"
    /// The composer's built-in `/` commands, a headless plugin whose Swift
    /// handlers (`BuiltInCommandsPlugin`) use only the host calls a script has.
    static let builtInCommandsID = "built-in-commands"

    static let builtInCommands: [PluginCommandManifest] = [
        PluginCommandManifest(name: "mcp", detail: "Mention an MCP server, manage it, or sign in to it", icon: "server.rack", list: true),
        PluginCommandManifest(name: "plan", detail: "Turn on plan mode", icon: "list.bullet.clipboard"),
        PluginCommandManifest(name: "goal", detail: "Turn on goal mode", icon: "scope"),
        PluginCommandManifest(name: "skill", detail: "Mention a skill or open its editor", icon: "sparkles", list: true),
        PluginCommandManifest(name: "login", detail: "Sign in to an agent", icon: "person.crop.circle", list: true),
        PluginCommandManifest(name: "plugin", detail: "Create a plugin or manage yours", icon: "puzzlepiece.extension", list: true)
    ]

    /// Names an installed plugin's command can't take.
    static var commandNames: Set<String> { Set(manifests.flatMap { $0.commands ?? [] }.map(\.name)) }

    static let manifests: [PluginManifest] = [
        PluginManifest(id: changesID, name: "Changes", version: 1, icon: "plusminus", placement: PluginPlacement.conversationSidebar.rawValue, presentation: PluginPresentation.inline.rawValue),
        PluginManifest(id: pullRequestModeID, name: "Pull request mode", version: 1, icon: "arrow.triangle.branch", placement: PluginPlacement.taskItem.rawValue, presentation: PluginPresentation.inline.rawValue),
        PluginManifest(id: pullRequestsID, name: "Pull requests", version: 1, icon: "arrow.triangle.pull", placement: PluginPlacement.taskItem.rawValue, presentation: PluginPresentation.inline.rawValue),
        PluginManifest(id: agentsInfoID, name: "Agents info", version: 1, icon: "gauge.with.dots.needle.33percent", placement: PluginPlacement.mainSidebarBottom.rawValue, presentation: PluginPresentation.section.rawValue),
        PluginManifest(id: scheduledTasksID, name: "Scheduled Tasks", version: 1, icon: "clock", placement: PluginPlacement.mainSidebar.rawValue, presentation: PluginPresentation.popover.rawValue, width: 400, height: 460),
        PluginManifest(
            id: builtInCommandsID, name: "Built-in Commands", version: 1, icon: "command", placement: PluginPlacement.composerActions.rawValue,
            presentation: PluginPresentation.headless.rawValue, commands: builtInCommands
        )
    ]

    static func isBuiltIn(_ id: String) -> Bool { manifests.contains { $0.id == id } }

    /// The built-ins as `plugin list` reports them, with each one's enabled state.
    static func records(disabled: Set<String>) -> [PluginRecord] {
        manifests.map { manifest in
            var record = PluginRecord(
                id: manifest.id, name: manifest.name, version: manifest.version ?? 0, icon: manifest.icon ?? PluginLibrary.defaultIcon,
                placement: manifest.placement, presentation: manifest.presentation, width: manifest.width, height: manifest.height,
                folder: "", entryPath: "", valid: true, errors: []
            )
            record.builtIn = true
            record.enabled = !disabled.contains(manifest.id)
            record.commands = manifest.commands ?? []
            return record
        }
    }
}

/// The plain task details a placement's context is built from, so the core
/// needs no app types.
struct PluginTaskContext: Sendable {
    struct PullRequest: Sendable, Equatable {
        var number: Int
        var url: String
        var merged: Bool
        /// Closed without merging.
        var closed = false

        /// "open", "merged" or "closed".
        var state: String { merged ? "merged" : closed ? "closed" : "open" }
    }

    struct Repository: Sendable {
        var repositoryPath: String
        var worktreePath: String
        var branch: String
        /// Not started yet: the task's first turn creates its worktree.
        var isPending = false
        /// Started, with no linked pull request and changes that may need one.
        var awaitsPullRequest = false
        var pullRequest: PullRequest?
    }

    /// A pull request of a worktree the task has since removed.
    struct PastPullRequest: Sendable {
        var repositoryPath: String
        var worktreePath = ""
        var branch = ""
        var pullRequest: PullRequest
    }

    var id: String
    var title: String
    var status: String
    var provider: String
    var isStandaloneChat: Bool
    var repositories: [Repository]
    var contextFolders: [String]
    var pastPullRequests: [PastPullRequest] = []
    /// The recurring schedule this task is a run of, if any.
    var scheduleSourceTaskID: String?
}

/// The composer's draft and the text selected in it, in UTF-16 offsets.
struct PluginComposerContext: Sendable, Equatable {
    var draft: String
    var selectionLocation: Int = 0
    var selectionLength: Int = 0

    var selectedText: String {
        let text = draft as NSString
        let location = min(max(0, selectionLocation), text.length)
        let length = min(max(0, selectionLength), text.length - location)
        return text.substring(with: NSRange(location: location, length: length))
    }
}

/// What the conversation sidebar tells its plugins about the task's folders
/// and the sidebar itself.
struct PluginWorkspaceContext: Sendable, Equatable {
    /// The diff the window shows, as `ui.openDiff` opened it.
    struct OpenDiff: Sendable, Equatable {
        var repository: String
        var path: String
        var group: String
    }

    /// Bumped whenever the task's folders may have changed on disk (a file
    /// watcher, a finished turn, a repository added or removed, or a plugin's
    /// `ui.refreshWorkspace`), so a plugin reloads what it shows.
    var revision = 0
    var openDiff: OpenDiff?
    /// The sidebar is hidden to its narrow rail, where an inline plugin has
    /// room for a count at most.
    var sidebarCollapsed = false
}

/// What the board's sidebar bottom tells its plugins about the agents: the
/// daemon's usage report (`usage.get`'s result, nil before the first read)
/// and how many tasks each provider is running.
struct PluginAgentsContext: Sendable, Equatable {
    var usage: PluginValue?
    var runningTasks: [String: Int] = [:]
    /// The providers `runningTasks` always lists.
    static let providers = ["claude", "codex"]

    var value: PluginValue {
        var counts: [String: PluginValue] = [:]
        for provider in Set(Self.providers).union(runningTasks.keys) {
            counts[provider] = .number(Double(runningTasks[provider] ?? 0))
        }
        return .object(["usage": usage ?? .null, "runningTasks": .object(counts)])
    }
}

/// What the board's sidebar tells its plugins about the scheduled tasks:
/// `schedule.list`'s tasks, as the bridge encodes them, and whether macOS
/// still waits for the user to allow the scheduler in Login Items.
struct PluginSchedulesContext: Sendable, Equatable {
    var tasks: [PluginValue] = []
    var needsLoginItemsApproval = false

    var value: PluginValue {
        .object(["tasks": .array(tasks), "needsLoginItemsApproval": .bool(needsLoginItemsApproval)])
    }
}

enum PluginContext {
    /// `Playhouse.props` for a plugin at its placement.
    static func props(
        plugin: PluginRecord,
        appearance: String,
        task: PluginTaskContext?,
        composer: PluginComposerContext?,
        workspace: PluginWorkspaceContext? = nil,
        agents: PluginAgentsContext? = nil,
        schedules: PluginSchedulesContext? = nil
    ) -> [String: PluginValue] {
        var props: [String: PluginValue] = [
            "plugin": .object([
                "id": .string(plugin.id),
                "name": .string(plugin.name),
                "version": .number(Double(plugin.version)),
                "placement": .string(plugin.placement),
                "presentation": .string(plugin.presentation)
            ]),
            "app": .object(["appearance": .string(appearance)]),
            "state": .object(plugin.state)
        ]
        let placement = PluginPlacement(rawValue: plugin.placement)
        if placement?.hasTask == true, let task {
            props["task"] = .object([
                "id": .string(task.id),
                "title": .string(task.title),
                "status": .string(task.status),
                "provider": .string(task.provider),
                "isStandaloneChat": .bool(task.isStandaloneChat),
                "scheduleSourceTaskID": task.scheduleSourceTaskID.map(PluginValue.string) ?? .null
            ])
            props["repositories"] = .array(task.repositories.map {
                .object([
                    "repositoryPath": .string($0.repositoryPath),
                    "worktreePath": .string($0.worktreePath),
                    "branch": .string($0.branch),
                    "isPending": .bool($0.isPending),
                    "awaitsPullRequest": .bool($0.awaitsPullRequest),
                    "pullRequest": $0.pullRequest.map(pullRequestValue) ?? .null
                ])
            })
            props["pastPullRequests"] = .array(task.pastPullRequests.map {
                var value = pullRequestValue($0.pullRequest).object ?? [:]
                value["repositoryPath"] = .string($0.repositoryPath)
                value["worktreePath"] = .string($0.worktreePath)
                value["branch"] = .string($0.branch)
                return .object(value)
            })
            props["contextFolders"] = .array(task.contextFolders.map(PluginValue.string))
        }
        if placement == .conversationSidebar {
            let workspace = workspace ?? PluginWorkspaceContext()
            props["workspace"] = .object([
                "revision": .number(Double(workspace.revision)),
                "openDiff": workspace.openDiff.map {
                    .object(["repository": .string($0.repository), "path": .string($0.path), "group": .string($0.group)])
                } ?? .null
            ])
            props["sidebar"] = .object(["collapsed": .bool(workspace.sidebarCollapsed)])
        }
        if placement == .mainSidebar {
            props["schedules"] = (schedules ?? PluginSchedulesContext()).value
        }
        if placement == .mainSidebarBottom {
            props["agents"] = (agents ?? PluginAgentsContext()).value
        }
        if placement == .composerActions {
            let composer = composer ?? PluginComposerContext(draft: "")
            props["composer"] = .object([
                "draft": .string(composer.draft),
                "selection": .object([
                    "location": .number(Double(composer.selectionLocation)),
                    "length": .number(Double(composer.selectionLength)),
                    "text": .string(composer.selectedText)
                ])
            ])
        }
        return props
    }

    private static func pullRequestValue(_ pullRequest: PluginTaskContext.PullRequest) -> PluginValue {
        .object([
            "number": .number(Double(pullRequest.number)), "url": .string(pullRequest.url), "merged": .bool(pullRequest.merged),
            "closed": .bool(pullRequest.closed), "state": .string(pullRequest.state)
        ])
    }

    /// The sample task a plugin is validated with.
    static let sampleTask = PluginTaskContext(
        id: "00000000-0000-0000-0000-000000000000", title: "Sample task", status: "In Progress",
        provider: "claude", isStandaloneChat: false,
        repositories: [.init(repositoryPath: "/tmp/sample-repository", worktreePath: "/tmp/sample-worktree", branch: "sample-branch")],
        contextFolders: []
    )
}

/// The user's plugins: one folder per plugin in `<data directory>/plugins`,
/// each holding `plugin.json` and its script.
struct PluginLibrary: Sendable {
    static let manifestName = "plugin.json"
    static let defaultEntry = "index.js"
    static let defaultIcon = "puzzlepiece.extension"

    let directory: URL
    var resources: URL? = PluginRuntime.bundledResources

    init(dataDirectory: String, resources: URL? = PluginRuntime.bundledResources) {
        directory = URL(fileURLWithPath: dataDirectory, isDirectory: true).appendingPathComponent("plugins", isDirectory: true)
        self.resources = resources
    }

    /// Lowercase words joined by hyphens, the plugin's folder name.
    static func isValidID(_ id: String) -> Bool {
        id.range(of: #"^[a-z0-9]+(-[a-z0-9]+)*$"#, options: .regularExpression) != nil
    }

    /// Every plugin folder, sorted by id. With `validate`, each valid-looking
    /// plugin is also rendered once headlessly with sample context, and any
    /// script error marks it invalid.
    /// The `disabled` plugins are marked so and, since they must not run,
    /// never rendered to validate them.
    func list(validate: Bool = true, disabled: Set<String> = []) -> [PluginRecord] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return entries.sorted().compactMap { entry in
            guard !entry.hasPrefix(".") else { return nil }
            let folder = directory.appendingPathComponent(entry, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
            var record = record(folder: folder, validate: validate && !disabled.contains(entry))
            record.enabled = !disabled.contains(entry)
            return record
        }
    }

    func plugin(id: String, validate: Bool = true) throws -> PluginRecord {
        guard Self.isValidID(id) else { throw PluginTreeError(message: "\"\(id)\" is not a plugin id.") }
        let folder = directory.appendingPathComponent(id, isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else {
            throw PluginLibraryError.notFound(id)
        }
        return record(folder: folder, validate: validate)
    }

    /// Whether the plugin has ever been saved, so its folder is installed.
    func isInstalled(id: String) -> Bool {
        Self.isValidID(id) && FileManager.default.fileExists(atPath: directory.appendingPathComponent(id).path)
    }

    /// Drafts and historical revisions live outside the installed-plugin listing.
    var draftDataDirectory: URL { directory.appendingPathComponent(".drafts", isDirectory: true) }
    var draftLibrary: PluginLibrary { PluginLibrary(dataDirectory: draftDataDirectory.path, resources: resources) }

    func prepareDraft(id: String) throws {
        guard Self.isValidID(id) else { throw PluginTreeError(message: "Invalid plugin id.") }
        let fm = FileManager.default
        let target = draftLibrary.directory.appendingPathComponent(id)
        guard !fm.fileExists(atPath: target.path) else { return }
        try fm.createDirectory(at: draftLibrary.directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent(id)
        if fm.fileExists(atPath: source.path) { try fm.copyItem(at: source, to: target) }
    }

    func hasDraftChanges(id: String) -> Bool {
        guard Self.isValidID(id) else { return false }
        let fm = FileManager.default
        let draft = draftLibrary.directory.appendingPathComponent(id)
        let installed = directory.appendingPathComponent(id)
        guard fm.fileExists(atPath: draft.path) else { return false }
        guard fm.fileExists(atPath: installed.path) else { return true }
        let draftPaths = Set((fm.enumerator(atPath: draft.path)?.allObjects as? [String]) ?? [])
        let installedPaths = Set((fm.enumerator(atPath: installed.path)?.allObjects as? [String]) ?? [])
        guard draftPaths == installedPaths else { return true }
        for path in draftPaths {
            let left = draft.appendingPathComponent(path).path
            let right = installed.appendingPathComponent(path).path
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: left, isDirectory: &isDirectory) else { return true }
            if !isDirectory.boolValue && !fm.contentsEqual(atPath: left, andPath: right) { return true }
        }
        return false
    }

    func discardDraft(id: String) throws {
        guard Self.isValidID(id) else { throw PluginTreeError(message: "Invalid plugin id.") }
        let fm = FileManager.default
        let target = draftLibrary.directory.appendingPathComponent(id)
        let installed = directory.appendingPathComponent(id)
        guard fm.fileExists(atPath: installed.path) else {
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            return
        }
        try fm.createDirectory(at: draftLibrary.directory, withIntermediateDirectories: true)
        let staging = draftLibrary.directory.appendingPathComponent(".reset-" + UUID().uuidString)
        try fm.copyItem(at: installed, to: staging)
        defer { try? fm.removeItem(at: staging) }
        if fm.fileExists(atPath: target.path) {
            _ = try fm.replaceItemAt(target, withItemAt: staging)
        } else { try fm.moveItem(at: staging, to: target) }
    }

    func versions(id: String) throws -> [Int] {
        guard Self.isValidID(id) else { throw PluginTreeError(message: "Invalid plugin id.") }
        let folder = directory.appendingPathComponent(".versions").appendingPathComponent(id)
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).compactMap(Int.init).sorted(by: >)
    }

    /// Publish a validated draft, preserving the installed tree before replacing it.
    func saveDraft(id: String, source: PluginLibrary? = nil, resetDraft: Bool = true) throws -> (plugin: PluginRecord, draftSyncFailed: Bool) {
        let draft = try (source ?? draftLibrary).plugin(id: id)
        guard draft.valid else { throw PluginTreeError(message: draft.errors.joined(separator: "\n")) }
        let fm = FileManager.default
        let installed = directory.appendingPathComponent(id)
        let old = try? plugin(id: id, validate: false)
        let next = max(old?.version ?? 0, (try versions(id: id).max()) ?? 0) + 1
        let staging = directory.appendingPathComponent(".publish-" + UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try fm.copyItem(at: URL(fileURLWithPath: draft.folder), to: staging)
        defer { try? fm.removeItem(at: staging) }
        let manifestURL = staging.appendingPathComponent(Self.manifestName)
        var manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: manifestURL))
        manifest.version = next
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
        if let old {
            let history = directory.appendingPathComponent(".versions").appendingPathComponent(id)
            try fm.createDirectory(at: history, withIntermediateDirectories: true)
            let backup = history.appendingPathComponent(String(old.version))
            guard !fm.fileExists(atPath: backup.path) else { throw PluginTreeError(message: "Version \(old.version) already exists.") }
            try fm.copyItem(at: installed, to: backup)
            let backupManifest = backup.appendingPathComponent(Self.manifestName)
            if let data = try? Data(contentsOf: backupManifest),
               var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                json["version"] = old.version
                do { try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: backupManifest, options: .atomic) }
                catch { try? fm.removeItem(at: backup); throw error }
            }
            do { _ = try fm.replaceItemAt(installed, withItemAt: staging) }
            catch { try? fm.removeItem(at: backup); throw error }
        } else {
            try fm.moveItem(at: staging, to: installed)
        }
        // Publication already succeeded; preserve the existing draft if refreshing it fails.
        var draftSyncFailed = false
        if resetDraft {
            do { try discardDraft(id: id) } catch { draftSyncFailed = true }
        }
        return (try plugin(id: id, validate: false), draftSyncFailed)
    }

    func restoreVersion(id: String, version: Int) throws -> (plugin: PluginRecord, draftSyncFailed: Bool) {
        guard Self.isValidID(id), version >= 0 else { throw PluginTreeError(message: "Invalid plugin version.") }
        let source = directory.appendingPathComponent(".versions").appendingPathComponent(id).appendingPathComponent(String(version))
        guard FileManager.default.fileExists(atPath: source.path) else { throw PluginTreeError(message: "Plugin version not found.") }
        // Restore through an isolated staging library: a failed restore must never
        // remove or overwrite the user's draft. Keep a dirty draft after success.
        let dirty = hasDraftChanges(id: id)
        let temporary = directory.appendingPathComponent(".restore-" + UUID().uuidString)
        let staging = PluginLibrary(dataDirectory: temporary.path, resources: resources)
        try FileManager.default.createDirectory(at: staging.directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: source, to: staging.directory.appendingPathComponent(id))
        let restored = try saveDraft(id: id, source: staging, resetDraft: false)
        var draftSyncFailed = false
        if !dirty {
            do { try discardDraft(id: id) } catch { draftSyncFailed = true }
        }
        return (restored.plugin, draftSyncFailed)
    }

    /// Removes the plugin's folder.
    func delete(id: String) throws {
        let record = try plugin(id: id, validate: false)
        let folder = URL(fileURLWithPath: record.folder, isDirectory: true).standardizedFileURL
        // Only ever a direct child of the plugins folder.
        guard folder.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path else {
            throw PluginTreeError(message: "\(folder.path) is not inside \(directory.path).")
        }
        let fm = FileManager.default
        try fm.removeItem(at: folder)
        for auxiliary in [draftLibrary.directory.appendingPathComponent(id), directory.appendingPathComponent(".versions").appendingPathComponent(id)] {
            if fm.fileExists(atPath: auxiliary.path) { try fm.removeItem(at: auxiliary) }
        }
    }

    private func record(folder: URL, validate: Bool) -> PluginRecord {
        let folderID = folder.lastPathComponent
        var errors: [String] = []
        var manifest = PluginManifest(id: folderID, name: folderID, placement: "", presentation: "")
        do {
            let data = try Data(contentsOf: folder.appendingPathComponent(Self.manifestName))
            manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        } catch let error as DecodingError {
            errors.append("\(Self.manifestName) is invalid: \(Self.describe(error))")
        } catch {
            errors.append("\(Self.manifestName) is missing.")
        }
        if errors.isEmpty {
            if manifest.id != folderID { errors.append("The manifest's id \"\(manifest.id)\" does not match its folder \"\(folderID)\".") }
            if !Self.isValidID(folderID) { errors.append("The folder name \"\(folderID)\" must be lowercase words joined by hyphens.") }
            if manifest.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { errors.append("The manifest needs a name.") }
            if PluginPlacement(rawValue: manifest.placement) == nil {
                errors.append("Unknown placement \"\(manifest.placement)\". Placements: \(PluginPlacement.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            if let presentation = PluginPresentation(rawValue: manifest.presentation) {
                if let placement = PluginPlacement(rawValue: manifest.placement), let problem = presentation.placementError(placement) {
                    errors.append(problem)
                }
            } else {
                errors.append("Unknown presentation \"\(manifest.presentation)\". Presentations: \(PluginPresentation.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            if BuiltInPlugins.isBuiltIn(folderID) { errors.append("\"\(folderID)\" is a built-in plugin's id.") }
            errors += Self.commandErrors(manifest.commands ?? [], presentation: PluginPresentation(rawValue: manifest.presentation), hasEvents: !(manifest.events ?? []).isEmpty)
            errors += Self.serviceErrors(events: manifest.events ?? [], mcpTools: manifest.mcpTools)
        }
        let entry = folder.appendingPathComponent(manifest.entry ?? Self.defaultEntry)
        let entryInside = entry.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/")
        if !entryInside {
            errors.append("The entry \"\(manifest.entry ?? "")\" must be inside the plugin's folder.")
        } else if errors.isEmpty, !FileManager.default.fileExists(atPath: entry.path) {
            errors.append("The entry script \(entry.lastPathComponent) is missing.")
        }
        var record = PluginRecord(
            id: folderID, name: manifest.name, version: manifest.version ?? 0, icon: manifest.icon ?? Self.defaultIcon,
            placement: manifest.placement, presentation: manifest.presentation,
            width: manifest.width, height: manifest.height,
            folder: folder.path, entryPath: entry.path, valid: errors.isEmpty, errors: errors
        )
        record.commands = manifest.commands ?? []
        record.events = manifest.events ?? []
        record.mcpTools = manifest.mcpTools
        if validate, errors.isEmpty {
            let renderErrors = self.renderErrors(record)
            if !renderErrors.isEmpty {
                record = PluginRecord(
                    id: record.id, name: record.name, version: record.version, icon: record.icon, placement: record.placement,
                    presentation: record.presentation, width: record.width, height: record.height,
                    folder: record.folder, entryPath: record.entryPath, valid: false, errors: renderErrors
                )
                record.commands = manifest.commands ?? []
                record.events = manifest.events ?? []
                record.mcpTools = manifest.mcpTools
            }
        }
        return record
    }

    /// Renders the plugin once with sample context and its timers settled.
    /// Host calls are answered with an error, since nothing is mounted.
    private func renderErrors(_ record: PluginRecord) -> [String] {
        do {
            let source = try String(contentsOfFile: record.entryPath, encoding: .utf8)
            let props = PluginContext.props(
                plugin: record, appearance: "dark", task: PluginContext.sampleTask,
                composer: PluginComposerContext(draft: "Sample draft", selectionLocation: 0, selectionLength: 6)
            )
            let runtime = try PluginRuntime(
                source: source, sourceName: URL(fileURLWithPath: record.entryPath).lastPathComponent,
                props: props, resources: resources, timers: .manual
            )
            runtime.runDueTimers()
            for call in runtime.pendingHostCalls {
                runtime.answerHostCall(call.id, result: .failure(PluginHostError(code: "unavailable", message: "Host calls are not answered while a plugin is validated.")))
            }
            runtime.runDueTimers()
            // Every declared command needs its handlers registered.
            let registered = Set(runtime.registeredCommands())
            let missing = record.commands.map(\.name).filter { !registered.contains($0) }
            return runtime.errors + missing.map { "The command /\($0) is declared but its script never calls Playhouse.commands.register(\"\($0)\", …)." }
        } catch {
            return [error.localizedDescription]
        }
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, _): "missing \"\(key.stringValue)\""
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            "\"\(context.codingPath.map(\.stringValue).joined(separator: "."))\" has the wrong type"
        case .dataCorrupted(let context): context.debugDescription
        @unknown default: error.localizedDescription
        }
    }
}

/// What a host refuses from a plugin, the same in the window and in
/// `plugin render`, so the headless check matches what the user sees.
enum PluginHostRules {
    static let uiCalls: Set<String> = ["close", "openTask", "openDiff", "refreshWorkspace", "moveTask", "resolveConflicts", "alert", "openURL", "confirm", "newTask", "openLoginItems", "composer.setDraft", "composer.insertText", "composer.replaceSelection", "composer.focus", "composer.setMode", "openSkills", "editPlugin"]

    /// Nil when the host should answer `call`. `placement` is nil for a plugin
    /// rendered from a file or a catalog page, which may call anything.
    static func refusal(kind: String, name: String, placement: PluginPlacement?, arguments: PluginValue = .null) -> PluginHostError? {
        switch kind {
        case "bridge":
            // Every other bridge command is the plugin's to call; rendering plugins would recurse,
            // and the daemon alone delivers events to plugins' background halves.
            if name == "plugin.render" { return PluginHostError(code: "invalid_argument", message: "A plugin can't render plugins.") }
            if name == "plugin.service" || name == "plugin.services" {
                return PluginHostError(code: "invalid_argument", message: "A plugin can't run plugins' background halves; the daemon delivers their events.")
            }
            return nil
        case "ui":
            guard uiCalls.contains(name) else { return PluginHostError(code: "invalid_argument", message: "Unknown host call ui.\(name).") }
            if name.hasPrefix("composer."), let placement, !placement.hasTask || placement == .taskItem {
                return PluginHostError(code: "unavailable", message: "There is no composer at the \(placement.title) placement.")
            }
            if ["openDiff", "refreshWorkspace"].contains(name), let placement, !placement.hasTask {
                return PluginHostError(code: "unavailable", message: "There is no task's workspace at the \(placement.title) placement.")
            }
            // Only the board answers these, for the cards it shows.
            if ["moveTask", "resolveConflicts", "alert"].contains(name), let placement, placement != .taskItem {
                return PluginHostError(code: "unavailable", message: "Only a task card's plugin can call ui.\(name), not one at the \(placement.title) placement.")
            }
            // The board window and the composer's commands ask the user to confirm.
            if name == "confirm", let placement, !placement.isOnBoard, placement != .composerActions {
                return PluginHostError(code: "unavailable", message: "Only a plugin on the board or in the composer can call ui.confirm, not one at the \(placement.title) placement.")
            }
            // The conversation window opens the Skills page and the plugin editor.
            if ["openSkills", "editPlugin"].contains(name), let placement, !placement.hasTask || placement == .taskItem {
                return PluginHostError(code: "unavailable", message: "Only a plugin in the conversation can call ui.\(name), not one at the \(placement.title) placement.")
            }
            if name == "composer.setMode", !["plan", "goal"].contains(arguments.object?["mode"]?.string ?? "") {
                return PluginHostError(code: "invalid_argument", message: "composer.setMode's mode is \"plan\" or \"goal\".")
            }
            if name == "editPlugin", (arguments.object?["pluginID"]?.string ?? "").isEmpty {
                return PluginHostError(code: "invalid_argument", message: "editPlugin needs a pluginID.")
            }
            // Only the board opens a new task or the Login Items setting.
            if ["newTask", "openLoginItems"].contains(name), let placement, !placement.isOnBoard {
                return PluginHostError(code: "unavailable", message: "Only a plugin on the board can call ui.\(name), not one at the \(placement.title) placement.")
            }
            if name == "newTask", let schedule = arguments.object?["schedule"], schedule != .null,
               !["once", "recurring"].contains(schedule.string ?? "") {
                return PluginHostError(code: "invalid_argument", message: "newTask's schedule is \"once\", \"recurring\" or null.")
            }
            if name == "openURL", openableURL(arguments) == nil {
                return PluginHostError(code: "invalid_argument", message: "openURL needs an http or https URL.")
            }
            return nil
        case "net":
            // fetch reaches the network from every placement; `PluginNetwork` checks its URL.
            return name == "fetch" ? nil : PluginHostError(code: "invalid_argument", message: "Unknown host call net.\(name).")
        default:
            return PluginHostError(code: "invalid_argument", message: "Unknown host call \(kind).\(name).")
        }
    }
}

extension PluginHostRules {
    /// The web page `ui.openURL` opens; only http and https.
    static func openableURL(_ arguments: PluginValue) -> URL? {
        guard let url = arguments.object?["url"]?.string.flatMap(URL.init(string:)),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil else { return nil }
        return url
    }
}

enum PluginLibraryError: LocalizedError {
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let id): "No plugin has the id \"\(id)\"."
        }
    }
}
