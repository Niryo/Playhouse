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

    init(task: BoardTask) {
        id = task.id
        title = task.title
        status = task.status.rawValue
        createdAt = task.createdAt
        codexThreadID = task.codexThreadID
        workspaceRoots = task.workspaceRootPaths
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
        }
    }
}

@MainActor
final class BoardTaskManager {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
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
    func move(_ id: UUID, to statusName: String) throws -> BoardTaskRecord {
        guard let status = TaskStatus(rawValue: statusName) else {
            throw StationAIManagerError.invalidStatus(statusName)
        }
        let task = try requireTask(id)
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
        let normalizedRoots = try Self.normalizeRoots(roots)
        let task = try requireTask(id)
        task.workspaceRootPaths = normalizedRoots
        try modelContext.save()
        return BoardTaskRecord(task: task)
    }

    func delete(_ id: UUID) throws {
        modelContext.delete(try requireTask(id))
        try modelContext.save()
    }

    func taskModel(_ id: UUID) throws -> BoardTask {
        try requireTask(id)
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

    func send(
        taskID: UUID,
        text: String,
        onUpdate: @escaping (ConversationUpdate) -> Void = { _ in }
    ) async throws -> CodexThreadHistory {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else { throw StationAIManagerError.invalidMessage }
        let task = try tasks.taskModel(taskID)
        let roots = task.workspaceRootPaths.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let workspace = try CodexWorkspaceContext(roots: roots)
        let threadID: String
        if let existing = task.codexThreadID {
            threadID = existing
        } else {
            threadID = try await client.startThread(workspace: workspace)
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
            let taskManager = BoardTaskManager(modelContext: context)
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
                result = try Self.value(taskManager.create(title: title, workspaceRoots: roots))
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
            case "task.roots.get", "workspace.roots":
                result = .object(["roots": .array(try workspaces.roots(for: request.requiredUUID("taskID")).map(BridgeValue.string))])
            case "task.roots.set":
                let roots = try request.requiredStrings("roots")
                result = try Self.value(workspaces.setRoots(roots, for: request.requiredUUID("taskID")))
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
            case "conversation.send":
                let taskID = try request.requiredUUID("taskID")
                let message = try request.requiredString("message")
                let conversations = CodexConversationManager(tasks: taskManager, client: CodexAppServerClient())
                let history = try await conversations.send(taskID: taskID, text: message) { update in
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
            case .invalidTitle, .invalidStatus, .noWorkspaceRoots, .unavailableWorkspaceRoot, .invalidParentFolder, .invalidMessage: code = "invalid_argument"
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

    func requiredUUID(_ name: String) throws -> UUID {
        guard let rawValue = arguments[name]?.string, let id = UUID(uuidString: rawValue) else {
            throw BridgeCommandError(code: "invalid_argument", message: "Argument \(name) must be a task UUID.")
        }
        return id
    }
}
