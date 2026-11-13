import Foundation
import Observation

/// The window's installed plugins, read from the bridge daemon, which owns
/// the plugins folder. The window reloads it whenever `plugin refresh` or
/// `plugin delete` bumps `WorkspaceSettings.pluginsRevisionKey`.
@MainActor
@Observable
final class PluginRegistry {
    /// Every plugin folder, valid or not, sorted by id.
    private(set) var plugins: [PluginRecord] = []
    private(set) var authoringSessions: [BoardTaskRecord] = []
    @ObservationIgnored private let client: DaemonClient

    init(client: DaemonClient = DaemonClient()) {
        self.client = client
    }

    func reload() async {
        do {
            let result = try await client.call("plugin.list")
            plugins = try result.object?["plugins"]?.decoded([PluginRecord].self) ?? []
            let sessions = try await client.call("plugin.sessions")
            authoringSessions = try sessions.object?["sessions"]?.decoded([BoardTaskRecord].self) ?? []
        } catch {
            PlayhouseDiagnostics.record("plugins.reload.failed", fields: ["error": error.localizedDescription])
        }
    }

    /// The valid plugins whose entry goes in `placement`.
    func plugins(for placement: PluginPlacement) -> [PluginRecord] {
        plugins.filter { $0.valid && $0.placement == placement.rawValue }
    }

    func delete(_ id: String) async throws {
        try await client.call("plugin.delete", ["pluginID": .string(id)])
        await reload()
    }

    /// Creates the task whose agent builds a plugin for `placement`, and
    /// returns it with the prompt its conversation sends.
    func author(_ placement: PluginPlacement, name: String? = nil, presentation: PluginPresentation? = nil) async throws -> (taskID: UUID, prompt: String) {
        var arguments: [String: BridgeValue] = ["placement": .string(placement.rawValue)]
        if let name { arguments["name"] = .string(name) }
        if let presentation { arguments["presentation"] = .string(presentation.rawValue) }
        let result = try await client.call("plugin.author", arguments)
        guard let task = try result.object?["task"]?.decoded(BoardTaskRecord.self),
              let prompt = result.object?["prompt"]?.string else {
            throw BridgeCommandError(code: "invalid_response", message: "The bridge did not return the new plugin task.")
        }
        await reload()
        return (task.id, prompt)
    }

    func edit(_ pluginID: String) async throws -> UUID {
        let result = try await client.call("plugin.edit", ["pluginID": .string(pluginID)])
        guard let task = try result.object?["task"]?.decoded(BoardTaskRecord.self) else {
            throw BridgeCommandError(code: "invalid_response", message: "The bridge did not return the plugin conversation.")
        }
        await reload()
        return task.id
    }

    /// Add Plugin mode, shared with the CLI's `plugin mode`.
    static func setAddMode(_ enabled: Bool) {
        WorkspaceSettingsManager().setPluginAddMode(enabled)
    }
}
