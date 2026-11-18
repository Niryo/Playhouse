import Foundation

// MARK: - Model

/// One row of the command list: a plugin's `/` command, enabled or with why it can't run.
struct SlashCommandEntry: Codable, Equatable, Identifiable, Sendable {
    let name: String
    /// The plugin that exposes the command.
    let pluginID: String
    let detail: String
    let icon: String
    /// Choosing it opens the command's own list rather than running it.
    let list: Bool
    let enabled: Bool
    let disabledReason: String?
    var id: String { name }
}

/// What the `/` menu shows for the text typed after the `/`: the matching commands, or,
/// once a command with its own list is typed in full, that command's list, its items
/// filtered by what follows the command.
struct SlashCommandMenu: Codable, Equatable, Sendable {
    let query: String
    /// The command whose list is shown, or nil while commands are listed.
    let command: String?
    /// The text after the command's name that narrows its items.
    let filter: String
    let commands: [SlashCommandEntry]
    /// The listed command's list with only the items that match `filter`.
    var list: PluginCommandList?
}

// MARK: - Catalog

/// Which commands the `/` menu offers: every `/` command the active plugins
/// declare, the Built-in Commands plugin's first. The composer and the CLI's
/// `slash-commands` read it alike.
enum SlashCommandCatalog {
    /// Splits the text typed after `/` into the command's name and, after the first
    /// space, the filter of its items.
    static func parse(_ query: String) -> (name: String, filter: String?) {
        guard let space = query.firstIndex(of: " ") else { return (query, nil) }
        return (String(query[..<space]), String(query[query.index(after: space)...]))
    }

    /// The plugins whose commands the menu offers, each command once: the built-in
    /// plugins first, then the installed ones by id; a name an earlier plugin
    /// already took is skipped.
    static func commandPlugins(_ plugins: [PluginRecord]) -> [(plugin: PluginRecord, commands: [PluginCommandManifest])] {
        var taken: Set<String> = []
        let ordered = plugins.filter { $0.builtIn } + plugins.filter { !$0.builtIn }.sorted { $0.id < $1.id }
        return ordered.filter { $0.isActive && !$0.commands.isEmpty }.compactMap { plugin in
            let commands = plugin.commands.filter { taken.insert($0.name).inserted }
            return commands.isEmpty ? nil : (plugin, commands)
        }
    }

    /// The command whose list the menu shows for `query`: a command with its own list
    /// typed in full, alone or followed by a filter.
    static func listedCommand(_ query: String, in entries: [SlashCommandEntry]) -> SlashCommandEntry? {
        let name = parse(query).name.lowercased()
        return entries.first { $0.name == name && $0.list }
    }

    /// The commands whose name starts with `name`, every command for an empty name.
    static func commands(matching name: String, in entries: [SlashCommandEntry]) -> [SlashCommandEntry] {
        let needle = name.lowercased()
        return entries.filter { needle.isEmpty || $0.name.hasPrefix(needle) }
    }

    /// The items whose title, detail or keywords contain `filter`, those whose
    /// title starts with it first.
    static func filter(_ items: [PluginCommandItem], by filter: String) -> [PluginCommandItem] {
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return items }
        func text(_ item: PluginCommandItem) -> [String] { [item.title, item.detail ?? ""] + (item.keywords ?? []) }
        let matching = items.filter { text($0).contains { $0.lowercased().contains(needle) } }
        func prefixed(_ item: PluginCommandItem) -> Bool {
            [item.title, item.title.hasPrefix("@") ? String(item.title.dropFirst()) : item.title].contains { $0.lowercased().hasPrefix(needle) }
        }
        return matching.filter(prefixed) + matching.filter { !prefixed($0) }
    }

    /// The menu for `query`, given the commands and, for a listed command, its unfiltered list.
    static func menu(query: String, entries: [SlashCommandEntry], list: PluginCommandList?) -> SlashCommandMenu {
        let parsed = parse(query)
        if let command = listedCommand(query, in: entries) {
            let filter = parsed.filter ?? ""
            var filtered = list
            filtered?.items = Self.filter(list?.items ?? [], by: filter)
            return SlashCommandMenu(query: query, command: command.name, filter: filter, commands: [], list: filtered)
        }
        // A space after a command without a list ends the command: nothing to show.
        let commands = parsed.filter == nil ? commands(matching: parsed.name, in: entries) : []
        return SlashCommandMenu(query: query, command: nil, filter: "", commands: commands, list: nil)
    }
}

// MARK: - Manager

/// Runs the plugins' `/` commands for one task, the same way in the window and in
/// the bridge daemon (`slash.list`, `slash.run`): each with the composer
/// placement's context (`props`), its host calls answered by `host`, which the
/// window gives its `PluginHost` and the daemon its headless host.
struct SlashCommandManager {
    /// Every plugin; only the active ones' commands are offered.
    let plugins: [PluginRecord]
    let props: (PluginRecord) -> [String: PluginValue]
    let host: (PluginRecord) -> PluginCommandHost

    /// The Swift or JavaScript handlers of `plugin`'s commands.
    static func handler(for plugin: PluginRecord) throws -> any PluginCommandHandler {
        if plugin.id == BuiltInPlugins.builtInCommandsID { return BuiltInCommandsPlugin() }
        guard !plugin.builtIn else { throw PluginHostError(code: "not_found", message: "The built-in plugin \(plugin.id) has no commands.") }
        return try JavaScriptCommandHandler(plugin: plugin.at(.composerActions))
    }

    /// Every offered command with whether it can run now. A plugin whose
    /// `available` handler fails has its commands listed disabled, with the error.
    func entries() async -> [SlashCommandEntry] {
        var entries: [SlashCommandEntry] = []
        for (plugin, commands) in SlashCommandCatalog.commandPlugins(plugins) {
            let context = plugin.at(.composerActions)
            var availability: [String: PluginCommandAvailability] = [:]
            var failure: String?
            do {
                availability = try await Self.handler(for: plugin).availability(props: props(context), host: host(context))
            } catch {
                failure = error.localizedDescription
            }
            entries += commands.map { command in
                let state = availability[command.name] ?? PluginCommandAvailability()
                return SlashCommandEntry(
                    name: command.name, pluginID: plugin.id, detail: command.detail, icon: command.icon ?? plugin.icon,
                    list: command.hasList, enabled: failure == nil && state.enabled, disabledReason: failure ?? (state.enabled ? nil : state.reason)
                )
            }
        }
        return entries
    }

    /// `entry`'s own list, unfiltered; `complete` asks for a pending list's slower details.
    func list(_ entry: SlashCommandEntry, filter: String = "", complete: Bool) async throws -> PluginCommandList {
        guard entry.list else {
            throw PluginHostError(code: "invalid_argument", message: "/\(entry.name) has no list to choose an item from.")
        }
        let (plugin, handler) = try resolve(entry)
        return try await handler.list(entry.name, filter: filter, complete: complete, props: props(plugin), host: host(plugin))
    }

    /// The item `id` of `entry`'s complete list.
    func item(_ entry: SlashCommandEntry, id: String) async throws -> PluginCommandItem {
        guard let item = try await list(entry, complete: true).items.first(where: { $0.id == id }) else {
            throw PluginHostError(code: "not_found", message: "/\(entry.name) lists no item \(id).")
        }
        return item
    }

    /// Runs `entry` (`run`), chooses `item` from its list (`choose`) or presses one of
    /// the item's buttons (`press`): a command with a list only through an item, an
    /// enabled button of that item.
    func act(_ entry: SlashCommandEntry, item: PluginCommandItem? = nil, button: String? = nil, filter: String = "") async throws -> PluginCommandOutcome {
        if entry.list, item == nil {
            throw PluginHostError(code: "invalid_argument", message: "/\(entry.name) opens a list; choose one of its items.")
        }
        if button != nil, item == nil {
            throw PluginHostError(code: "invalid_argument", message: "A button needs the item whose button it is.")
        }
        let (plugin, handler) = try resolve(entry)
        var request: [String: PluginValue] = ["filter": .string(filter)]
        let phase: PluginCommandPhase
        if let item {
            guard entry.list else {
                throw PluginHostError(code: "invalid_argument", message: "/\(entry.name) has no list to choose an item from.")
            }
            request["item"] = try PluginValue(encoding: item)
            phase = button == nil ? .choose : .press
            if let button {
                guard let pressed = item.buttons?.first(where: { $0.id == button }) else {
                    throw PluginHostError(code: "not_found", message: "The item \(item.id) has no button \(button).")
                }
                if pressed.disabled == true {
                    throw PluginHostError(code: "unavailable", message: pressed.help ?? "The button \(button) is disabled.")
                }
                request["button"] = .string(button)
            }
        } else {
            phase = .run
        }
        return try await handler.act(phase, command: entry.name, request: .object(request), props: props(plugin), host: host(plugin))
    }

    /// A disabled command's list can't open and it can't run.
    private func resolve(_ entry: SlashCommandEntry) throws -> (PluginRecord, any PluginCommandHandler) {
        guard entry.enabled else {
            throw PluginHostError(code: "unavailable", message: entry.disabledReason ?? "/\(entry.name) can't run now.")
        }
        guard let plugin = plugins.first(where: { $0.id == entry.pluginID && $0.isActive }) else {
            throw PluginHostError(code: "not_found", message: "The plugin \(entry.pluginID) that exposes /\(entry.name) isn't enabled.")
        }
        let context = plugin.at(.composerActions)
        return (context, try Self.handler(for: plugin))
    }
}

// MARK: - Text

/// Where a `/` command is typed in the composer: anywhere a `/` starts a word.
enum SlashCommandText {
    /// The command being typed before the caret: the `/`'s UTF-16 location, the length
    /// up to the caret, and the text after the `/`. The text can hold one space after a
    /// command with its own list (`/mcp git`, `hasList` says which names have one), whose
    /// items it then filters. Nil when the caret is not in such a command.
    static func activeQuery(in text: String, caret: Int, hasList: (String) -> Bool) -> (location: Int, length: Int, query: String)? {
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
        guard let name = command(from: commandStart, to: start - 1), hasList(name.lowercased()) else { return nil }
        return query(from: commandStart)
    }

    private static func isWhitespace(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x0A || unit == 0x09 || unit == 0x0D || unit == 0xA0
    }
}
