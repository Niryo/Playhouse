import Foundation
import AppKit
import SwiftData
import Darwin
import SQLite3

@MainActor
final class WorkspaceSettingsManager {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = WorkspaceSettings.preferencesStore) {
        self.defaults = defaults
    }

    var defaultParentFolderPath: String {
        let value = defaults.string(forKey: WorkspaceSettings.defaultParentFolderKey) ?? ""
        PlayhouseDiagnostics.record("settings.read", fields: [
            "setting": "defaultParentFolder",
            "isSet": String(!value.isEmpty),
            "path": value
        ])
        return value
    }

    var lastSelectedRepositories: [String] {
        let value = defaults.stringArray(forKey: WorkspaceSettings.lastSelectedRepositoriesKey) ?? []
        PlayhouseDiagnostics.record("settings.read", fields: [
            "setting": "lastSelectedRepositories",
            "repositoryCount": String(value.count),
            "repositoryPaths": value.joined(separator: "\n")
        ])
        return value
    }

    /// Repositories most recently selected for any task, newest first.
    var recentRepositories: [String] {
        defaults.stringArray(forKey: WorkspaceSettings.recentRepositoriesKey) ?? []
    }

    /// Recent repositories still on disk that are not already attached, for quick re-adding.
    func recentRepositorySuggestions(excluding attachedPaths: [String]) -> [String] {
        let attached = Set(attachedPaths.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path })
        return recentRepositories.filter { path in
            !attached.contains(path)
                && FileManager.default.fileExists(atPath: URL(fileURLWithPath: path).appendingPathComponent(".git").path)
        }
    }

    var appearance: String {
        let value = defaults.string(forKey: WorkspaceSettings.appearanceKey) ?? "dark"
        let appearance = value == "light" ? "light" : "dark"
        PlayhouseDiagnostics.record("settings.read", fields: ["setting": "appearance", "value": appearance])
        return appearance
    }

    var pluginAddMode: Bool { defaults.bool(forKey: WorkspaceSettings.pluginAddModeKey) }

    func setPluginAddMode(_ enabled: Bool) {
        defaults.set(enabled, forKey: WorkspaceSettings.pluginAddModeKey)
        PlayhouseDiagnostics.record("settings.write.succeeded", fields: ["setting": "pluginAddMode", "value": String(enabled)])
    }

    var pluginsRevision: Int { defaults.integer(forKey: WorkspaceSettings.pluginsRevisionKey) }

    /// The plugins the user disabled: listed, but neither shown nor run.
    var disabledPluginIDs: Set<String> { Set(defaults.stringArray(forKey: WorkspaceSettings.disabledPluginIDsKey) ?? []) }

    func setPluginEnabled(_ id: String, _ enabled: Bool) {
        var disabled = disabledPluginIDs
        if enabled { disabled.remove(id) } else { disabled.insert(id) }
        defaults.set(disabled.sorted(), forKey: WorkspaceSettings.disabledPluginIDsKey)
        PlayhouseDiagnostics.record("settings.write.succeeded", fields: ["setting": "pluginEnabled", "plugin": id, "value": String(enabled)])
    }

    /// Each plugin's own saved values, by plugin id: what `plugin.state.set` stored,
    /// reported as `Playhouse.props.state`.
    var pluginStates: [String: [String: PluginValue]] {
        var states = defaults.data(forKey: WorkspaceSettings.pluginStatesKey)
            .flatMap { try? JSONDecoder().decode([String: [String: PluginValue]].self, from: $0) } ?? [:]
        // The Changes section's collapsed state, from before Changes was a built-in plugin.
        if states[BuiltInPlugins.changesID]?["collapsed"] == nil,
           defaults.object(forKey: WorkspaceSettings.workspaceChangesSectionCollapsedKey) != nil {
            states[BuiltInPlugins.changesID, default: [:]]["collapsed"] = .bool(defaults.bool(forKey: WorkspaceSettings.workspaceChangesSectionCollapsedKey))
        }
        return states
    }

    func pluginState(_ id: String) -> [String: PluginValue] { pluginStates[id] ?? [:] }

    /// Stores one of a plugin's values; null removes it. Returns the plugin's whole state.
    @discardableResult
    func setPluginState(_ id: String, key: String, value: PluginValue) -> [String: PluginValue] {
        var states = pluginStates
        var state = states[id] ?? [:]
        state[key] = value == .null ? nil : value
        states[id] = state.isEmpty ? nil : state
        writePluginStates(states)
        PlayhouseDiagnostics.record("settings.write.succeeded", fields: ["setting": "pluginState", "plugin": id, "key": key])
        return state
    }

    var legacyPullRequestModesImported: Bool {
        get { defaults.bool(forKey: WorkspaceSettings.legacyPullRequestModesImportedKey) }
        set { defaults.set(newValue, forKey: WorkspaceSettings.legacyPullRequestModesImportedKey) }
    }

    /// Forgets a deleted plugin's values, so one installed again under its id starts fresh.
    func clearPluginState(_ id: String) {
        var states = pluginStates
        guard states.removeValue(forKey: id) != nil else { return }
        writePluginStates(states)
    }

    private func writePluginStates(_ states: [String: [String: PluginValue]]) {
        defaults.set(try? JSONEncoder().encode(states), forKey: WorkspaceSettings.pluginStatesKey)
        // The legacy key is carried over once it is written.
        defaults.removeObject(forKey: WorkspaceSettings.workspaceChangesSectionCollapsedKey)
    }

    /// Tells every window to reload the installed plugins.
    @discardableResult
    func bumpPluginsRevision() -> Int {
        let revision = pluginsRevision + 1
        defaults.set(revision, forKey: WorkspaceSettings.pluginsRevisionKey)
        return revision
    }

    func setAppearance(_ value: String) throws {
        PlayhouseDiagnostics.record("settings.write.started", fields: ["setting": "appearance", "value": value])
        guard value == "dark" || value == "light" else {
            PlayhouseDiagnostics.record("settings.write.failed", fields: [
                "setting": "appearance",
                "value": value,
                "errorCode": "invalid_argument"
            ])
            throw BridgeCommandError(code: "invalid_argument", message: "Appearance must be 'dark' or 'light'.")
        }
        defaults.set(value, forKey: WorkspaceSettings.appearanceKey)
        PlayhouseDiagnostics.record("settings.write.succeeded", fields: ["setting": "appearance", "value": value])
    }

    var statusSoundsEnabled: Bool { WorkspaceSettings.statusSoundsEnabled(in: defaults) }

    func setStatusSoundsEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: WorkspaceSettings.statusSoundsEnabledKey)
        PlayhouseDiagnostics.record("settings.write.succeeded", fields: ["setting": "statusSounds", "value": String(enabled)])
    }

    /// The token total a task's usage dot reaches full red at. Everything below
    /// shades from green through orange toward it.
    var tokenUsageColorMax: Int {
        let stored = defaults.integer(forKey: WorkspaceSettings.tokenUsageColorMaxKey)
        return stored > 0 ? stored : WorkspaceSettings.defaultTokenUsageColorMax
    }

    func setTokenUsageColorMax(_ value: Int) throws {
        PlayhouseDiagnostics.record("settings.write.started", fields: ["setting": "tokenUsageColorMax", "value": String(value)])
        guard value > 0 else {
            PlayhouseDiagnostics.record("settings.write.failed", fields: [
                "setting": "tokenUsageColorMax",
                "value": String(value),
                "errorCode": "invalid_argument"
            ])
            throw BridgeCommandError(code: "invalid_argument", message: "The token usage color maximum must be greater than zero.")
        }
        defaults.set(value, forKey: WorkspaceSettings.tokenUsageColorMaxKey)
        PlayhouseDiagnostics.record("settings.write.succeeded", fields: ["setting": "tokenUsageColorMax", "value": String(value)])
    }

    /// The CPU percent a task's usage bar reaches full red at. Defaults to
    /// one fully busy core per logical CPU (the Activity Monitor convention).
    var cpuUsageColorMax: Int {
        let stored = defaults.integer(forKey: WorkspaceSettings.cpuUsageColorMaxKey)
        return stored > 0 ? stored : WorkspaceSettings.defaultCPUUsageColorMax
    }

    func setCPUUsageColorMax(_ value: Int) throws {
        PlayhouseDiagnostics.record("settings.write.started", fields: ["setting": "cpuUsageColorMax", "value": String(value)])
        guard value > 0 else {
            PlayhouseDiagnostics.record("settings.write.failed", fields: [
                "setting": "cpuUsageColorMax",
                "value": String(value),
                "errorCode": "invalid_argument"
            ])
            throw BridgeCommandError(code: "invalid_argument", message: "The CPU usage color maximum must be greater than zero.")
        }
        defaults.set(value, forKey: WorkspaceSettings.cpuUsageColorMaxKey)
        PlayhouseDiagnostics.record("settings.write.succeeded", fields: ["setting": "cpuUsageColorMax", "value": String(value)])
    }

    /// Automatic context compaction defaults: on, at a 200k threshold, compacting
    /// Claude sessions after 50 idle minutes when they hold at least 150k tokens.
    /// Codex uses the threshold and model-switch triggers because its app-server
    /// has no prompt-cache expiry signal.
    var contextCompaction: ContextCompactionSettings {
        let defaults = defaults
        func stored(_ key: String, _ range: ClosedRange<Int>, _ fallback: Int) -> Int {
            let value = defaults.integer(forKey: key)
            return range.contains(value) ? value : fallback
        }
        return ContextCompactionSettings(
            enabled: defaults.object(forKey: WorkspaceSettings.autoCompactionEnabledKey) as? Bool ?? true,
            thresholdTokens: stored(WorkspaceSettings.autoCompactionThresholdKey, ContextCompactionSettings.thresholdRange, ContextCompactionSettings.defaultThresholdTokens),
            idleMinutes: stored(WorkspaceSettings.autoCompactionIdleMinutesKey, ContextCompactionSettings.idleMinutesRange, ContextCompactionSettings.defaultIdleMinutes),
            minimumTokens: stored(WorkspaceSettings.autoCompactionMinimumKey, ContextCompactionSettings.minimumTokensRange, ContextCompactionSettings.defaultMinimumTokens)
        )
    }

    /// Changes any of the compaction settings given; a value out of its range
    /// is rejected before anything is stored.
    func setContextCompaction(enabled: Bool? = nil, thresholdTokens: Int? = nil, idleMinutes: Int? = nil, minimumTokens: Int? = nil) throws {
        var fields = ["setting": "contextCompaction"]
        if let enabled { fields["enabled"] = String(enabled) }
        if let thresholdTokens { fields["thresholdTokens"] = String(thresholdTokens) }
        if let idleMinutes { fields["idleMinutes"] = String(idleMinutes) }
        if let minimumTokens { fields["minimumTokens"] = String(minimumTokens) }
        PlayhouseDiagnostics.record("settings.write.started", fields: fields)
        func reject(_ message: String) -> BridgeCommandError {
            PlayhouseDiagnostics.record("settings.write.failed", fields: fields.merging(["errorCode": "invalid_argument"]) { _, new in new })
            return BridgeCommandError(code: "invalid_argument", message: message)
        }
        let threshold = ContextCompactionSettings.thresholdRange
        let idle = ContextCompactionSettings.idleMinutesRange
        let minimum = ContextCompactionSettings.minimumTokensRange
        if let thresholdTokens, !threshold.contains(thresholdTokens) {
            throw reject("The compaction threshold must be from \(threshold.lowerBound.formatted()) to \(threshold.upperBound.formatted()) tokens, the window Claude Code accepts.")
        }
        if let idleMinutes, !idle.contains(idleMinutes) {
            throw reject("The idle wait must be from \(idle.lowerBound) to \(idle.upperBound) minutes, so it fires before the one-hour prompt cache expires.")
        }
        if let minimumTokens, !minimum.contains(minimumTokens) {
            throw reject("The minimum context must be from \(minimum.lowerBound.formatted()) to \(minimum.upperBound.formatted()) tokens.")
        }
        if let enabled { defaults.set(enabled, forKey: WorkspaceSettings.autoCompactionEnabledKey) }
        if let thresholdTokens { defaults.set(thresholdTokens, forKey: WorkspaceSettings.autoCompactionThresholdKey) }
        if let idleMinutes { defaults.set(idleMinutes, forKey: WorkspaceSettings.autoCompactionIdleMinutesKey) }
        if let minimumTokens { defaults.set(minimumTokens, forKey: WorkspaceSettings.autoCompactionMinimumKey) }
        PlayhouseDiagnostics.record("settings.write.succeeded", fields: fields)
    }

    /// The provider new tasks start with. Codex until the user chooses otherwise.
    var defaultConversationProvider: ConversationProvider {
        let value = defaults.string(forKey: WorkspaceSettings.defaultConversationProviderKey)
        return value.flatMap(ConversationProvider.init(rawValue:)) ?? .codex
    }

    func setDefaultConversationProvider(_ value: String) throws {
        PlayhouseDiagnostics.record("settings.write.started", fields: ["setting": "defaultConversationProvider", "value": value])
        let provider: ConversationProvider
        do {
            provider = try ConversationProvider.parse(value)
        } catch {
            PlayhouseDiagnostics.record("settings.write.failed", fields: [
                "setting": "defaultConversationProvider", "value": value, "errorCode": "invalid_argument"
            ])
            throw error
        }
        defaults.set(provider.rawValue, forKey: WorkspaceSettings.defaultConversationProviderKey)
        PlayhouseDiagnostics.record("settings.write.succeeded", fields: ["setting": "defaultConversationProvider", "value": provider.rawValue])
    }

    var defaultParentFolderURL: URL? {
        WorkspaceSettings.validDirectoryURL(for: defaultParentFolderPath)
    }

    func requireRepositoryRootFolder() throws -> URL {
        guard let rootFolder = defaultParentFolderURL else {
            throw BridgeCommandError(
                code: "settings_required",
                message: "Set the repository root folder in Settings before sending a conversation."
            )
        }
        return rootFolder
    }

    func setDefaultParentFolder(_ path: String?) throws {
        PlayhouseDiagnostics.record("settings.write.started", fields: [
            "setting": "defaultParentFolder",
            "path": path ?? "",
            "cleared": String(path == nil || path?.isEmpty == true)
        ])
        guard let path, !path.isEmpty else {
            // An empty value is unset to every reader. Removing the key is not enough: with a
            // preferences file the app also writes, another process's value stays visible.
            defaults.set("", forKey: WorkspaceSettings.defaultParentFolderKey)
            PlayhouseDiagnostics.record("settings.write.succeeded", fields: [
                "setting": "defaultParentFolder",
                "cleared": "true"
            ])
            return
        }
        guard let url = WorkspaceSettings.validDirectoryURL(for: path) else {
            PlayhouseDiagnostics.record("settings.write.failed", fields: [
                "setting": "defaultParentFolder",
                "path": path,
                "errorCode": "invalid_argument"
            ])
            throw PlayhouseManagerError.invalidParentFolder(path)
        }
        defaults.set(url.path, forKey: WorkspaceSettings.defaultParentFolderKey)
        PlayhouseDiagnostics.record("settings.write.succeeded", fields: [
            "setting": "defaultParentFolder",
            "path": url.path,
            "cleared": "false"
        ])
    }

    func setLastSelectedRepositories(_ paths: [String]) throws {
        PlayhouseDiagnostics.record("settings.write.started", fields: [
            "setting": "lastSelectedRepositories",
            "requestedCount": String(paths.count),
            "requestedPaths": paths.joined(separator: "\n")
        ])
        var normalized: [String] = []
        for path in paths {
            let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) else {
                PlayhouseDiagnostics.record("settings.write.failed", fields: [
                    "setting": "lastSelectedRepositories",
                    "path": path,
                    "errorCode": "invalid_argument"
                ])
                throw PlayhouseManagerError.unavailableWorkspaceRoot(path)
            }
            if !normalized.contains(url.path) { normalized.append(url.path) }
        }
        defaults.set(normalized, forKey: WorkspaceSettings.lastSelectedRepositoriesKey)
        // The current selection moves to the front of the recent history; repositories
        // removed from it stay behind so they can be suggested again.
        let recent = Array((normalized + recentRepositories.filter { !normalized.contains($0) })
            .prefix(WorkspaceSettings.recentRepositoryHistoryLimit))
        defaults.set(recent, forKey: WorkspaceSettings.recentRepositoriesKey)
        PlayhouseDiagnostics.record("settings.write.succeeded", fields: [
            "setting": "lastSelectedRepositories",
            "repositoryCount": String(normalized.count),
            "repositoryPaths": normalized.joined(separator: "\n"),
            "recentRepositoryPaths": recent.joined(separator: "\n")
        ])
    }
}

@MainActor
final class WorkspaceManager {
    private let taskManager: BoardTaskManager?
    private let settingsManager: WorkspaceSettingsManager
    private let worktreeService = PlayhouseWorktreeService()

    init(
        taskManager: BoardTaskManager? = nil,
        settingsManager: WorkspaceSettingsManager? = nil
    ) {
        self.taskManager = taskManager
        self.settingsManager = settingsManager ?? WorkspaceSettingsManager()
    }

    func suggestedRepositories(parentPath: String) async throws -> [String] {
        guard let parent = WorkspaceSettings.validDirectoryURL(for: parentPath) else {
            throw PlayhouseManagerError.invalidParentFolder(parentPath)
        }
        PlayhouseDiagnostics.record("workspace.repositories.scan.started", fields: ["parentPath": parent.path])
        let repositories = await RepositoryScanner.scan(parent: parent).map(\.path)
        PlayhouseDiagnostics.record("workspace.repositories.scan.succeeded", fields: [
            "parentPath": parent.path,
            "repositoryCount": String(repositories.count),
            "repositories": repositories.joined(separator: "\n")
        ])
        return repositories
    }

    /// Recently selected repositories the repository picker offers before anything is typed.
    func recentRepositorySuggestions(for taskID: UUID) throws -> [String] {
        guard let taskManager else { throw BridgeCommandError(code: "internal_error", message: "Task manager is unavailable.") }
        let attached = try taskManager.get(taskID).repositoryWorktrees.map(\.repositoryPath)
        return settingsManager.recentRepositorySuggestions(excluding: attached)
    }

    func roots(for taskID: UUID) throws -> [String] {
        guard let taskManager else { throw BridgeCommandError(code: "internal_error", message: "Task manager is unavailable.") }
        PlayhouseDiagnostics.record("workspace.roots.read.started", fields: ["taskID": taskID.uuidString])
        let roots = try taskManager.get(taskID).workspaceRoots
        PlayhouseDiagnostics.record("workspace.roots.read.succeeded", fields: [
            "taskID": taskID.uuidString,
            "rootCount": String(roots.count),
            "roots": roots.joined(separator: "\n")
        ])
        return roots
    }

    @discardableResult
    func setRoots(_ roots: [String], for taskID: UUID) async throws -> BoardTaskRecord {
        guard let taskManager else { throw BridgeCommandError(code: "internal_error", message: "Task manager is unavailable.") }
        PlayhouseDiagnostics.record("workspace.roots.write.started", fields: [
            "taskID": taskID.uuidString,
            "requestedRoots": roots.joined(separator: "\n"),
            "requestedRootCount": String(roots.count)
        ])
        let record = try await taskManager.setWorkspaceRoots(taskID, roots: roots)
        PlayhouseDiagnostics.record("workspace.roots.write.succeeded", fields: [
            "taskID": taskID.uuidString,
            "rootCount": String(record.workspaceRoots.count),
            "roots": record.workspaceRoots.joined(separator: "\n")
        ])
        return record
    }

    @discardableResult
    func addRepository(_ repositoryPath: String, to taskID: UUID) async throws -> BoardTaskRecord {
        guard let taskManager else { throw BridgeCommandError(code: "internal_error", message: "Task manager is unavailable.") }
        PlayhouseDiagnostics.record("workspace.repository.add.started", fields: [
            "taskID": taskID.uuidString,
            "repositoryPath": repositoryPath
        ])
        _ = try await taskManager.addRepository(
            taskID,
            repositoryPath: repositoryPath,
            duringActiveConversation: true
        )
        let prepared = try await taskManager.prepareRepositoryWorktrees(taskID)
        try settingsManager.setLastSelectedRepositories(prepared.repositoryWorktrees.map(\.repositoryPath))
        PlayhouseDiagnostics.record("workspace.repository.add.succeeded", fields: [
            "taskID": taskID.uuidString,
            "repositoryPath": repositoryPath,
            "repositoryCount": String(prepared.repositoryWorktrees.count)
        ])
        return BoardTaskRecord(task: prepared)
    }

    @discardableResult
    func addRepositories(_ repositoryPaths: [String], to taskID: UUID) async throws -> BoardTaskRecord {
        guard let taskManager else { throw BridgeCommandError(code: "internal_error", message: "Task manager is unavailable.") }
        PlayhouseDiagnostics.record("workspace.repositories.add.started", fields: [
            "taskID": taskID.uuidString,
            "repositoryPaths": repositoryPaths.joined(separator: "\n"),
            "repositoryCount": String(repositoryPaths.count)
        ])
        _ = try await taskManager.addRepositories(
            taskID,
            repositoryPaths: repositoryPaths,
            duringActiveConversation: true
        )
        let taskBeforePreparation = try taskManager.taskModel(taskID)
        if ["Untitled task", "Generating title…"].contains(taskBeforePreparation.title),
           taskBeforePreparation.pendingSubmittedPrompt == nil {
            return BoardTaskRecord(task: taskBeforePreparation)
        }
        let record = try await taskManager.prepareRepositoryWorktrees(taskID)
        try settingsManager.setLastSelectedRepositories(record.repositoryWorktrees.map(\.repositoryPath))
        PlayhouseDiagnostics.record("workspace.repositories.add.succeeded", fields: [
            "taskID": taskID.uuidString,
            "repositoryCount": String(record.repositoryWorktrees.count)
        ])
        return BoardTaskRecord(task: record)
    }

    @discardableResult
    func replaceRepositories(_ repositoryPaths: [String], on taskID: UUID) async throws -> BoardTaskRecord {
        guard let taskManager else { throw BridgeCommandError(code: "internal_error", message: "Task manager is unavailable.") }
        PlayhouseDiagnostics.record("workspace.repositories.replace.started", fields: [
            "taskID": taskID.uuidString,
            "repositoryPaths": repositoryPaths.joined(separator: "\n"),
            "repositoryCount": String(repositoryPaths.count)
        ])
        _ = try await taskManager.replaceRepositories(
            taskID,
            repositoryPaths: repositoryPaths,
            duringActiveConversation: true
        )
        let record = try await taskManager.prepareRepositoryWorktrees(taskID)
        try settingsManager.setLastSelectedRepositories(record.repositoryWorktrees.map(\.repositoryPath))
        PlayhouseDiagnostics.record("workspace.repositories.replace.succeeded", fields: [
            "taskID": taskID.uuidString,
            "repositoryCount": String(record.repositoryWorktrees.count)
        ])
        return BoardTaskRecord(task: record)
    }

    @discardableResult
    func renewRepository(_ repositoryPath: String, on taskID: UUID) async throws -> BoardTaskRecord {
        guard let taskManager else { throw BridgeCommandError(code: "internal_error", message: "Task manager is unavailable.") }
        return BoardTaskRecord(task: try await taskManager.renewRepository(taskID, repositoryPath: repositoryPath))
    }

    @discardableResult
    func removeRepository(_ repositoryPath: String, from taskID: UUID) async throws -> BoardTaskRecord {
        guard let taskManager else { throw BridgeCommandError(code: "internal_error", message: "Task manager is unavailable.") }
        let record = try await taskManager.removeRepository(
            taskID,
            repositoryPath: repositoryPath,
            duringActiveConversation: true
        )
        try settingsManager.setLastSelectedRepositories(record.repositoryWorktrees.map(\.repositoryPath))
        return record
    }

    func reconcileDeferredRepositoryRemovals() async throws {
        guard let taskManager else { return }
        for (intentURL, intent) in try taskManager.deferredRepositoryRemovals() {
            guard try !taskManager.hasConversationTurnReservation(intent.taskID) else { continue }
            do {
                try await taskManager.withConversationTurnReservation(intent.taskID) {
                    try await taskManager.withTaskOperationLock(intent.taskID) {
                        guard FileManager.default.fileExists(atPath: intentURL.path) else { return }
                        if try taskManager.isRepositoryAttached(intent.record, to: intent.taskID) {
                            // The intent is written before detaching the task record. If the save failed or
                            // the service exited before it, leave the still-attached worktree in place.
                            try taskManager.clearDeferredRepositoryRemoval(at: intentURL)
                            return
                        }
                        if try await self.worktreeService.hasChanges(intent.record) {
                            PlayhouseDiagnostics.record("workspace.repository.deferred_removal_kept_dirty", fields: [
                                "taskID": intent.taskID.uuidString,
                                "repositoryPath": intent.record.repositoryPath,
                                "worktreePath": intent.record.worktreePath
                            ])
                        } else if FileManager.default.fileExists(atPath: intent.record.worktreePath) {
                            try await self.worktreeService.remove(intent.record)
                            PlayhouseDiagnostics.record("workspace.repository.deferred_removal_succeeded", fields: [
                                "taskID": intent.taskID.uuidString,
                                "repositoryPath": intent.record.repositoryPath,
                                "worktreePath": intent.record.worktreePath
                            ])
                        }
                        try taskManager.clearDeferredRepositoryRemoval(at: intentURL)
                    }
                }
            } catch {
                PlayhouseDiagnostics.record("workspace.repository.deferred_removal_failed", fields: [
                    "taskID": intent.taskID.uuidString,
                    "repositoryPath": intent.record.repositoryPath,
                    "worktreePath": intent.record.worktreePath,
                    "error": error.localizedDescription
                ])
            }
        }
    }

    /// How the task's terminal starts: the user's login shell, opened in the task's first created
    /// repository worktree. It never opens in a source repository or a context folder, and never
    /// creates a pending worktree, which the task's start names and creates.
    func terminalLaunch(for taskID: UUID) throws -> TaskTerminalLaunch {
        guard let taskManager else { throw BridgeCommandError(code: "internal_error", message: "Task manager is unavailable.") }
        let records = try taskManager.get(taskID).repositoryWorktrees
        if let reason = TaskTerminalLaunch.unavailableReason(for: records) {
            PlayhouseDiagnostics.record("workspace.terminal.launch.failed", fields: [
                "taskID": taskID.uuidString,
                "reason": records.isEmpty ? "no_repository" : "worktree_pending"
            ])
            throw BridgeCommandError(code: "terminal_unavailable", message: reason)
        }
        guard let directory = records.filter({ !$0.isPending }).map(\.worktreePath)
            .first(where: { WorkspaceSettings.validDirectoryURL(for: $0) != nil }) else {
            PlayhouseDiagnostics.record("workspace.terminal.launch.failed", fields: [
                "taskID": taskID.uuidString,
                "reason": "worktree_missing"
            ])
            throw BridgeCommandError(
                code: "terminal_unavailable",
                message: "This task's worktree no longer exists, so there is nowhere to open a terminal."
            )
        }
        let launch = TaskTerminalLaunch(
            taskID: taskID,
            directory: URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL.path,
            shell: TaskTerminalLaunch.loginShell(),
            arguments: ["-l"],
            environment: TaskTerminalLaunch.environment(taskID: taskID)
        )
        PlayhouseDiagnostics.record("workspace.terminal.launch.resolved", fields: [
            "taskID": taskID.uuidString,
            "directory": launch.directory,
            "shell": launch.shell
        ])
        return launch
    }

    func changes(for taskID: UUID) async throws -> WorkspaceChangeInventory {
        guard let taskManager else {
            throw BridgeCommandError(code: "internal_error", message: "Task manager is unavailable.")
        }
        PlayhouseDiagnostics.record("workspace.changes.read.started", fields: ["taskID": taskID.uuidString])
        let task = try taskManager.taskModel(taskID)
        let branchFrom = Dictionary(task.repositoryWorktrees.map { (URL(fileURLWithPath: $0.worktreePath, isDirectory: true).standardizedFileURL.path, $0.branchFrom) }) { existing, _ in existing }
        // A Done task's managed worktrees are gone; it has no changes to show until it renews one.
        let scannedRoots = try roots(for: taskID).filter { task.status != .done || FileManager.default.fileExists(atPath: $0) }
        let inventory = try await WorkspaceChangeScanner.inventory(workspaceRoots: scannedRoots, branchFromByRepository: branchFrom, viewedChanges: task.viewedWorkspaceChanges)
        PlayhouseDiagnostics.record("workspace.changes.read.succeeded", fields: [
            "taskID": taskID.uuidString,
            "unviewedCount": String(inventory.unviewed.count),
            "viewedCount": String(inventory.viewed.count)
        ])
        return inventory
    }

    func markViewed(for taskID: UUID, repository: String, path: String) async throws {
        guard let taskManager else {
            throw BridgeCommandError(code: "internal_error", message: "Task manager is unavailable.")
        }
        let task = try taskManager.taskModel(taskID)
        let inventory = try await changes(for: taskID)
        guard inventory.unviewed.contains(where: { $0.repository == URL(fileURLWithPath: repository).standardizedFileURL.path && $0.path == path }) else {
            throw BridgeCommandError(code: "not_found", message: "The file isn't currently an unviewed change.")
        }
        let snapshot = try await WorkspaceChangeScanner.captureViewedChange(workspaceRoots: task.workspaceRootPaths, repositoryPath: repository, relativePath: path)
        try await taskManager.setViewedWorkspaceChanges([snapshot], taskID: taskID)
    }

    /// Marks every current Changes entry viewed in one save, returning how many were marked.
    func markAllViewed(for taskID: UUID) async throws -> Int {
        guard let taskManager else {
            throw BridgeCommandError(code: "internal_error", message: "Task manager is unavailable.")
        }
        let task = try taskManager.taskModel(taskID)
        let inventory = try await changes(for: taskID)
        guard !inventory.unviewed.isEmpty else { return 0 }
        let snapshots = try await WorkspaceChangeScanner.captureViewedChanges(
            workspaceRoots: task.workspaceRootPaths,
            files: inventory.unviewed.map { ($0.repository, $0.path) }
        )
        try await taskManager.setViewedWorkspaceChanges(snapshots, taskID: taskID)
        return snapshots.count
    }

    /// Drops a file's viewed snapshot so its whole change from the branch base is listed under
    /// Changes again. The Git index is left as is: unviewing never discards staged work.
    func markUnviewed(for taskID: UUID, repository: String, path: String) async throws {
        guard let taskManager else {
            throw BridgeCommandError(code: "internal_error", message: "Task manager is unavailable.")
        }
        let repository = URL(fileURLWithPath: repository).standardizedFileURL.path
        let inventory = try await changes(for: taskID)
        guard inventory.viewed.contains(where: { $0.repository == repository && $0.path == path }) else {
            throw BridgeCommandError(code: "not_found", message: "The file isn't currently a viewed change.")
        }
        try await taskManager.removeViewedWorkspaceChange(repository: repository, path: path, taskID: taskID)
    }

    func diff(
        for taskID: UUID,
        repository: String,
        path: String,
        group: String
    ) async throws -> WorkspaceFileDiff {
        guard let taskManager else {
            throw BridgeCommandError(code: "internal_error", message: "Task manager is unavailable.")
        }
        guard let changeGroup = WorkspaceChangeGroup(rawValue: group) else {
            throw BridgeCommandError(code: "invalid_argument", message: "Change group must be 'unviewed' or 'viewed'.")
        }
        let task = try taskManager.taskModel(taskID)
        let normalizedRepository = URL(fileURLWithPath: repository, isDirectory: true).standardizedFileURL.path
        let branchFrom = task.repositoryWorktrees.first {
            URL(fileURLWithPath: $0.worktreePath, isDirectory: true).standardizedFileURL.path == normalizedRepository
        }?.branchFrom ?? "HEAD"
        PlayhouseDiagnostics.record("workspace.diff.read.started", fields: [
            "taskID": taskID.uuidString,
            "repositoryPath": repository,
            "path": path,
            "group": group
        ])
        let fileDiff = try await WorkspaceChangeScanner.diff(
            workspaceRoots: roots(for: taskID),
            repositoryPath: repository,
            relativePath: path,
            group: changeGroup,
            branchFrom: branchFrom,
            viewedChanges: task.viewedWorkspaceChanges
        )
        PlayhouseDiagnostics.record("workspace.diff.read.succeeded", fields: [
            "taskID": taskID.uuidString,
            "repositoryPath": repository,
            "path": path,
            "group": group,
            "originalBytes": String(fileDiff.original?.utf8.count ?? 0),
            "modifiedBytes": String(fileDiff.modified?.utf8.count ?? 0),
            "isText": String(fileDiff.isText)
        ])
        return fileDiff
    }
}
