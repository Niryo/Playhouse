import Foundation
import Observation

/// The window's installed plugins, read from the bridge daemon, which owns
/// the plugins folder, with the built-in plugins first. The window reloads it
/// whenever `plugin refresh`, `plugin delete`, `plugin enable` or
/// `plugin disable` bumps `WorkspaceSettings.pluginsRevisionKey`.
@MainActor
@Observable
final class PluginRegistry {
    /// The built-in plugins, then every plugin folder, valid or not, sorted by id.
    private(set) var plugins: [PluginRecord] = []
    private(set) var authoringSessions: [BoardTaskRecord] = []
    @ObservationIgnored private let client: DaemonClient

    init(client: DaemonClient = DaemonClient()) {
        self.client = client
    }

    func reload() async {
        do {
            // Every assignment rebuilds the Plugins menu, closing a submenu the user has
            // open, so an unchanged reload (the revision bump that follows an enable or
            // disable this window already reloaded for) assigns nothing.
            let result = try await client.call("plugin.list")
            let listed = try result.object?["plugins"]?.decoded([PluginRecord].self) ?? []
            if listed != plugins { plugins = listed }
            let sessions = try await client.call("plugin.sessions")
            let listedSessions = try sessions.object?["sessions"]?.decoded([BoardTaskRecord].self) ?? []
            if listedSessions != authoringSessions { authoringSessions = listedSessions }
        } catch {
            PlayhouseDiagnostics.record("plugins.reload.failed", fields: ["error": error.localizedDescription])
        }
    }

    /// The active plugins whose entry button goes in `placement`.
    func plugins(for placement: PluginPlacement) -> [PluginRecord] {
        plugins.filter { $0.isActive && $0.hasSurface && $0.placement == placement.rawValue && !$0.presentationKind.isInPlace }
    }

    /// The active plugins rendered in place as sections of `placement`.
    func inlinePlugins(for placement: PluginPlacement) -> [PluginRecord] {
        plugins.filter { $0.isActive && $0.placement == placement.rawValue && $0.presentationKind == .inline }
    }

    /// The active plugins rendered as collapsible sections of `placement`, top to bottom.
    func sectionPlugins(for placement: PluginPlacement) -> [PluginRecord] {
        plugins.filter { $0.isActive && $0.placement == placement.rawValue && $0.presentationKind == .section }
    }

    /// The compiled-in plugins, and the installed ones, as the Plugins menu lists them.
    var builtInPlugins: [PluginRecord] { plugins.filter(\.builtIn) }
    var installedPlugins: [PluginRecord] { plugins.filter { !$0.builtIn } }

    /// Enables or disables a plugin, shared with the CLI's `plugin enable` and `plugin disable`.
    func setEnabled(_ id: String, _ enabled: Bool) async throws {
        try await client.call(enabled ? "plugin.enable" : "plugin.disable", ["pluginID": .string(id)])
        await reload()
    }

    func delete(_ id: String) async throws {
        try await client.call("plugin.delete", ["pluginID": .string(id)])
        await reload()
    }

    /// Creates the task whose agent builds a plugin for `placement`, and
    /// returns it with its initial conversation draft.
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
