import Foundation

/// The bridge commands of plugins' background work: running a script
/// plugin's service handlers (`plugin.service`, `plugin.services`), calling
/// an MCP tool directly (`mcp.call`) and running an agent (`agent.run`,
/// `agent.cancel`, `agent.runs`). The window, the CLI and a plugin's
/// `Playhouse.bridge` all reach these same handlers.
extension PlayhouseBridgeRuntime {
    func pluginBackgroundOperation(
        _ request: BridgeRequest,
        settings: WorkspaceSettingsManager,
        library: () throws -> PluginLibrary,
        storeDirectory: String?,
        conversationClients: () -> ConversationClients,
        mcpWorkspace: () -> ConversationWorkspaceContext?
    ) async throws -> BridgeValue {
        switch request.command {
        // A script plugin's background half run for app events: headlessly for
        // `plugin service` (provider calls need a mock), or live, for one event the
        // daemon delivers to an installed plugin's service (`deliver`).
        case "plugin.service":
            do {
                return BridgeValue(plugin: try await runPluginService(request, settings: settings, library: library))
            } catch let error as PluginTreeError {
                throw BridgeCommandError(code: "invalid_argument", message: error.message)
            }
        // The enabled, valid script plugins with a background half, which the
        // daemon's service host wakes for the events they list. Runs a daemon that
        // was cut off left unfinished are reported as interrupted first.
        case "plugin.services":
            if let store = agentRunStore(storeDirectory) { PluginAgentRuns.recoverInterrupted(store: store, origin: request, codex: conversationClients().codex) }
            let disabled = settings.disabledPluginIDs
            let installed = try library()
            let plugins = await Task.detached { installed.list(validate: false, disabled: disabled) }.value
            return .object(["services": .array(plugins.filter { $0.isActive && $0.hasService }.map { plugin in
                .object(["pluginID": .string(plugin.id), "events": .array(plugin.events.map(BridgeValue.string))])
            })])
        case "mcp.call":
            return try await callMcpTool(request, library: library, conversationClients: conversationClients, mcpWorkspace: mcpWorkspace)
        case "agent.run":
            let plugin = try scriptPlugin(request, settings: settings, library: library)
            guard plugin.events.contains(PluginEvent.agentFinished) else {
                throw BridgeCommandError(code: "invalid_argument", message: "The plugin \(plugin.id) must list \"\(PluginEvent.agentFinished)\" in its manifest's \"events\" to hear how its agent run ends.")
            }
            let provider = try pluginProvider(request)
            let prompt = try request.requiredString("prompt").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prompt.isEmpty else { throw BridgeCommandError(code: "invalid_argument", message: "agent.run needs a prompt.") }
            let model = request.arguments["model"]?.string
            if let model, !ConversationManager.isValidModelID(model) {
                throw BridgeCommandError(code: "invalid_argument", message: ConversationManager.invalidModelIDMessage)
            }
            var allowedTools: [String] = []
            if let tools = request.arguments["allowedTools"], tools != .null {
                let names = PluginValue(bridge: tools).array?.compactMap(\.string)
                guard let names, names.count == PluginValue(bridge: tools).array?.count else {
                    throw BridgeCommandError(code: "invalid_argument", message: "allowedTools must be a list of tool names.")
                }
                allowedTools = names
            }
            var schema: PluginValue?
            if let value = request.arguments["jsonSchema"], value != .null {
                guard value.object != nil else { throw BridgeCommandError(code: "invalid_argument", message: "jsonSchema must be a JSON Schema object.") }
                schema = PluginValue(bridge: value)
            }
            let context = request.arguments["context"].map(PluginValue.init(bridge:)) ?? .null
            guard context.jsonText.utf8.count <= PluginAgentRuns.contextLimit else {
                throw BridgeCommandError(code: "invalid_argument", message: "An agent run's context must be small JSON, at most \(PluginAgentRuns.contextLimit) bytes.")
            }
            let cwd: URL
            if let path = request.arguments["cwd"]?.string, !path.isEmpty {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    throw BridgeCommandError(code: "invalid_argument", message: "The agent's cwd \(path) is not a folder.")
                }
                cwd = URL(fileURLWithPath: path, isDirectory: true)
            } else {
                // A folder of its own, so the agent starts with nothing to read or change.
                guard let storeDirectory else { throw BridgeCommandError(code: "operation_failed", message: "Playhouse could not resolve its data directory.") }
                cwd = URL(fileURLWithPath: storeDirectory, isDirectory: true).appendingPathComponent("plugin-agents", isDirectory: true)
                try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
            }
            let run = PluginAgentRuns.Request(pluginID: plugin.id, prompt: prompt, model: model, allowedTools: allowedTools, jsonSchema: schema, context: context, cwd: cwd)
            let store = try requiredAgentRunStore(storeDirectory)
            let runID = switch provider {
            case .codex: try await PluginAgentRuns.startCodex(run, codex: conversationClients().codex, store: store, origin: request)
            case .opencode: try await PluginAgentRuns.startOpenCode(run, opencode: conversationClients().opencode, store: store, origin: request)
            case .claude: try PluginAgentRuns.start(run, claude: conversationClients().claude, store: store, origin: request)
            }
            return .object(["runID": .string(runID)])
        case "agent.cancel":
            let pluginID = try request.requiredString("pluginID")
            let runID = try request.requiredString("runID")
            try PluginAgentRuns.cancel(pluginID: pluginID, runID: runID, store: try requiredAgentRunStore(storeDirectory), origin: request, codex: conversationClients().codex)
            return .object(["runID": .string(runID), "cancelled": .boolean(true)])
        case "agent.runs":
            let store = try requiredAgentRunStore(storeDirectory)
            PluginAgentRuns.recoverInterrupted(store: store, origin: request, codex: conversationClients().codex)
            let pluginID = request.arguments["pluginID"]?.string.flatMap { $0.isEmpty ? nil : $0 }
            return .object(["runs": BridgeValue(plugin: .array(PluginAgentRuns.list(store: store, pluginID: pluginID)))])
        default:
            throw BridgeCommandError(code: "unknown_command", message: "Unknown command '\(request.command)'.")
        }
    }

    func agentRunStore(_ storeDirectory: String?) -> PluginAgentRunStore? {
        storeDirectory.map(PluginAgentRunStore.init(storeDirectory:))
    }

    private func requiredAgentRunStore(_ storeDirectory: String?) throws -> PluginAgentRunStore {
        guard let store = agentRunStore(storeDirectory) else {
            throw BridgeCommandError(code: "operation_failed", message: "Playhouse could not resolve its data directory.")
        }
        return store
    }

    /// An installed, enabled script plugin named by the request's `pluginID`.
    private func scriptPlugin(_ request: BridgeRequest, settings: WorkspaceSettingsManager, library: () throws -> PluginLibrary) throws -> PluginRecord {
        let pluginID = try request.requiredString("pluginID")
        if BuiltInPlugins.isBuiltIn(pluginID) {
            throw BridgeCommandError(code: "invalid_argument", message: "\"\(pluginID)\" is a built-in plugin; its background half is compiled into Playhouse.")
        }
        let plugin: PluginRecord
        do {
            plugin = try library().plugin(id: pluginID, validate: false)
        } catch let error as PluginLibraryError {
            throw BridgeCommandError(code: "not_found", message: error.localizedDescription)
        } catch let error as PluginTreeError {
            throw BridgeCommandError(code: "invalid_argument", message: error.message)
        }
        if let problem = plugin.errors.first { throw BridgeCommandError(code: "invalid_argument", message: problem) }
        if settings.disabledPluginIDs.contains(plugin.id) {
            throw BridgeCommandError(code: "unavailable", message: "The plugin \"\(plugin.id)\" is disabled; enable it to run it.")
        }
        return plugin
    }

    private func runPluginService(_ request: BridgeRequest, settings: WorkspaceSettingsManager, library: () throws -> PluginLibrary) async throws -> PluginValue {
        var command: PluginServiceCommand
        var target: String?
        if request.arguments["pluginID"]?.string != nil {
            // An installed plugin runs with its placement's props: the plugin and its state.
            var plugin = try scriptPlugin(request, settings: settings, library: library)
            plugin.state = settings.pluginState(plugin.id)
            command = PluginServiceCommand(
                source: try String(contentsOfFile: plugin.entryPath, encoding: .utf8),
                sourceName: URL(fileURLWithPath: plugin.entryPath).lastPathComponent,
                props: PluginContext.props(plugin: plugin, appearance: settings.appearance, task: nil, composer: nil)
            )
            target = plugin.id
        } else if let file = request.arguments["file"]?.string {
            guard let source = try? String(contentsOfFile: file, encoding: .utf8) else {
                throw BridgeCommandError(code: "invalid_argument", message: "Couldn't read the plugin file \(file).")
            }
            command = PluginServiceCommand(source: source, sourceName: URL(fileURLWithPath: file).lastPathComponent, props: [
                "plugin": .object(["id": .string("plugin-file"), "name": .string(URL(fileURLWithPath: file).lastPathComponent), "version": .number(0),
                                   "placement": .string(PluginPlacement.composerActions.rawValue), "presentation": .string(PluginPresentation.headless.rawValue)]),
                "app": .object(["appearance": .string(settings.appearance)]),
                "state": .object([:])
            ])
            command.localState = true
        } else {
            throw BridgeCommandError(code: "invalid_argument", message: "Pass a plugin file or an installed plugin.")
        }
        if let json = request.arguments["props"]?.string {
            guard let object = try? JSONDecoder().decode(PluginValue.self, from: Data(json.utf8)).object else {
                throw BridgeCommandError(code: "invalid_argument", message: "--props must be a JSON object.")
            }
            command.props.merge(object) { _, new in new }
        }
        if let delivery = request.arguments["deliver"].map(PluginValue.init(bridge:))?.object {
            // One event of the daemon's, with the provider calls it makes for real.
            command.events = [PluginEvent(name: delivery["name"]?.string ?? "", payload: delivery["payload"]?.object ?? [:], pluginID: target)]
            command.live = true
        } else {
            guard case .array(let events)? = request.arguments["events"], !events.isEmpty else {
                throw BridgeCommandError(code: "invalid_argument", message: "Pass at least one --event <name>[:<json payload>].")
            }
            command.events = try events.map { try PluginEvent(parsing: $0.string ?? "") }
            if let unknown = command.events.first(where: { !PluginEvent.names.contains($0.name) }) {
                throw BridgeCommandError(code: "invalid_argument", message: "Unknown plugin event \"\(unknown.name)\". Events: \(PluginEvent.names.joined(separator: ", ")).")
            }
            if case .object(let mocks)? = request.arguments["mocks"] {
                command.mocks = mocks.mapValues(PluginValue.init(bridge:))
            }
        }
        if let seconds = PlayhouseProcessEnvironment.current["PLAYHOUSE_E2E_PLUGIN_SERVICE_TIMEOUT_SECONDS"].flatMap(TimeInterval.init) {
            command.timeout = seconds
        }
        // The handlers' Playhouse.bridge calls run as requests of this caller.
        let caller = request
        let writer = target ?? command.props["plugin"]?.object?["id"]?.string ?? "plugin-file"
        command.bridge = { name, arguments in
            var nested = caller
            nested.id = UUID().uuidString
            nested.command = name
            nested.arguments = caller.arguments.filter { $0.key.hasPrefix("__") }.merging(BridgeValue(plugin: arguments).object ?? [:]) { _, new in new }
            // Marks the requests the handlers make, and those they cause, as this plugin's.
            nested.arguments["__pluginService"] = .string(writer)
            let response = await PlayhouseBridgeRuntime().perform(nested) { _ in }
            guard response.ok else {
                throw PluginHostError(code: response.error?.code ?? "operation_failed", message: response.error?.message ?? "The bridge command failed.")
            }
            return PluginValue(bridge: response.result ?? .null)
        }
        let run = command
        let report = try await Task.detached { try await run.run() }.value
        if command.live, let errors = report.object?["errors"]?.array, !errors.isEmpty {
            PlayhouseDiagnostics.record("plugin.service.errors", fields: [
                "pluginID": target ?? "", "name": command.events.first?.name ?? "",
                "errors": errors.compactMap(\.string).joined(separator: " | ")
            ])
        }
        return report
    }

    private func callMcpTool(
        _ request: BridgeRequest,
        library: () throws -> PluginLibrary,
        conversationClients: () -> ConversationClients,
        mcpWorkspace: () -> ConversationWorkspaceContext?
    ) async throws -> BridgeValue {
        let tool = try request.requiredString("tool")
        guard PluginMcpTool.isQualified(tool) else {
            throw BridgeCommandError(code: "invalid_argument", message: "\"\(tool)\" is not a fully qualified MCP tool name such as mcp__<server>__<tool>.")
        }
        let provider = try pluginProvider(request)
        // A plugin's manifest may name the only tools it calls, which catches a mistyped tool early.
        if let pluginID = request.arguments["pluginID"]?.string, !pluginID.isEmpty, !BuiltInPlugins.isBuiltIn(pluginID),
           let allowed = (try? library().plugin(id: pluginID, validate: false))?.mcpTools, !allowed.contains(tool) {
            throw BridgeCommandError(code: "permission_denied", message: "The plugin \(pluginID) lists the MCP tools it calls in \"mcpTools\", and \(tool) isn't one of them.")
        }
        var arguments: [String: Any] = [:]
        if let given = request.arguments["arguments"], given != .null {
            guard given.object != nil,
                  let object = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(given))) as? [String: Any] else {
                throw BridgeCommandError(code: "invalid_argument", message: "An MCP tool's arguments must be a JSON object.")
            }
            arguments = object
        }
        let seconds: Double
        switch request.arguments["timeout"] {
        case .integer(let value)?: seconds = Double(value)
        case .decimal(let value)?: seconds = value
        default: seconds = 60
        }
        guard seconds > 0, seconds <= 600 else { throw BridgeCommandError(code: "invalid_argument", message: "timeout is between 1 and 600 seconds.") }
        guard let workspace = mcpWorkspace() else { throw BridgeCommandError(code: "operation_failed", message: "Playhouse couldn't prepare a folder for the agent.") }
        let reply: [String: Any]
        do {
            switch provider {
            case .claude: reply = try await conversationClients().claude.callMcpTool(tool, arguments: arguments, workspace: workspace, timeout: .seconds(seconds))
            case .codex: reply = try await conversationClients().codex.callMcpTool(tool, arguments: arguments, workspace: workspace, timeout: .seconds(seconds))
            case .opencode:
                // OpenCode's server has no API to call an MCP tool outside a model turn.
                throw McpToolCallError.unsupported("OpenCode can't call MCP tools outside a turn; call them through Claude Code or Codex.")
            }
        } catch ClaudeCodeClient.ClientError.cliNotFound {
            throw BridgeCommandError(code: "unavailable", message: "Claude Code isn't installed, so MCP tools can't be called.")
        } catch CodexAppServerClient.ClientError.cliNotFound {
            throw BridgeCommandError(code: "unavailable", message: "Codex isn't installed, so MCP tools can't be called through it.")
        } catch let error as McpToolCallError {
            switch error {
            case .unsupported: throw BridgeCommandError(code: "unavailable", message: error.localizedDescription)
            case .timedOut: throw BridgeCommandError(code: "timeout", message: error.localizedDescription)
            case .toolFailed(let message): throw BridgeCommandError(code: "tool_failed", message: message)
            }
        } catch {
            throw BridgeCommandError(code: "operation_failed", message: error.localizedDescription)
        }
        PlayhouseDiagnostics.record("mcp.call.finished", fields: ["provider": provider.rawValue, "isError": String(reply["isError"] as? Bool ?? false)])
        guard let data = try? JSONSerialization.data(withJSONObject: reply), let value = try? JSONDecoder().decode(BridgeValue.self, from: data) else {
            throw BridgeCommandError(code: "operation_failed", message: "The answer to the MCP call wasn't JSON.")
        }
        return value
    }

    /// The provider an `mcp.call` or `agent.run` asks for: Claude Code unless it
    /// names `codex`, since a plugin's model names and MCP servers belong to one.
    private func pluginProvider(_ request: BridgeRequest) throws -> ConversationProvider {
        guard let value = request.arguments["provider"]?.string, !value.isEmpty else { return .claude }
        guard let provider = ConversationProvider(rawValue: value) else {
            throw BridgeCommandError(code: "invalid_argument", message: "Provider must be one of \(ConversationProvider.allCases.map { "'\($0.rawValue)'" }.joined(separator: ", ")).")
        }
        return provider
    }
}
