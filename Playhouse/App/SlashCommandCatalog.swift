import Foundation

// MARK: - Model

/// A command the composer's `/` menu offers, in the order the menu lists them.
enum SlashCommand: String, Codable, Sendable, CaseIterable {
    case mcp, plan, goal, skill, login, plugin

    var detail: String {
        switch self {
        case .mcp: "Mention an MCP server, manage it, or sign in to it"
        case .plan: "Turn on plan mode"
        case .goal: "Turn on goal mode"
        case .skill: "Mention a skill or open its editor"
        case .login: "Sign in to an agent"
        case .plugin: "Create a plugin or manage yours"
        }
    }

    var icon: String {
        switch self {
        case .mcp: "server.rack"
        case .plan: "list.bullet.clipboard"
        case .goal: "scope"
        case .skill: "sparkles"
        case .login: "person.crop.circle"
        case .plugin: "puzzlepiece.extension"
        }
    }

    /// Choosing the command opens its own list instead of acting at once.
    var hasItems: Bool {
        switch self {
        case .mcp, .skill, .login, .plugin: true
        case .plan, .goal: false
        }
    }
}

/// One row of the command list: a command the task's provider can run, or one it
/// can't, with why.
struct SlashCommandEntry: Codable, Equatable, Identifiable, Sendable {
    let command: SlashCommand
    let detail: String
    let enabled: Bool
    let disabledReason: String?
    var id: String { command.rawValue }
}

enum SlashCommandItemKind: String, Codable, Sendable {
    case mcp, skill, login, plugin
    case createPlugin = "create-plugin"
}

/// One row of a command's own list: an MCP server, a skill, an agent to sign in to,
/// Create Plugin, or an installed plugin.
struct SlashCommandItem: Codable, Equatable, Identifiable, Sendable {
    /// `<kind>:<targetID>`.
    let id: String
    let kind: SlashCommandItemKind
    /// The MCP server's or skill's catalog ID, the provider, or the plugin's ID.
    let targetID: String
    let title: String
    let detail: String
    /// What choosing an MCP server or skill mentions, after the `@`.
    var handle: String?
    /// The agents that reported the MCP server needs a sign-in.
    var needsSignIn: [ConversationProvider] = []
    /// The gear can open the item's editor (a skill with a folder, any listed MCP server).
    var editable = false
}

/// What the `/` menu shows for the text typed after the `/`: the matching commands, or,
/// once a command with its own list is typed in full, that command's items.
struct SlashCommandMenu: Codable, Equatable, Sendable {
    let query: String
    /// The command whose items are listed, or nil while commands are listed.
    let command: SlashCommand?
    /// The text after the command's name that narrows its items.
    let filter: String
    let commands: [SlashCommandEntry]
    let items: [SlashCommandItem]
    /// An agent that couldn't say which MCP servers need a sign-in, with why.
    var statusErrors: [String: String] = [:]
}

// MARK: - Catalog

/// Which commands and items the `/` menu offers. The composer and the CLI's
/// `slash-commands list` read it alike: the window filters the items the bridge
/// returns with the same functions the bridge uses.
enum SlashCommandCatalog {
    /// Splits the text typed after `/` into the command's name and, after the first
    /// space, the filter of its items.
    static func parse(_ query: String) -> (name: String, filter: String?) {
        guard let space = query.firstIndex(of: " ") else { return (query, nil) }
        return (String(query[..<space]), String(query[query.index(after: space)...]))
    }

    /// The command whose items the menu lists for `query`: a command with its own list
    /// typed in full, alone or followed by a filter.
    static func listedCommand(_ query: String) -> SlashCommand? {
        let parsed = parse(query)
        guard let command = SlashCommand(rawValue: parsed.name.lowercased()), command.hasItems else { return nil }
        return command
    }

    static func entry(_ command: SlashCommand, provider: ConversationProvider) -> SlashCommandEntry {
        if command == .goal, !provider.supportsGoals {
            return SlashCommandEntry(
                command: command, detail: command.detail, enabled: false,
                disabledReason: "Goal mode isn't supported by \(provider.displayName)"
            )
        }
        return SlashCommandEntry(command: command, detail: command.detail, enabled: true, disabledReason: nil)
    }

    /// The commands whose name starts with `name`, every command for an empty name.
    static func commands(matching name: String, provider: ConversationProvider) -> [SlashCommandEntry] {
        let needle = name.lowercased()
        return SlashCommand.allCases.filter { needle.isEmpty || $0.rawValue.hasPrefix(needle) }.map { entry($0, provider: provider) }
    }

    /// The items whose title, handle or detail contains `filter`, those whose title
    /// starts with it first.
    static func filter(_ items: [SlashCommandItem], by filter: String) -> [SlashCommandItem] {
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return items }
        // Create Plugin stays first while it matches "create".
        let matching = items.filter {
            $0.title.lowercased().contains(needle) || ($0.handle?.lowercased().contains(needle) ?? false) || $0.detail.lowercased().contains(needle)
        }
        let prefixed = matching.filter { $0.title.lowercased().hasPrefix(needle) }
        return prefixed + matching.filter { !$0.title.lowercased().hasPrefix(needle) }
    }

    /// The menu for `query`, given each list's unfiltered items.
    static func menu(query: String, provider: ConversationProvider, items: (SlashCommand) -> [SlashCommandItem]) -> SlashCommandMenu {
        let parsed = parse(query)
        if let command = listedCommand(query) {
            let filter = parsed.filter ?? ""
            return SlashCommandMenu(query: query, command: command, filter: filter, commands: [], items: Self.filter(items(command), by: filter))
        }
        // A space after a command without a list ends the command: nothing to show.
        let commands = parsed.filter == nil ? commands(matching: parsed.name, provider: provider) : []
        return SlashCommandMenu(query: query, command: nil, filter: "", commands: commands, items: [])
    }

    // MARK: Items

    /// The MCP servers the composer can mention, each with the agents that need a sign-in to it.
    static func mcpItems(_ mentions: [MentionItem], status: McpStatusReport?) -> [SlashCommandItem] {
        mentions.filter { $0.kind == .mcp }.map { mention in
            let serverID = String(mention.id.dropFirst("mcp:".count))
            return SlashCommandItem(
                id: "mcp:" + serverID, kind: .mcp, targetID: serverID, title: mention.title, detail: mention.detail,
                handle: mention.handle, needsSignIn: signInNeeded(mention.title, status: status), editable: true
            )
        }
    }

    /// The providers that reported the server named `name` needs a sign-in.
    static func signInNeeded(_ name: String, status: McpStatusReport?) -> [ConversationProvider] {
        guard let status else { return [] }
        return [ConversationProvider.claude, .codex].filter { provider in
            let reports = provider == .claude ? status.claude : status.codex
            return reports.contains { $0.name == name && $0.needsSignIn }
        }
    }

    /// The skills the composer can mention; the gear edits the editable ones (not built-in skills).
    static func skillItems(_ mentions: [MentionItem], skills: SkillCatalog) -> [SlashCommandItem] {
        mentions.filter { $0.kind == .skill }.map { mention in
            let skillID = String(mention.id.dropFirst("skill:".count))
            return SlashCommandItem(
                id: "skill:" + skillID, kind: .skill, targetID: skillID, title: mention.title, detail: mention.detail,
                handle: mention.handle, editable: skills.skill(id: skillID)?.editable == true
            )
        }
    }

    /// Both agents, the task's own first.
    static func loginItems(provider: ConversationProvider) -> [SlashCommandItem] {
        ([provider] + ConversationProvider.allCases.filter { $0 != provider }).map { option in
            SlashCommandItem(
                id: "login:" + option.rawValue, kind: .login, targetID: option.rawValue,
                title: "Sign in to \(option.displayName)", detail: option == provider ? "This task's agent" : ""
            )
        }
    }

    /// Create Plugin, then the user's own plugins (not the built-in ones).
    static func pluginItems(_ plugins: [PluginRecord]) -> [SlashCommandItem] {
        let create = SlashCommandItem(
            id: "plugin:create", kind: .createPlugin, targetID: "", title: "Create Plugin", detail: "Turn on Add Plugin mode to choose where it goes"
        )
        return [create] + plugins.filter { !$0.builtIn }.map { plugin in
            let placement = PluginPlacement(rawValue: plugin.placement)?.title ?? plugin.placement
            return SlashCommandItem(
                id: "plugin:" + plugin.id, kind: .plugin, targetID: plugin.id, title: plugin.name,
                detail: placement + (plugin.enabled ? "" : " (Disabled)"), editable: true
            )
        }
    }
}

// MARK: - Manager

/// Builds the `/` menu the bridge's `slash.list` returns: a command's own list reads only
/// its source, and `/mcp` asks both agents which servers need a sign-in when `mcpStatus` is given.
@MainActor
struct SlashCommandManager {
    let mentions: MentionCatalogManager
    let skills: SkillCatalogManager

    func menu(
        query: String, task: any ConversationSubject, tasks: BoardTaskManager, settings: WorkspaceSettingsManager,
        mcpStatus: (() async -> McpStatusReport?)?, plugins: () async throws -> [PluginRecord]
    ) async throws -> SlashCommandMenu {
        let listed = SlashCommandCatalog.listedCommand(query)
        var items: [SlashCommandItem] = []
        var statusErrors: [String: String] = [:]
        switch listed {
        case .mcp:
            let catalog = await mentions.catalog(for: task, tasks: tasks, settings: settings)
            let status = await mcpStatus?()
            statusErrors = status?.errors ?? [:]
            items = SlashCommandCatalog.mcpItems(catalog.items, status: status)
        case .skill:
            let catalog = await mentions.catalog(for: task, tasks: tasks, settings: settings)
            items = SlashCommandCatalog.skillItems(catalog.items, skills: skills.catalog(roots: SkillRoot.roots(for: task)))
        case .login:
            items = SlashCommandCatalog.loginItems(provider: task.conversationProvider)
        case .plugin:
            items = SlashCommandCatalog.pluginItems(try await plugins())
        case .plan, .goal, nil:
            break
        }
        var menu = SlashCommandCatalog.menu(query: query, provider: task.conversationProvider) { _ in items }
        menu.statusErrors = statusErrors
        return menu
    }
}

// MARK: - Text

/// Where a `/` command is typed in the composer: anywhere a `/` starts a word.
enum SlashCommandText {
    /// The command being typed before the caret: the `/`'s UTF-16 location, the length
    /// up to the caret, and the text after the `/`. The text can hold one space after a
    /// command with its own list (`/mcp git`), whose items it then filters. Nil when the
    /// caret is not in such a command.
    static func activeQuery(in text: String, caret: Int) -> (location: Int, length: Int, query: String)? {
        let utf16 = Array(text.utf16)
        guard caret >= 1, caret <= utf16.count else { return nil }
        func wordStart(before end: Int) -> Int {
            var start = end
            while start > 0, !isWhitespace(utf16[start - 1]) { start -= 1 }
            return start
        }
        func command(from start: Int, to end: Int) -> String? {
            guard start < end, utf16[start] == 0x2F else { return nil }
            let name = String(utf16CodeUnits: Array(utf16[(start + 1)..<end]), count: end - start - 1)
            return name.contains("/") ? nil : name
        }
        func query(from start: Int) -> (location: Int, length: Int, query: String) {
            (start, caret - start, String(utf16CodeUnits: Array(utf16[(start + 1)..<caret]), count: caret - start - 1))
        }
        let start = wordStart(before: caret)
        if command(from: start, to: caret) != nil { return query(from: start) }
        // The filter after a command with its own list, separated from it by one space.
        guard start >= 2, utf16[start - 1] == 0x20 else { return nil }
        let commandStart = wordStart(before: start - 1)
        guard let name = command(from: commandStart, to: start - 1),
              SlashCommand(rawValue: name.lowercased())?.hasItems == true else { return nil }
        return query(from: commandStart)
    }

    private static func isWhitespace(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x0A || unit == 0x09 || unit == 0x0D || unit == 0xA0
    }
}
