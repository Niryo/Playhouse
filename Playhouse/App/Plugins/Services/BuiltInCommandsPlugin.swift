import Foundation

/// The "Built-in Commands" plugin (`BuiltInPlugins.builtInCommandsID`): the
/// composer's `/mcp`, `/plan`, `/goal`, `/skill`, `/login` and `/plugin`. It is
/// a headless plugin like any installed one: it reads the task's provider,
/// MCP servers, skills and plugins through bridge commands and acts through
/// `ui` calls, each answered by `host` exactly as a script's would be, so an
/// installed plugin could offer the same commands.
struct BuiltInCommandsPlugin: PluginCommandHandler {
    func perform(
        _ phase: PluginCommandPhase, command: String, request: PluginValue,
        props: [String: PluginValue], host: @escaping PluginCommandHost
    ) async throws -> PluginValue {
        let calls = Calls(host: host, taskID: props["task"]?.object?["id"]?.string ?? "")
        let request = request.object ?? [:]
        let item = request["item"]?.object ?? [:]
        let data = item["data"]?.object ?? [:]
        switch (phase, command) {
        case (.available, _):
            let provider = try await calls.provider()
            guard !provider.supportsGoals else { return .object([:]) }
            return .object(["goal": .object([
                "enabled": .bool(false), "reason": .string("Goal mode isn't supported by \(provider.name.displayName)")
            ])])
        case (.run, "plan"), (.run, "goal"):
            _ = try await calls.ui("composer.setMode", ["mode": .string(command)])
            return .object([:])
        case (.list, "mcp"):
            return try await mcpList(calls, complete: request["complete"]?.bool == true)
        case (.list, "skill"):
            return try await skillList(calls)
        case (.list, "login"):
            return try await loginList(calls)
        case (.list, "plugin"):
            return try await pluginList(calls)
        case (.choose, "mcp"), (.choose, "skill"):
            // Mentions the server or skill in place of the typed command.
            return .object(["text": .string("@" + (data["handle"]?.string ?? item["title"]?.string ?? "") + " ")])
        case (.press, "mcp"):
            let button = request["button"]?.string ?? ""
            if button == "gear" {
                _ = try await calls.ui("openSkills", ["mcpServerID": data["serverID"] ?? .null])
            } else if button.hasPrefix("signin-") {
                _ = try await calls.ui("openSkills", ["signIn": .object([
                    "name": data["name"] ?? .null, "provider": .string(String(button.dropFirst("signin-".count)))
                ])])
            }
            return .object([:])
        case (.press, "skill"):
            _ = try await calls.ui("openSkills", ["skillID": data["skillID"] ?? .null])
            return .object([:])
        case (.choose, "login"):
            // Starts the sign-in as the Agents info section's Log in does and
            // opens the link the agent returns, when it returns one.
            let login = try await calls.bridge("usage.login", ["provider": data["provider"] ?? .null])
            if let url = login.object?["loginURL"]?.string, !url.isEmpty {
                _ = try await calls.ui("openURL", ["url": .string(url)])
            }
            return .object([:])
        case (.choose, "plugin"):
            if item["id"]?.string == "create-plugin" {
                _ = try await calls.bridge("plugin.mode", ["enabled": .bool(true)])
            } else {
                _ = try await calls.ui("editPlugin", ["pluginID": data["pluginID"] ?? .null])
            }
            return .object([:])
        case (.press, "plugin"):
            let pluginID = data["pluginID"] ?? .null
            switch request["button"]?.string {
            case "edit":
                _ = try await calls.ui("editPlugin", ["pluginID": pluginID])
            case "delete":
                let confirmed = try await calls.ui("confirm", [
                    "title": .string("Delete the plugin \(item["title"]?.string ?? "")?"), "message": .string("Its folder is removed."),
                    "confirm": .string("Delete"), "destructive": .bool(true)
                ])
                if confirmed.bool == true { _ = try await calls.bridge("plugin.delete", ["pluginID": pluginID]) }
            default:
                break
            }
            return .object([:])
        default:
            throw PluginHostError(code: "not_found", message: "/\(command) has no \(phase.rawValue) handler.")
        }
    }

    // MARK: Lists

    /// Both agents, Claude first, so sign-in buttons keep one order.
    private static let providers = ConversationProvider.allCases.sorted { $0.displayName < $1.displayName }

    /// The MCP servers the composer can mention. The quick list comes first;
    /// asked again with `complete`, it also says which agents need a sign-in
    /// to each, which takes both agents a few seconds to report.
    private func mcpList(_ calls: Calls, complete: Bool) async throws -> PluginValue {
        let mentions = try await calls.mentions(kind: "mcp")
        var status: [String: PluginValue] = [:]
        var errors: [String] = []
        if complete {
            status = try await calls.bridge("mcp.status", ["taskID": .string(calls.taskID)]).object ?? [:]
            errors = (status["errors"]?.object ?? [:]).sorted { $0.key < $1.key }.compactMap { provider, error in
                error.string.map { "\(ConversationProvider(rawValue: provider)?.displayName ?? provider): \($0)" }
            }
        }
        let items: [PluginValue] = mentions.map { mention in
            let name = mention["title"]?.string ?? ""
            let handle = mention["handle"]?.string ?? name
            let serverID = String((mention["id"]?.string ?? "").dropFirst("mcp:".count))
            let signIns: [PluginValue] = Self.providers.filter { provider in
                (status[provider.rawValue]?.array ?? []).contains {
                    $0.object?["name"]?.string == name && $0.object?["needsSignIn"]?.bool == true
                }
            }.map { provider in
                .object([
                    "id": .string("signin-" + provider.rawValue), "label": .string("Sign in for \(provider.displayName)"),
                    "help": .string("Sign in to \(name) for \(provider.displayName)"), "icon": .string("key"),
                    "text": .string(provider.displayName), "style": .string("bordered")
                ])
            }
            return .object([
                "id": .string("mcp-" + handle), "title": .string("@" + handle), "detail": mention["detail"] ?? .null,
                "icon": .string("server.rack"), "help": .string("Mention \(name)"), "keywords": .array([.string(name), .string(handle)]),
                "buttons": .array(signIns + [.object([
                    "id": .string("gear"), "label": .string("Manage"), "help": .string("Open \(name) in the MCP page"),
                    "icon": .string("gearshape")
                ])]),
                "data": .object(["serverID": .string(serverID), "name": .string(name), "handle": .string(handle)])
            ])
        }
        return .object([
            "title": .string("MCP servers"), "items": .array(items),
            "pending": complete ? .null : .string("Checking sign-in…"),
            "empty": .string(errors.isEmpty ? "No MCP servers" : "No MCP servers. " + errors.joined(separator: " ")),
            "noMatch": .string("No MCP server matches")
        ])
    }

    /// The skills the composer can mention; the gear edits the ones with a folder.
    private func skillList(_ calls: Calls) async throws -> PluginValue {
        let mentions = try await calls.mentions(kind: "skill")
        let catalog = try await calls.bridge("skills.list", ["taskID": .string(calls.taskID)]).object ?? [:]
        let skills = (catalog["repositories"]?.array ?? []).flatMap { $0.object?["skills"]?.array ?? [] }
            + (catalog["global"]?.array ?? []) + (catalog["builtin"]?.array ?? [])
        let editable = Set(skills.compactMap { $0.object }.filter { $0["editable"]?.bool == true }.compactMap { $0["id"]?.string })
        let items: [PluginValue] = mentions.map { mention in
            let handle = mention["handle"]?.string ?? ""
            let name = mention["title"]?.string ?? handle
            let skillID = String((mention["id"]?.string ?? "").dropFirst("skill:".count))
            let canEdit = editable.contains(skillID)
            return .object([
                "id": .string("skill-" + handle), "title": .string("@" + handle), "detail": mention["detail"] ?? .null,
                "icon": .string("sparkles"), "help": .string("Mention \(name)"), "keywords": .array([.string(name), .string(handle)]),
                "buttons": .array([.object([
                    "id": .string("gear"), "label": .string("Manage"), "icon": .string("gearshape"),
                    "help": .string(canEdit ? "Open \(name) in the Skills page" : "Built-in skills can't be edited"),
                    "disabled": .bool(!canEdit)
                ])]),
                "data": .object(["skillID": .string(skillID), "handle": .string(handle)])
            ])
        }
        return .object([
            "title": .string("Skills"), "items": .array(items),
            "empty": .string("No skills"), "noMatch": .string("No skill matches")
        ])
    }

    /// Both agents, the task's own first.
    private func loginList(_ calls: Calls) async throws -> PluginValue {
        let own = try await calls.provider().name
        let items: [PluginValue] = ([own] + Self.providers.filter { $0 != own }).map { provider in
            .object([
                "id": .string("login-" + provider.rawValue), "title": .string("Sign in to \(provider.displayName)"),
                "detail": provider == own ? .string("This task's agent") : .null, "icon": .string("person.crop.circle"),
                "help": .string("Sign in to \(provider.displayName)"),
                "data": .object(["provider": .string(provider.rawValue)])
            ])
        }
        return .object(["title": .string("Sign in"), "items": .array(items), "noMatch": .string("No agent matches")])
    }

    /// Create Plugin, then the user's own plugins (not the built-in ones).
    private func pluginList(_ calls: Calls) async throws -> PluginValue {
        let plugins = try await calls.bridge("plugin.list", [:]).object?["plugins"]?.array ?? []
        let create: PluginValue = .object([
            "id": .string("create-plugin"), "title": .string("Create Plugin"),
            "detail": .string("Turn on Add Plugin mode to choose where it goes"), "icon": .string("plus"),
            "help": .string("Turn on Add Plugin mode to choose where it goes")
        ])
        let installed: [PluginValue] = plugins.compactMap(\.object).filter { $0["builtIn"]?.bool != true }.map { plugin in
            let id = plugin["id"]?.string ?? ""
            let name = plugin["name"]?.string ?? id
            let placement = plugin["placement"]?.string ?? ""
            let where_ = plugin["presentation"]?.string == PluginPresentation.headless.rawValue
                ? PluginPresentation.headless.title : PluginPlacement(rawValue: placement)?.title ?? placement
            return .object([
                "id": .string("plugin-" + id), "title": .string(name),
                "detail": .string(where_ + (plugin["enabled"]?.bool == false ? " (Disabled)" : "")),
                "icon": .string("puzzlepiece.extension"), "help": .string("Open this plugin's editor"),
                "buttons": .array([
                    .object(["id": .string("edit"), "label": .string("Edit"), "help": .string("Open this plugin's editor"), "icon": .string("pencil")]),
                    .object([
                        "id": .string("delete"), "label": .string("Delete"), "help": .string("Delete this plugin's folder"),
                        "icon": .string("trash"), "destructive": .bool(true)
                    ]),
                    // Plugin settings don't exist yet; the gear stays where they will open.
                    .object([
                        "id": .string("gear"), "label": .string("Settings"), "help": .string("Plugin settings are not available yet"),
                        "icon": .string("gearshape"), "disabled": .bool(true)
                    ])
                ]),
                "data": .object(["pluginID": .string(id)])
            ])
        }
        return .object(["title": .string("Plugins"), "items": .array([create] + installed), "noMatch": .string("No plugin matches")])
    }

    // MARK: Host calls

    /// The plugin's host calls, failing as a script's awaited call would.
    private struct Calls {
        let host: PluginCommandHost
        let taskID: String

        func bridge(_ command: String, _ arguments: [String: PluginValue]) async throws -> PluginValue {
            try await host("bridge", command, .object(arguments)).value()
        }

        func ui(_ name: String, _ arguments: [String: PluginValue]) async throws -> PluginValue {
            try await host("ui", name, .object(arguments)).value()
        }

        func provider() async throws -> (name: ConversationProvider, supportsGoals: Bool) {
            let value = try await bridge("conversation.provider.get", ["taskID": .string(taskID)]).object ?? [:]
            return (ConversationProvider(rawValue: value["provider"]?.string ?? "") ?? .claude, value["supportsGoals"]?.bool == true)
        }

        /// The composer's mentionable items of `kind`, "mcp" or "skill".
        func mentions(kind: String) async throws -> [[String: PluginValue]] {
            let items = try await bridge("mentions.list", ["taskID": .string(taskID)]).object?["items"]?.array ?? []
            return items.compactMap(\.object).filter { $0["kind"]?.string == kind }
        }
    }
}
