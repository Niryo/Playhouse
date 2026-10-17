import Foundation
import SwiftData

enum StationAIStore {
    static func makeContainer(dataDirectory: String? = nil) throws -> ModelContainer {
        let schema = Schema([BoardTask.self])
        let storeURL: URL
        if let dataDirectory {
            let directory = URL(fileURLWithPath: dataDirectory, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            storeURL = directory.appendingPathComponent("StationAI.store")
        } else {
            let supportDirectory = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("StationAI", isDirectory: true)
            try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            storeURL = supportDirectory.appendingPathComponent("StationAI.store")
        }

        let configuration = ModelConfiguration(
            "StationAI",
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}

struct BoardTaskRecord: Codable, Equatable, Identifiable {
    let id: UUID
    let title: String
    let status: String
    let createdAt: Date
    let codexThreadID: String?
    let workspaceRoots: [String]
    let repositoryWorktrees: [RepositoryWorktreeRecord]
    let contextFolders: [String]

    init(task: BoardTask) {
        id = task.id
        title = task.title
        status = task.status.rawValue
        createdAt = task.createdAt
        codexThreadID = task.codexThreadID
        workspaceRoots = task.workspaceRootPaths
        repositoryWorktrees = task.repositoryWorktrees
        contextFolders = task.contextFolderPaths
    }
}

enum StationAIManagerError: LocalizedError {
    case invalidTitle
    case taskNotFound(UUID)
    case invalidStatus(String)
    case noWorkspaceRoots
    case unavailableWorkspaceRoot(String)
    case invalidParentFolder(String)
    case invalidMessage
    case repositoryAssigned(String)

    var errorDescription: String? {
        switch self {
        case .invalidTitle:
            "Task title can't be empty."
        case .taskNotFound(let id):
            "No task exists with ID \(id)."
        case .invalidStatus(let status):
            "Unknown task status '\(status)'. Valid statuses: \(TaskStatus.allCases.map(\.rawValue).joined(separator: ", "))."
        case .noWorkspaceRoots:
            "Choose at least one working folder."
        case .unavailableWorkspaceRoot(let path):
            "The working folder is unavailable: \(path)"
        case .invalidParentFolder(let path):
            "The parent folder isn't an available directory: \(path)"
        case .invalidMessage:
            "Message can't be empty."
        case .repositoryAssigned(let path):
            "This branch worktree is already assigned to another active task: \(path). Choose another branch or finish that task first."
        }
    }
}

@MainActor
final class BoardTaskManager {
    private let modelContext: ModelContext
    private let worktreeRoot: URL

    init(modelContext: ModelContext, worktreeRoot: URL = StationAIWorktreeManager.defaultRoot()) {
        self.modelContext = modelContext
        self.worktreeRoot = worktreeRoot
    }

    func list() throws -> [BoardTaskRecord] {
        let descriptor = FetchDescriptor<BoardTask>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        return try modelContext.fetch(descriptor).map(BoardTaskRecord.init(task:))
    }

    func get(_ id: UUID) throws -> BoardTaskRecord {
        BoardTaskRecord(task: try requireTask(id))
    }

    @discardableResult
    func create(title: String, workspaceRoots: [String]) throws -> BoardTaskRecord {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else { throw StationAIManagerError.invalidTitle }
        let normalizedRoots = try Self.normalizeRoots(workspaceRoots)
        let task = BoardTask(title: normalizedTitle, status: .backlog, workspaceRootPaths: normalizedRoots)
        modelContext.insert(task)
        try modelContext.save()
        return BoardTaskRecord(task: task)
    }

    @discardableResult
    func create(title: String, repositories: [RepositoryWorktreeSpec], contextFolders: [String]) throws -> BoardTaskRecord {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else { throw StationAIManagerError.invalidTitle }
        let folders = try Self.normalizeOptionalRoots(contextFolders)
        guard !repositories.isEmpty || !folders.isEmpty else { throw StationAIManagerError.noWorkspaceRoots }
        var worktrees: [RepositoryWorktreeRecord] = []
        do {
            for spec in repositories {
                let record = try StationAIWorktreeManager.resolve(spec: spec, title: normalizedTitle, root: worktreeRoot)
                let normalizedWorktree = URL(fileURLWithPath: record.worktreePath).standardizedFileURL.path
                guard !worktrees.contains(where: { $0.repositoryPath == record.repositoryPath }) else {
                    throw BridgeCommandError(code: "invalid_argument", message: "A repository can be selected only once per task: \(record.repositoryPath)")
                }
                for other in try listModels() where other.status != .done {
                    if other.repositoryWorktrees.contains(where: { URL(fileURLWithPath: $0.worktreePath).standardizedFileURL.path == normalizedWorktree }) {
                        throw StationAIManagerError.repositoryAssigned(normalizedWorktree)
                    }
                }
                worktrees.append(record)
            }
        } catch {
            for record in worktrees where record.createdByStationAI && FileManager.default.fileExists(atPath: record.worktreePath) {
                try? StationAIWorktreeManager.remove(record)
            }
            throw error
        }
        let roots = try Self.normalizeOptionalRoots(worktrees.map(\.worktreePath) + folders)
        let task = BoardTask(title: normalizedTitle, status: .backlog, workspaceRootPaths: roots)
        task.repositoryWorktrees = worktrees
        task.contextFolderPaths = folders
        modelContext.insert(task)
        try modelContext.save()
        return BoardTaskRecord(task: task)
    }

    @discardableResult
    func move(_ id: UUID, to statusName: String) throws -> BoardTaskRecord {
        guard let status = TaskStatus(rawValue: statusName) else {
            throw StationAIManagerError.invalidStatus(statusName)
        }
        let task = try requireTask(id)
        if status == .done, task.status != .done {
            for worktree in task.repositoryWorktrees { try StationAIWorktreeManager.preflightRemoval(worktree) }
            for worktree in task.repositoryWorktrees { try StationAIWorktreeManager.remove(worktree) }
            task.workspaceRootPaths = task.contextFolderPaths
        } else if task.status == .done, status != .done {
            let worktrees = try task.repositoryWorktrees.map { record in
                try StationAIWorktreeManager.resolve(
                    spec: RepositoryWorktreeSpec(repositoryPath: record.repositoryPath, branch: record.branch, branchFrom: record.branchFrom),
                    title: task.title,
                    root: worktreeRoot
                )
            }
            task.repositoryWorktrees = worktrees
            task.workspaceRootPaths = try Self.normalizeOptionalRoots(worktrees.map(\.worktreePath) + task.contextFolderPaths)
        }
        task.status = status
        try modelContext.save()
        return BoardTaskRecord(task: task)
    }

    @discardableResult
    func rename(_ id: UUID, title: String) throws -> BoardTaskRecord {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else { throw StationAIManagerError.invalidTitle }
        let task = try requireTask(id)
        task.title = normalizedTitle
        try modelContext.save()
        return BoardTaskRecord(task: task)
    }

    @discardableResult
    func setWorkspaceRoots(_ id: UUID, roots: [String]) throws -> BoardTaskRecord {
        let task = try requireTask(id)
        if task.repositoryWorktrees.isEmpty {
            task.workspaceRootPaths = try Self.normalizeRoots(roots)
            task.contextFolderPaths = task.workspaceRootPaths
        } else {
            let paths = try Self.normalizeOptionalRoots(roots)
            let existingPaths = Set(task.repositoryWorktrees.map { URL(fileURLWithPath: $0.worktreePath).standardizedFileURL.path })
            let retained = task.repositoryWorktrees.filter { existingPaths.contains(URL(fileURLWithPath: $0.worktreePath).standardizedFileURL.path) && paths.contains(URL(fileURLWithPath: $0.worktreePath).standardizedFileURL.path) }
            var worktrees = retained
            var folders: [String] = []
            for path in paths where !existingPaths.contains(path) {
                if FileManager.default.fileExists(atPath: URL(fileURLWithPath: path).appendingPathComponent(".git").path) {
                    let record = try StationAIWorktreeManager.resolve(
                        spec: RepositoryWorktreeSpec(repositoryPath: path, branch: nil, branchFrom: nil),
                        title: task.title,
                        root: worktreeRoot
                    )
                    let worktreePath = URL(fileURLWithPath: record.worktreePath).standardizedFileURL.path
                    for other in try listModels() where other.id != id && other.status != .done {
                        if other.repositoryWorktrees.contains(where: { URL(fileURLWithPath: $0.worktreePath).standardizedFileURL.path == worktreePath }) {
                            if record.createdByStationAI { try? StationAIWorktreeManager.remove(record) }
                            throw StationAIManagerError.repositoryAssigned(worktreePath)
                        }
                    }
                    worktrees.append(record)
                } else {
                    folders.append(path)
                }
            }
            task.repositoryWorktrees = worktrees
            task.contextFolderPaths = folders
            let resolvedRoots = try Self.normalizeOptionalRoots(worktrees.map(\.worktreePath) + folders)
            guard !resolvedRoots.isEmpty else { throw StationAIManagerError.noWorkspaceRoots }
            task.workspaceRootPaths = resolvedRoots
        }
        try modelContext.save()
        return BoardTaskRecord(task: task)
    }

    func delete(_ id: UUID) throws {
        let task = try requireTask(id)
        for worktree in task.repositoryWorktrees {
            try StationAIWorktreeManager.removeAfterConfirmation(worktree)
        }
        modelContext.delete(task)
        try modelContext.save()
    }

    func taskModel(_ id: UUID) throws -> BoardTask {
        try requireTask(id)
    }

    func deleteRequiresConfirmation(_ id: UUID, client: CodexAppServerClient) async throws -> Bool {
        let task = try requireTask(id)
        let dirtyWorktree = try task.repositoryWorktrees.contains { try StationAIWorktreeManager.hasChanges($0) }
        guard task.codexThreadID != nil else { return dirtyWorktree }
        let history = try await CodexConversationManager(tasks: self, client: client).history(taskID: id)
        let hasConversation = history.messages.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            || !history.activities.isEmpty || history.diff != nil
        return dirtyWorktree || hasConversation
    }

    func save() throws {
        try modelContext.save()
    }

    private func requireTask(_ id: UUID) throws -> BoardTask {
        var descriptor = FetchDescriptor<BoardTask>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let task = try modelContext.fetch(descriptor).first else {
            throw StationAIManagerError.taskNotFound(id)
        }
        return task
    }

    private static func normalizeRoots(_ roots: [String]) throws -> [String] {
        let paths = roots.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path }
        guard !paths.isEmpty else { throw StationAIManagerError.noWorkspaceRoots }
        var unique: [String] = []
        for path in paths where !unique.contains(path) {
            guard WorkspaceSettings.validDirectoryURL(for: path) != nil else {
                throw StationAIManagerError.unavailableWorkspaceRoot(path)
            }
            unique.append(path)
        }
        return unique
    }

    private static func normalizeOptionalRoots(_ roots: [String]) throws -> [String] {
        let paths = roots.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path }
        var unique: [String] = []
        for path in paths where !unique.contains(path) {
            guard WorkspaceSettings.validDirectoryURL(for: path) != nil else {
                throw StationAIManagerError.unavailableWorkspaceRoot(path)
            }
            unique.append(path)
        }
        return unique
    }

    private func listModels() throws -> [BoardTask] {
        try modelContext.fetch(FetchDescriptor<BoardTask>())
    }
}

@MainActor
final class WorkspaceSettingsManager {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = WorkspaceSettings.preferencesStore) {
        self.defaults = defaults
    }

    var defaultParentFolderPath: String {
        defaults.string(forKey: WorkspaceSettings.defaultParentFolderKey) ?? ""
    }

    var defaultParentFolderURL: URL? {
        WorkspaceSettings.validDirectoryURL(for: defaultParentFolderPath)
    }

    func setDefaultParentFolder(_ path: String?) throws {
        guard let path, !path.isEmpty else {
            defaults.removeObject(forKey: WorkspaceSettings.defaultParentFolderKey)
            return
        }
        guard let url = WorkspaceSettings.validDirectoryURL(for: path) else {
            throw StationAIManagerError.invalidParentFolder(path)
        }
        defaults.set(url.path, forKey: WorkspaceSettings.defaultParentFolderKey)
    }
}

@MainActor
final class WorkspaceManager {
    private let taskManager: BoardTaskManager?

    init(taskManager: BoardTaskManager? = nil) {
        self.taskManager = taskManager
    }

    func suggestedRepositories(parentPath: String) async throws -> [String] {
        guard let parent = WorkspaceSettings.validDirectoryURL(for: parentPath) else {
            throw StationAIManagerError.invalidParentFolder(parentPath)
        }
        return await RepositoryScanner.scan(parent: parent).map(\.path)
    }

    func roots(for taskID: UUID) throws -> [String] {
        guard let taskManager else { throw BridgeCommandError(code: "internal_error", message: "Task manager is unavailable.") }
        return try taskManager.get(taskID).workspaceRoots
    }

    @discardableResult
    func setRoots(_ roots: [String], for taskID: UUID) throws -> BoardTaskRecord {
        guard let taskManager else { throw BridgeCommandError(code: "internal_error", message: "Task manager is unavailable.") }
        return try taskManager.setWorkspaceRoots(taskID, roots: roots)
    }

    func changes(for taskID: UUID) async throws -> WorkspaceChangeInventory {
        guard taskManager != nil else {
            throw BridgeCommandError(code: "internal_error", message: "Task manager is unavailable.")
        }
        return try await WorkspaceChangeScanner.inventory(workspaceRoots: roots(for: taskID))
    }

    func diff(
        for taskID: UUID,
        repository: String,
        path: String,
        group: String
    ) async throws -> WorkspaceFileDiff {
        guard taskManager != nil else {
            throw BridgeCommandError(code: "internal_error", message: "Task manager is unavailable.")
        }
        guard let changeGroup = WorkspaceChangeGroup(rawValue: group) else {
            throw BridgeCommandError(code: "invalid_argument", message: "Change group must be 'staged' or 'working'.")
        }
        return try await WorkspaceChangeScanner.diff(
            workspaceRoots: roots(for: taskID),
            repositoryPath: repository,
            relativePath: path,
            group: changeGroup
        )
    }
}

struct ConversationUpdate: Codable {
    let type: String
    var text: String?
    var activity: CodexActivity?
    var diff: String?
    var history: CodexThreadHistory?
    var message: String?
}

@MainActor
final class CodexConversationManager {
    private let tasks: BoardTaskManager
    private let client: CodexAppServerClient

    init(tasks: BoardTaskManager, client: CodexAppServerClient) {
        self.tasks = tasks
        self.client = client
    }

    func history(taskID: UUID, onActionRequest: @escaping () -> Void = {}) async throws -> CodexThreadHistory {
        let task = try tasks.taskModel(taskID)
        guard let threadID = task.codexThreadID else {
            return CodexThreadHistory(messages: [], activities: [], diff: nil)
        }
        let workspace = try CodexWorkspaceContext(roots: task.workspaceRootPaths.map {
            URL(fileURLWithPath: $0, isDirectory: true)
        })
        return try await client.loadThread(id: threadID, workspace: workspace, onActionRequest: onActionRequest)
    }

    func models(taskID: UUID) async throws -> [CodexModelOption] {
        let task = try tasks.taskModel(taskID)
        let workspace = try CodexWorkspaceContext(roots: task.workspaceRootPaths.map {
            URL(fileURLWithPath: $0, isDirectory: true)
        })
        return try await client.availableModels(workspace: workspace)
    }

    func interrupt(taskID: UUID) async throws -> Bool {
        let task = try tasks.taskModel(taskID)
        guard let threadID = task.codexThreadID else { return false }
        return try await client.interruptActiveTurn(threadID: threadID)
    }

    func send(
        taskID: UUID,
        text: String,
        mode: CodexConversationMode = .code,
        modelID: String = CodexAppServerClient.modelID,
        onUpdate: @escaping (ConversationUpdate) -> Void = { _ in }
    ) async throws -> CodexThreadHistory {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else { throw StationAIManagerError.invalidMessage }
        guard Self.isValidModelID(modelID) else {
            throw BridgeCommandError(code: "invalid_argument", message: "Model ID must contain only letters, digits, dots, underscores, and hyphens.")
        }
        let task = try tasks.taskModel(taskID)
        let roots = task.workspaceRootPaths.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let workspace = try CodexWorkspaceContext(roots: roots)
        let threadID: String
        if let existing = task.codexThreadID {
            threadID = existing
        } else {
            threadID = try await client.startThread(workspace: workspace, modelID: modelID)
            task.codexThreadID = threadID
            do {
                try tasks.save()
            } catch {
                task.codexThreadID = nil
                throw error
            }
        }

        onUpdate(ConversationUpdate(type: "started"))
        try await client.sendMessage(
            normalizedText,
            mode: mode,
            modelID: modelID,
            threadID: threadID,
            workspace: workspace,
            onDelta: { delta in onUpdate(ConversationUpdate(type: "text_delta", text: delta)) },
            onFinalMessage: { message in onUpdate(ConversationUpdate(type: "assistant_final", text: message)) },
            onActivity: { activity in onUpdate(ConversationUpdate(type: "activity", activity: activity)) },
            onDiff: { diff in onUpdate(ConversationUpdate(type: "diff", diff: diff.unifiedDiff)) },
            onHistory: { history in onUpdate(ConversationUpdate(type: "history", history: history)) },
            onActionRequest: {
                let message = "Codex requested an approval. StationAI denied it because approval prompts are disabled."
                onUpdate(ConversationUpdate(type: "action_notice", message: message))
            }
        )
        let finalHistory = try await history(taskID: taskID) {
            onUpdate(ConversationUpdate(
                type: "action_notice",
                message: "Codex requested an approval. StationAI denied it because approval prompts are disabled."
            ))
        }
        onUpdate(ConversationUpdate(type: "completed", history: finalHistory))
        return finalHistory
    }

    private static func isValidModelID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 100 && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-").contains($0)
        }
    }
}

struct BridgeCommandError: LocalizedError {
    let code: String
    let message: String
    var errorDescription: String? { message }
}

@MainActor
final class StationAIBridgeRuntime {
    func perform(
        _ request: BridgeRequest,
        eventHandler: @escaping (BridgeEvent) -> Void
    ) async -> BridgeResponse {
        guard request.version == BridgeContract.currentVersion else {
            return .failure(request, code: "unsupported_version", message: "Unsupported bridge version \(request.version). This service supports version \(BridgeContract.currentVersion).")
        }

        do {
            let dataDirectory: String?
            #if DEBUG
            dataDirectory = request.dataDirectory
            #else
            dataDirectory = nil
            #endif
            let container = try StationAIStore.makeContainer(dataDirectory: dataDirectory)
            let context = ModelContext(container)
            let worktreeRoot: URL
            #if DEBUG
            worktreeRoot = request.worktreeDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? StationAIWorktreeManager.defaultRoot()
            #else
            worktreeRoot = StationAIWorktreeManager.defaultRoot()
            #endif
            let taskManager = BoardTaskManager(modelContext: context, worktreeRoot: worktreeRoot)
            let preferences: UserDefaults
            #if DEBUG
            if let suite = request.defaultsSuite, let isolated = UserDefaults(suiteName: suite) {
                preferences = isolated
            } else {
                let applicationIdentifier = Bundle.main.infoDictionary?["StationAIApplicationBundleIdentifier"] as? String
                    ?? "com.stationai.app"
                preferences = UserDefaults(suiteName: applicationIdentifier) ?? .standard
            }
            #else
            let applicationIdentifier = Bundle.main.infoDictionary?["StationAIApplicationBundleIdentifier"] as? String
                ?? "com.stationai.app"
            preferences = UserDefaults(suiteName: applicationIdentifier) ?? .standard
            #endif
            let settings = WorkspaceSettingsManager(defaults: preferences)
            let workspaces = WorkspaceManager(taskManager: taskManager)

            let result: BridgeValue
            switch request.command {
            case "status":
                result = .object(["service": .string("StationAI"), "bridgeVersion": .integer(BridgeContract.currentVersion)])
            case "board.list", "task.list":
                result = try Self.value(["tasks": taskManager.list()])
            case "task.create":
                let title = try request.requiredString("title")
                let roots = try request.requiredStrings("roots")
                let repositories = try request.repositorySpecs("repositories")
                result = try Self.value(taskManager.create(title: title, repositories: repositories, contextFolders: roots))
            case "task.get", "task.show":
                result = try Self.value(taskManager.get(request.requiredUUID("taskID")))
            case "task.move":
                let taskID = try request.requiredUUID("taskID")
                let status = try request.requiredString("status")
                result = try Self.value(taskManager.move(taskID, to: status))
            case "task.rename":
                let taskID = try request.requiredUUID("taskID")
                let title = try request.requiredString("title")
                result = try Self.value(taskManager.rename(taskID, title: title))
            case "task.delete":
                try taskManager.delete(request.requiredUUID("taskID"))
                result = .object(["deleted": .boolean(true)])
            case "task.delete.requires-confirmation":
                let requiresConfirmation = try await taskManager.deleteRequiresConfirmation(
                    request.requiredUUID("taskID"),
                    client: CodexAppServerClient()
                )
                result = .object(["requiresConfirmation": .boolean(requiresConfirmation)])
            case "task.roots.get", "workspace.roots":
                result = .object(["roots": .array(try workspaces.roots(for: request.requiredUUID("taskID")).map(BridgeValue.string))])
            case "task.roots.set":
                let roots = try request.requiredStrings("roots")
                result = try Self.value(workspaces.setRoots(roots, for: request.requiredUUID("taskID")))
            case "task.changes.list":
                result = try Self.value(await workspaces.changes(for: request.requiredUUID("taskID")))
            case "task.changes.diff":
                result = try Self.value(await workspaces.diff(
                    for: request.requiredUUID("taskID"),
                    repository: request.requiredString("repository"),
                    path: request.requiredString("path"),
                    group: request.requiredString("group")
                ))
            case "workspace.suggest":
                let parent = try request.requiredString("parent")
                result = .object(["repositories": .array(try await workspaces.suggestedRepositories(parentPath: parent).map(BridgeValue.string))])
            case "settings.get":
                result = .object([
                    "defaultParentFolder": settings.defaultParentFolderPath.isEmpty ? .null : .string(settings.defaultParentFolderPath),
                    "defaultParentAvailable": .boolean(settings.defaultParentFolderURL != nil)
                ])
            case "settings.set-parent":
                try settings.setDefaultParentFolder(request.requiredString("path"))
                result = .object(["defaultParentFolder": .string(settings.defaultParentFolderPath)])
            case "settings.clear-parent":
                try settings.setDefaultParentFolder(nil)
                result = .object(["defaultParentFolder": .null])
            case "conversation.history":
                let conversations = CodexConversationManager(tasks: taskManager, client: CodexAppServerClient())
                result = try Self.value(await conversations.history(taskID: request.requiredUUID("taskID")))
            case "conversation.models":
                let conversations = CodexConversationManager(tasks: taskManager, client: CodexAppServerClient())
                result = .object(["models": .array(try await conversations.models(taskID: request.requiredUUID("taskID")).map { try Self.value($0) })])
            case "conversation.send":
                let taskID = try request.requiredUUID("taskID")
                let message = try request.requiredString("message")
                let modeValue = request.arguments["mode"]?.string ?? CodexConversationMode.code.rawValue
                guard let mode = CodexConversationMode(rawValue: modeValue) else {
                    throw BridgeCommandError(
                        code: "invalid_argument",
                        message: "Unknown conversation mode '\(modeValue)'. Valid modes: default, plan."
                    )
                }
                let modelID = request.arguments["model"]?.string ?? CodexAppServerClient.modelID
                let conversations = CodexConversationManager(tasks: taskManager, client: CodexAppServerClient())
                let history = try await conversations.send(taskID: taskID, text: message, mode: mode, modelID: modelID) { update in
                    if let payload = try? Self.value(update) {
                        eventHandler(BridgeEvent(requestID: request.id, type: update.type, payload: payload))
                    }
                }
                result = try Self.value(history)
            default:
                throw BridgeCommandError(code: "unknown_command", message: "Unknown command '\(request.command)'. Run 'stationai help' to list commands.")
            }
            return .success(request, result: result)
        } catch let error as BridgeCommandError {
            return .failure(request, code: error.code, message: error.message)
        } catch let error as StationAIManagerError {
            let code: String
            switch error {
            case .taskNotFound: code = "not_found"
            case .invalidTitle, .invalidStatus, .noWorkspaceRoots, .unavailableWorkspaceRoot, .invalidParentFolder, .invalidMessage, .repositoryAssigned: code = "invalid_argument"
            }
            return .failure(request, code: code, message: error.localizedDescription)
        } catch {
            return .failure(request, code: "operation_failed", message: error.localizedDescription)
        }
    }

    private static func value<T: Encodable>(_ value: T) throws -> BridgeValue {
        let data = try JSONEncoder.bridge.encode(value)
        return try JSONDecoder().decode(BridgeValue.self, from: data)
    }
}

private extension JSONEncoder {
    static var bridge: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension BridgeRequest {
    func requiredString(_ name: String) throws -> String {
        guard let value = arguments[name]?.string, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BridgeCommandError(code: "invalid_argument", message: "Missing required argument: \(name).")
        }
        return value
    }

    func requiredStrings(_ name: String) throws -> [String] {
        guard let value = arguments[name]?.strings else {
            throw BridgeCommandError(code: "invalid_argument", message: "Missing required list argument: \(name).")
        }
        return value
    }

    func repositorySpecs(_ name: String) throws -> [RepositoryWorktreeSpec] {
        guard case .array(let values)? = arguments[name] else {
            throw BridgeCommandError(code: "invalid_argument", message: "Missing repository list argument: \(name).")
        }
        return try values.map { value in
            guard let object = value.object, let path = object["repositoryPath"]?.string else {
                throw BridgeCommandError(code: "invalid_argument", message: "Each repository must include a repositoryPath.")
            }
            return RepositoryWorktreeSpec(
                repositoryPath: path,
                branch: object["branch"]?.string,
                branchFrom: object["branchFrom"]?.string
            )
        }
    }

    func requiredUUID(_ name: String) throws -> UUID {
        guard let rawValue = arguments[name]?.string, let id = UUID(uuidString: rawValue) else {
            throw BridgeCommandError(code: "invalid_argument", message: "Argument \(name) must be a task UUID.")
        }
        return id
    }
}
