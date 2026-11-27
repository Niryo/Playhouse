import Foundation

package enum WorkspaceSettings {
    package static let defaultParentFolderKey = "defaultWorkspaceParentFolderPath"
    package static let lastSelectedRepositoriesKey = "lastSelectedRepositories"
    package static let recentRepositoriesKey = "recentRepositories"
    /// How many recently selected repositories are remembered and offered by the repository picker.
    package static let recentRepositoryHistoryLimit = 20
    package static let appearanceKey = "appearance"
    /// Whether the task view's sidebar is hidden to a narrow rail; one value shared by every task.
    package static let taskSidebarCollapsedKey = "taskSidebarCollapsed"
    /// Whether the standalone chat's page labels are locked open beside its transcript by a click
    /// on their handle, rather than sliding out from it only while hovered.
    package static let chatPageAnchorsPinnedKey = "chatPageAnchorsPinned"
    /// Whether the Changes section inside the task sidebar was collapsed, before the
    /// built-in Changes plugin kept it in its plugin state; read once to carry it over.
    package static let workspaceChangesSectionCollapsedKey = "workspaceChangesSectionCollapsed"
    /// Whether the Agents info section at the bottom of the board sidebar was minimized; the
    /// built-in Agents info plugin keeps it in its plugin state; read once to carry it over.
    package static let agentsInfoSectionCollapsedKey = "agentsInfoSectionCollapsed"
    package static let defaultConversationProviderKey = "defaultConversationProvider"
    package static let tokenUsageColorMaxKey = "tokenUsageColorMax"
    package static let defaultTokenUsageColorMax = TokenUsageHeatmap.defaultColorMax
    package static let cpuUsageColorMaxKey = "cpuUsageColorMax"
    package static let defaultCPUUsageColorMax = CPUUsageHeatmap.defaultColorMax
    /// Whether a task moving to Review or Waiting Response plays its sound; on unless turned off.
    package static let statusSoundsEnabledKey = "statusSoundsEnabled"

    package static func statusSoundsEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: statusSoundsEnabledKey) as? Bool ?? true
    }
    /// The Optimized context choice last made in any board task's composer (full or
    /// optimized), which every new board task starts with. Unset until first chosen.
    package static let conversationContextModeKey = "conversationContextMode"
    /// Playhouse's own context compaction triggers, shared by Claude and Codex task
    /// sessions. A threshold saved by earlier builds under "autoCompactionThresholdTokens"
    /// is no longer read: each provider's native auto-compaction owns that decision.
    package static let autoCompactionEnabledKey = "autoCompactionEnabled"
    package static let autoCompactionIdleMinutesKey = "autoCompactionIdleMinutes"
    package static let autoCompactionMinimumKey = "autoCompactionMinimumTokens"
    /// Add Plugin mode: the window shows "Add here" placeholders at every plugin placement.
    package static let pluginAddModeKey = "pluginAddMode"
    /// Bumped whenever the plugins folder changes (`plugin refresh`, `plugin delete`), so
    /// the window reloads its installed plugins.
    package static let pluginsRevisionKey = "pluginsRevision"
    /// The ids of the plugins, built-in or installed, the user disabled.
    package static let disabledPluginIDsKey = "disabledPluginIDs"
    /// Each plugin's own saved values (`plugin state`), as JSON keyed by plugin id.
    package static let pluginStatesKey = "pluginStates"
    /// Set once the tasks' pull request modes, from before the `pull-request-mode`
    /// plugin kept them in its state, were carried into that state.
    package static let legacyPullRequestModesImportedKey = "legacyPullRequestModesImported"
    /// Set once the tasks saved while PR was the default pull request mode got
    /// PR saved as their own, before Manual became the default.
    package static let existingTaskPullRequestModesPinnedKey = "existingTaskPullRequestModesPinned"

    package static var preferencesStore: UserDefaults {
        #if DEBUG
        if let suiteName = PlayhouseProcessEnvironment.current["PLAYHOUSE_E2E_DEFAULTS_SUITE"],
           let suite = UserDefaults(suiteName: suiteName) {
            return suite
        }
        #endif
        return .standard
    }

    /// Where a provider runs for a task with no repository or folder: the repository root
    /// that repository suggestions come from, so an agent's searches stay among the user's
    /// repositories instead of walking the home folder into other apps' data (which macOS
    /// guards with an "access data from other apps" prompt). Home only while no root is set.
    package static var rootlessWorkingDirectoryURL: URL {
        validDirectoryURL(for: preferencesStore.string(forKey: defaultParentFolderKey) ?? "")
            ?? FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
    }

    package static func validDirectoryURL(for path: String) -> URL? {
        guard !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return url
    }
}

package struct ConversationWorkspaceContext {
    package let roots: [URL]
    package let cwd: URL
    /// The skill folders each provider needs passed so it sees the whole
    /// gallery. Only a turn's own launch sets it.
    package var skillBridge: SkillBridgeLaunch?
    /// The rule files each provider is handed or told to skip. Only a turn's own launch sets it.
    package var ruleBridge: RuleBridgeLaunch?
    /// The MCP servers each provider is passed or told to skip. Only a turn's own launch sets it.
    package var mcpBridge: McpBridgeLaunch?
    /// A side chat's turns may read the workspace and run the Playhouse CLI but never
    /// change files (see `SideChatReadOnlyPolicy`): Codex runs them in its read-only sandbox,
    /// whose CLI calls the daemon limits to board requests, and Claude Code, which has no
    /// sandbox, checks every tool call in a hook that runs before the user's own allow rules.
    /// MCP tools stay available on both providers, as Codex's sandbox does not cover them.
    package var isReadOnly = false

    /// One Codex thread config joining what skills and MCP servers each need.
    package var codexThreadConfig: [String: Any]? {
        var config = skillBridge?.codexThreadConfig ?? [:]
        if let servers = mcpBridge?.codexServers { config["mcp_servers"] = servers }
        return config.isEmpty ? nil : config
    }

    /// With no roots the provider runs in `rootlessDirectory`, else in the configured
    /// repository root (`WorkspaceSettings.rootlessWorkingDirectoryURL`).
    package init(roots: [URL], rootlessDirectory: URL? = nil) throws {
        let normalized = roots.map(\.standardizedFileURL)
        guard normalized.allSatisfy({ WorkspaceSettings.validDirectoryURL(for: $0.path) != nil }) else {
            throw WorkspaceError.unavailableRoot
        }
        let uniqueRoots = Array(NSOrderedSet(array: normalized.map(\.path))).compactMap {
            ($0 as? String).map { URL(fileURLWithPath: $0, isDirectory: true) }
        }
        self.roots = uniqueRoots
        cwd = uniqueRoots.first ?? rootlessDirectory?.standardizedFileURL ?? WorkspaceSettings.rootlessWorkingDirectoryURL
    }
}

package enum WorkspaceError: LocalizedError {
    case unavailableRoot

    package var errorDescription: String? {
        switch self {
        case .unavailableRoot:
            "One or more working folders are unavailable. Edit the task folders and try again."
        }
    }
}


package enum RepositoryScanner {
    package static func scan(parent: URL) async -> [URL] {
        await Task.detached(priority: .utility) {
            scanSynchronously(parent: parent)
        }.value
    }

    package static func scanSynchronously(parent: URL) -> [URL] {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let enumerator = manager.enumerator(
                at: parent,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [],
                errorHandler: { _, _ in true }
              ) else { return [] }

        let markerAtParent = parent.appendingPathComponent(".git", isDirectory: false)
        if manager.fileExists(atPath: markerAtParent.path) {
            return [parent.standardizedFileURL]
        }

        var repositories: [URL] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            guard values?.isDirectory == true else { continue }

            let marker = url.appendingPathComponent(".git", isDirectory: false)
            if manager.fileExists(atPath: marker.path) {
                repositories.append(url.standardizedFileURL)
                enumerator.skipDescendants()
            }
        }
        return repositories.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }
}

/// The environment work should run with. The bridge daemon scopes each request
/// to its caller's environment (`BridgeRequest.environment`) for the life of
/// that request's task, including across suspension points while other requests
/// interleave on the main actor. Outside a request, such as in the GUI app, this
/// is simply this process's own environment.
package enum PlayhouseProcessEnvironment {
    @TaskLocal package static var requestEnvironment: [String: String]?

    package static var current: [String: String] {
        requestEnvironment ?? ProcessInfo.processInfo.environment
    }
}

/// One bridge request's diagnostics routing. A single daemon process serves
/// requests for different stores, so each request keeps its own store-directory
/// selection (as each XPC service process once had), and records it makes
/// before choosing that directory wait for it instead of landing elsewhere.
/// Only touched on the main actor.
package final class PlayhouseDiagnosticsScope: @unchecked Sendable {
    package let id = UUID()
    package var directoryOverride: URL?
    package var awaitingDirectory = true

    package init() {}
}

/// What a request's background work needs to keep behaving as part of that
/// request after the request has returned: its environment, its diagnostics
/// scope, and the request itself, whose isolation the plugin services' commands
/// reuse when a change it made raises an event (`PluginServiceHost.origin`).
/// `Task.detached` doesn't inherit task-local values.
package struct PlayhouseRequestContext: Sendable {
    @TaskLocal package static var diagnosticsScope: PlayhouseDiagnosticsScope?

    package let environment: [String: String]?
    package let scope: PlayhouseDiagnosticsScope?
    package var origin: BridgeRequest? = nil

    @MainActor package static func capture() -> PlayhouseRequestContext {
        PlayhouseRequestContext(environment: PlayhouseProcessEnvironment.requestEnvironment, scope: diagnosticsScope, origin: PluginServiceHost.origin)
    }

    package func run<T>(_ operation: () async throws -> T) async rethrows -> T {
        try await PlayhouseProcessEnvironment.$requestEnvironment.withValue(environment) {
            try await Self.$diagnosticsScope.withValue(scope) {
                try await PluginServiceHost.$origin.withValue(origin) {
                    try await operation()
                }
            }
        }
    }

    package init(environment: [String: String]?, scope: PlayhouseDiagnosticsScope?, origin: BridgeRequest? = nil) {
        self.environment = environment
        self.scope = scope
        self.origin = origin
    }
}

package enum PlayhouseAppIdentity {
    package static var applicationIdentifier: String {
        Bundle.main.infoDictionary?["PlayhouseApplicationBundleIdentifier"] as? String
            ?? Bundle.main.bundleIdentifier ?? ""
    }

    package static var isTestBundle: Bool {
        BridgeContract.isTestBundle(applicationIdentifier)
    }

    package static var worktreeKey: String? {
        let prefix = "com.playhouse.app.worktree."
        guard applicationIdentifier.hasPrefix(prefix) else { return nil }
        let remainder = String(applicationIdentifier.dropFirst(prefix.count))
        let key = String(remainder.prefix(17))
        guard key.count == 17, key.first == "w",
              key.dropFirst().allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
        let suffix = remainder.dropFirst(key.count)
        guard suffix.isEmpty || (isTestBundle && suffix.hasPrefix(".e2e.")) else { return nil }
        return key
    }

    package static func defaultDataDirectory() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Playhouse", isDirectory: true)
        guard let worktreeKey else { return support }
        return support.appendingPathComponent("Worktrees", isDirectory: true)
            .appendingPathComponent(worktreeKey, isDirectory: true)
    }
}
