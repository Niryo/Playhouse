import Foundation
import SwiftData
import Darwin

@MainActor
struct CodexTaskTitleGenerator {
    let client: CodexAppServerClient

    func generateTitle(from prompt: String, workspace: CodexWorkspaceContext, taskID: UUID) async -> String? {
        var phase = "thread-start"
        var threadID = ""
        do {
            threadID = try await client.startThread(workspace: workspace, modelID: CodexAppServerClient.modelID)
            StationAIDiagnostics.record("task.title_generation.started", fields: [
                "taskID": taskID.uuidString,
                "threadID": threadID,
                "modelID": CodexAppServerClient.modelID
            ])
            var generated: String?
            phase = "title-turn"
            try await client.sendMessage(
                "Write a concise task title of at most 8 words for this request. Return only the title:\n\n\(prompt)",
                mode: .plan,
                modelID: CodexAppServerClient.modelID,
                threadID: threadID,
                workspace: workspace,
                onDelta: { _ in },
                onFinalMessage: { generated = $0.trimmingCharacters(in: .whitespacesAndNewlines) },
                onActivity: { _ in }, onDiff: { _ in }, onHistory: { _ in },
                onActionRequest: {}, onUserInput: { _ in }
            )
            guard let title = generated?.components(separatedBy: .newlines).first,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                StationAIDiagnostics.record("task.title_generation.failed", fields: [
                    "taskID": taskID.uuidString,
                    "threadID": threadID,
                    "phase": phase,
                    "reason": "empty_response"
                ])
                return nil
            }
            StationAIDiagnostics.record("task.title_generation.succeeded", fields: [
                "taskID": taskID.uuidString,
                "threadID": threadID,
                "phase": phase,
                "titleWordCount": String(title.split(whereSeparator: \.isWhitespace).count)
            ])
            return title
        } catch {
            var fields = StationAIDiagnostics.errorFields(error, redacting: [prompt])
            fields["taskID"] = taskID.uuidString
            fields["threadID"] = threadID
            fields["phase"] = phase
            StationAIDiagnostics.record("task.title_generation.failed", fields: fields)
            return nil
        }
    }
}

enum StationAITaskTitleDiagnostics {
    static func state(of title: String) -> String {
        switch title {
        case "Untitled task": "untitled"
        case "Generating title…": "generating"
        default: "custom"
        }
    }
}

@MainActor
enum StationAIStore {
    private static var lifecycleGateHeld = false
    private static var lifecycleGateWaiters: [CheckedContinuation<Void, Never>] = []

    static func storeURL(dataDirectory: String? = nil) throws -> URL {
        if let dataDirectory {
            return URL(fileURLWithPath: dataDirectory, isDirectory: true).appendingPathComponent("StationAI.store")
        }
        let supportDirectory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("StationAI", isDirectory: true)
        return supportDirectory.appendingPathComponent("StationAI.store")
    }

    static func makeContainer(dataDirectory: String? = nil) throws -> ModelContainer {
        StationAIDiagnostics.useDataDirectory(dataDirectory)
        let schema = Schema([BoardTask.self])
        let storeURL = try Self.storeURL(dataDirectory: dataDirectory)
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let configuration = ModelConfiguration(
            "StationAI",
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    @MainActor
    static func prepareLifecycle(container: ModelContainer, dataDirectory: String? = nil) async throws {
        await Self.acquireLifecycleGate()
        defer { Self.releaseLifecycleGate() }
        let storeURL = try Self.storeURL(dataDirectory: dataDirectory)
        let directory = storeURL.deletingLastPathComponent()
        let marker = directory.appendingPathComponent("task-lifecycle-v2-reset")
        let lockURL = directory.appendingPathComponent("task-lifecycle-v2-reset.lock")
        let lockDescriptor = try await Self.acquireLifecycleLock(at: lockURL)
        defer { _ = Darwin.close(lockDescriptor) }
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }

        let context = ModelContext(container)
        let dirtyWorktrees = try await BoardTaskManager(modelContext: context).resetAllTasksForLifecycle()
        if !dirtyWorktrees.isEmpty {
            let notice = directory.appendingPathComponent("task-lifecycle-v2-notice.json")
            try JSONEncoder().encode(dirtyWorktrees).write(to: notice, options: .atomic)
        }
        try Data("1\n".utf8).write(to: marker, options: .atomic)
    }

    private static func acquireLifecycleGate() async {
        guard lifecycleGateHeld else {
            lifecycleGateHeld = true
            return
        }
        await withCheckedContinuation { continuation in
            lifecycleGateWaiters.append(continuation)
        }
    }

    private static func releaseLifecycleGate() {
        guard !lifecycleGateWaiters.isEmpty else {
            lifecycleGateHeld = false
            return
        }
        lifecycleGateWaiters.removeFirst().resume()
    }

    private static func acquireLifecycleLock(at url: URL) async throws -> Int32 {
        try await Task.detached(priority: .utility) {
            let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else {
                throw StoreLifecycleLockError(message: "Couldn't open the task-store lifecycle lock (errno \(errno)).")
            }
            var lock = flock()
            lock.l_type = Int16(F_WRLCK)
            lock.l_whence = Int16(SEEK_SET)
            while Darwin.fcntl(descriptor, F_SETLK, &lock) != 0 {
                if errno == EACCES || errno == EAGAIN {
                    usleep(50_000)
                    continue
                }
                let code = errno
                _ = Darwin.close(descriptor)
                throw StoreLifecycleLockError(message: "Couldn't acquire the task-store lifecycle lock (errno \(code)).")
            }
            return descriptor
        }.value
    }

    static func takeLifecycleResetNotice(dataDirectory: String? = nil) -> [String] {
        let directory: URL
        if let dataDirectory {
            directory = URL(fileURLWithPath: dataDirectory, isDirectory: true)
        } else if let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            directory = support.appendingPathComponent("StationAI", isDirectory: true)
        } else {
            return []
        }
        let notice = directory.appendingPathComponent("task-lifecycle-v2-notice.json")
        guard let data = try? Data(contentsOf: notice),
              let paths = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        try? FileManager.default.removeItem(at: notice)
        return paths
    }
}

private struct StoreLifecycleLockError: Error, LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

private struct BridgeFileLockError: Error, LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

private enum RepositoryAllocationLock {
    static func fileName(for repositoryPath: String) -> String {
        let canonicalPath = URL(fileURLWithPath: repositoryPath)
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
        var hash: UInt64 = 14695981039346656037
        for byte in canonicalPath.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1099511628211
        }
        return String(format: "%016llx.lock", hash)
    }
}

@MainActor
private enum TaskOperationLockGate {
    private static var heldKeys: Set<String> = []
    private static var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    static func acquire(_ key: String) async {
        guard !heldKeys.contains(key) else {
            await withCheckedContinuation { continuation in
                waiters[key, default: []].append(continuation)
            }
            return
        }
        heldKeys.insert(key)
    }

    static func isHeld(_ key: String) -> Bool {
        heldKeys.contains(key)
    }

    static func release(_ key: String) {
        guard var pending = waiters[key], !pending.isEmpty else {
            heldKeys.remove(key)
            return
        }
        let next = pending.removeFirst()
        waiters[key] = pending.isEmpty ? nil : pending
        next.resume()
    }
}

struct BoardTaskRecord: Codable, Equatable, Identifiable {
    let id: UUID
    let title: String
    let status: String
    let statusMessage: String?
    let progressType: String?
    let progressLabel: String?
    let progressDetail: String?
    let createdAt: Date
    let codexThreadID: String?
    let savedPrompt: String?
    let workspaceRoots: [String]
    let repositoryWorktrees: [RepositoryWorktreeRecord]
    let contextFolders: [String]

    init(task: BoardTask) {
        id = task.id
        title = task.title
        status = task.status.rawValue
        statusMessage = task.statusMessage
        progressType = task.progressTypeRawValue
        progressLabel = task.progressLabel
        progressDetail = task.progressDetail
        createdAt = task.createdAt
        codexThreadID = task.codexThreadID
        savedPrompt = task.savedPrompt
        workspaceRoots = task.workspaceRootPaths
        repositoryWorktrees = task.repositoryWorktrees
        contextFolders = task.contextFolderPaths
    }
}

enum GitHubPullRequestManager {
    struct PullRequest: Decodable, Sendable {
        let number: Int
        let url: String
        let baseRefName: String?
    }

    private struct PullRequestState: Decodable {
        let mergedAt: String?
    }

    static func resolveExecutable() throws -> String {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map {
            URL(fileURLWithPath: String($0)).appendingPathComponent("gh").path
        } + ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        guard let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw BridgeCommandError(code: "operation_failed", message: "GitHub CLI (gh) isn't available. Install GitHub CLI and try again.")
        }
        return path
    }

    static func findOpen(_ record: RepositoryWorktreeRecord, executable: String) throws -> PullRequest? {
        let result = try run(executable, ["pr", "list", "--head", record.branch, "--state", "open", "--json", "number,url,baseRefName", "--limit", "1"], directory: record.worktreePath)
        guard let pullRequest = try JSONDecoder().decode([PullRequest].self, from: Data(result.utf8)).first else {
            return nil
        }
        if let mergeTarget = configuredMergeTarget(for: record) {
            guard let baseRefName = pullRequest.baseRefName else {
                throw BridgeCommandError(
                    code: "operation_failed",
                    message: "GitHub couldn't confirm the base branch of the existing pull request for \(record.branch). Its configured merge target is \(mergeTarget)."
                )
            }
            guard baseRefName == mergeTarget else {
                throw BridgeCommandError(
                    code: "invalid_transition",
                    message: "An open pull request for \(record.branch) targets \(baseRefName), but this repository is configured to merge into \(mergeTarget). The existing pull request was left unchanged."
                )
            }
        }
        return pullRequest
    }

    static func create(_ record: RepositoryWorktreeRecord, title: String, body: String, executable: String) throws -> PullRequest {
        var arguments = ["pr", "create", "--title", title, "--body", body, "--head", record.branch]
        if let mergeTarget = configuredMergeTarget(for: record) {
            arguments += ["--base", mergeTarget]
        }
        let result = try run(executable, arguments, directory: record.worktreePath)
        guard let url = result.split(whereSeparator: \.isNewline).last.map(String.init),
              URL(string: url)?.host != nil,
              let number = URL(string: url)?.pathComponents.last.flatMap(Int.init) else {
            throw BridgeCommandError(code: "operation_failed", message: "GitHub CLI created a pull request but did not return its number and URL.")
        }
        return PullRequest(number: number, url: url, baseRefName: nil)
    }

    private static func configuredMergeTarget(for record: RepositoryWorktreeRecord) -> String? {
        guard let mergeTarget = record.mergeTarget?.trimmingCharacters(in: .whitespacesAndNewlines),
              !mergeTarget.isEmpty else {
            return nil
        }
        return mergeTarget
    }

    static func isMerged(_ record: RepositoryWorktreeRecord, executable: String) throws -> Bool {
        guard let number = record.pullRequestNumber else { return true }
        let result = try run(executable, ["pr", "view", String(number), "--json", "mergedAt"], directory: record.worktreePath)
        return try JSONDecoder().decode(PullRequestState.self, from: Data(result.utf8)).mergedAt != nil
    }

    private static func run(_ executable: String, _ arguments: [String], directory: String) throws -> String {
        let result: StationAIProcessResult
        do {
            result = try StationAIProcessRunner.run(
                executable: executable,
                arguments: arguments,
                directory: directory
            )
        } catch {
            throw BridgeCommandError(code: "operation_failed", message: "Couldn't start GitHub CLI: \(error.localizedDescription)")
        }
        let text = String(data: result.stdout, encoding: .utf8) ?? ""
        guard result.status == 0 else {
            let detail = String(data: result.stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let guidance = detail.localizedCaseInsensitiveContains("auth") || detail.localizedCaseInsensitiveContains("login")
                ? "GitHub CLI isn't authorized. Run `gh auth login` in Terminal, then try again. "
                : "GitHub CLI couldn't complete the request. "
            throw BridgeCommandError(code: "operation_failed", message: guidance + (detail.isEmpty ? "Exit status \(result.status)." : detail))
        }
        return text
    }
}

struct StationAIPullRequestService {

    func resolveExecutable() throws -> String {
        try GitHubPullRequestManager.resolveExecutable()
    }

    func findOpen(_ record: RepositoryWorktreeRecord, executable: String) async throws -> GitHubPullRequestManager.PullRequest? {
        try await StationAIBackgroundOperation.run {
            try GitHubPullRequestManager.findOpen(record, executable: executable)
        }
    }

    func create(
        _ record: RepositoryWorktreeRecord,
        title: String,
        body: String,
        executable: String
    ) async throws -> GitHubPullRequestManager.PullRequest {
        try await StationAIBackgroundOperation.run {
            try GitHubPullRequestManager.create(record, title: title, body: body, executable: executable)
        }
    }

    func isMerged(_ record: RepositoryWorktreeRecord, executable: String) async throws -> Bool {
        try await StationAIBackgroundOperation.run {
            try GitHubPullRequestManager.isMerged(record, executable: executable)
        }
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
    case invalidTransition(String)
    case unmergedPullRequests([Int])

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
        case .invalidTransition(let message):
            message
        case .unmergedPullRequests(let numbers):
            "Pull request(s) \(numbers.map { "#\($0)" }.joined(separator: ", ")) haven't been merged. Confirm that you want to mark this task Done."
        }
    }
}

@MainActor
final class BoardTaskManager {
    private let modelContext: ModelContext
    private let worktreeRoot: URL
    private let taskOperationLockDirectory: URL?
    private let repositoryAllocationLockDirectory: URL?
    private let conversationTurnLockDirectory: URL?
    private let worktreeService = StationAIWorktreeService()
    private let pullRequestService = StationAIPullRequestService()

    init(modelContext: ModelContext, worktreeRoot: URL = StationAIWorktreeManager.defaultRoot()) {
        self.modelContext = modelContext
        self.worktreeRoot = worktreeRoot
        self.taskOperationLockDirectory = modelContext.container.configurations.first?.url
            .deletingLastPathComponent()
            .appendingPathComponent("task-operation-locks", isDirectory: true)
        self.repositoryAllocationLockDirectory = modelContext.container.configurations.first?.url
            .deletingLastPathComponent()
            .appendingPathComponent("repository-allocation-locks", isDirectory: true)
        self.conversationTurnLockDirectory = modelContext.container.configurations.first?.url
            .deletingLastPathComponent()
            .appendingPathComponent("conversation-turn-locks", isDirectory: true)
    }

    private func withTaskOperationLock<T>(
        _ id: UUID,
        operation: @MainActor () async throws -> T
    ) async throws -> T {
        guard let taskOperationLockDirectory else {
            throw BridgeFileLockError(message: "Couldn't determine the task-store location for an operation lock.")
        }
        let lockURL = taskOperationLockDirectory.appendingPathComponent("\(id.uuidString).lock")
        return try await withExclusiveFileLocks(at: [lockURL], purpose: "task-operation") {
            try await operation()
        }
    }

    /// Reserves a task's whole conversation send across app/XPC processes.
    /// Workspace and repository changes, plus task deletion, use this same
    /// reservation so they cannot change a worktree while a turn is using it.
    /// This lock deliberately uses a separate file namespace from the short
    /// task-operation locks: streamed-turn callbacks must still acquire those
    /// locks to save lifecycle, progress, and thread state while this reservation
    /// remains held. Never hold a task-operation lock across the Codex turn.
    func withConversationTurnReservation<T>(
        _ id: UUID,
        operation: @MainActor () async throws -> T
    ) async throws -> T {
        guard let conversationTurnLockDirectory else {
            throw BridgeFileLockError(message: "Couldn't determine the task-store location for the conversation-turn reservation.")
        }
        let lockURL = conversationTurnLockDirectory.appendingPathComponent("\(id.uuidString).lock")
        return try await withExclusiveFileLocks(at: [lockURL], purpose: "conversation-turn") {
            try await operation()
        }
    }

    func hasConversationTurnReservation(_ id: UUID) throws -> Bool {
        guard let conversationTurnLockDirectory else {
            throw BridgeFileLockError(message: "Couldn't determine the task-store location for the conversation-turn reservation.")
        }
        let lockURL = conversationTurnLockDirectory
            .appendingPathComponent("\(id.uuidString).lock")
            .standardizedFileURL
        let key = lockURL.path
        guard !TaskOperationLockGate.isHeld(key) else { return true }

        let descriptor = Darwin.open(lockURL.path, O_RDWR | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return false }
            throw BridgeFileLockError(message: "Couldn't inspect the conversation-turn reservation (errno \(errno)).")
        }
        defer { _ = Darwin.close(descriptor) }

        var lock = flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        guard Darwin.fcntl(descriptor, F_GETLK, &lock) == 0 else {
            throw BridgeFileLockError(message: "Couldn't inspect the conversation-turn reservation (errno \(errno)).")
        }
        return lock.l_type != Int16(F_UNLCK)
    }

    private func withRepositoryAllocationLocks<T>(
        _ repositoryPaths: [String],
        operation: @MainActor () async throws -> T
    ) async throws -> T {
        guard !repositoryPaths.isEmpty else { return try await operation() }
        guard let repositoryAllocationLockDirectory else {
            throw BridgeFileLockError(message: "Couldn't determine the task-store location for repository allocation locks.")
        }
        let lockURLs = Set(repositoryPaths.map { repositoryPath in
            repositoryAllocationLockDirectory.appendingPathComponent(
                RepositoryAllocationLock.fileName(for: repositoryPath)
            )
        }).sorted { $0.path < $1.path }
        return try await withExclusiveFileLocks(at: lockURLs, purpose: "repository-allocation") {
            try await operation()
        }
    }

    private func withExclusiveFileLocks<T>(
        at lockURLs: [URL],
        purpose: String,
        operation: @MainActor () async throws -> T
    ) async throws -> T {
        let orderedURLs = Array(Set(lockURLs.map { $0.standardizedFileURL }))
            .sorted { $0.path < $1.path }
        var acquiredKeys: [String] = []
        var descriptors: [Int32] = []

        do {
            for lockURL in orderedURLs {
                let key = lockURL.path
                await TaskOperationLockGate.acquire(key)
                do {
                    let descriptor = try await Task.detached(priority: .utility) {
                        do {
                            try FileManager.default.createDirectory(
                                at: lockURL.deletingLastPathComponent(),
                                withIntermediateDirectories: true
                            )
                        } catch {
                            throw BridgeFileLockError(message: "Couldn't create the \(purpose) lock directory: \(error.localizedDescription)")
                        }
                        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
                        guard descriptor >= 0 else {
                            throw BridgeFileLockError(message: "Couldn't open the \(purpose) lock (errno \(errno)).")
                        }
                        var lock = flock()
                        lock.l_type = Int16(F_WRLCK)
                        lock.l_whence = Int16(SEEK_SET)
                        while Darwin.fcntl(descriptor, F_SETLK, &lock) != 0 {
                            if errno == EACCES || errno == EAGAIN {
                                usleep(50_000)
                                continue
                            }
                            let code = errno
                            _ = Darwin.close(descriptor)
                            throw BridgeFileLockError(message: "Couldn't acquire the \(purpose) lock (errno \(code)).")
                        }
                        return descriptor
                    }.value
                    acquiredKeys.append(key)
                    descriptors.append(descriptor)
                } catch {
                    TaskOperationLockGate.release(key)
                    throw error
                }
            }
        } catch {
            for descriptor in descriptors.reversed() { _ = Darwin.close(descriptor) }
            for key in acquiredKeys.reversed() { TaskOperationLockGate.release(key) }
            throw error
        }

        defer {
            for descriptor in descriptors.reversed() { _ = Darwin.close(descriptor) }
            for key in acquiredKeys.reversed() { TaskOperationLockGate.release(key) }
        }
        return try await operation()
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
    func create(title: String, repositories: [RepositoryWorktreeSpec], contextFolders: [String]) async throws -> BoardTaskRecord {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else { throw StationAIManagerError.invalidTitle }
        let folders = try Self.normalizeOptionalRoots(contextFolders)
        var worktrees: [RepositoryWorktreeRecord] = []
        for spec in repositories {
            worktrees.append(try await worktreeService.pendingRecord(spec: spec))
        }
        let duplicate = worktrees.first { record in
            worktrees.filter { $0.repositoryPath == record.repositoryPath }.count > 1
        }
        if let duplicate {
            throw BridgeCommandError(code: "invalid_argument", message: "A repository can be selected only once per task: \(duplicate.repositoryPath)")
        }
        let roots = try Self.normalizeOptionalRoots(worktrees.map(\.repositoryPath) + folders)
        let task = BoardTask(title: normalizedTitle, status: .backlog, workspaceRootPaths: roots)
        task.repositoryWorktrees = worktrees
        task.contextFolderPaths = folders
        return try await withRepositoryAllocationLocks(worktrees.map(\.repositoryPath)) {
            try validateRepositoryAssignments(worktrees, excludingTaskID: nil)
            modelContext.insert(task)
            try modelContext.save()
            return BoardTaskRecord(task: task)
        }
    }

    @discardableResult
    func addRepository(_ id: UUID, repositoryPath: String) async throws -> BoardTaskRecord {
        return try await addRepositories(id, repositoryPaths: [repositoryPath])
    }

    @discardableResult
    func addRepositories(_ id: UUID, repositoryPaths: [String]) async throws -> BoardTaskRecord {
        guard !repositoryPaths.isEmpty else {
            throw BridgeCommandError(code: "invalid_argument", message: "Add at least one repository.")
        }

        let initialTask = try requireTask(id)
        guard initialTask.status != .done else {
            throw BridgeCommandError(code: "invalid_transition", message: "Repositories can't be changed on a completed task.")
        }

        var records: [RepositoryWorktreeRecord] = []
        records.reserveCapacity(repositoryPaths.count)
        for path in repositoryPaths {
            records.append(try await worktreeService.pendingRecord(
                spec: RepositoryWorktreeSpec(repositoryPath: path, branch: nil, branchFrom: nil)
            ))
        }

        var seenRepositories = Set<String>()
        for record in records {
            let repository = Self.canonicalPath(record.repositoryPath)
            guard seenRepositories.insert(repository).inserted else {
                throw BridgeCommandError(
                    code: "invalid_argument",
                    message: "A repository can be selected only once per task: \(record.repositoryPath)"
                )
            }
        }

        let attachedRepositories = Set(initialTask.repositoryWorktrees.map { Self.canonicalPath($0.repositoryPath) })
        if let duplicate = records.first(where: { attachedRepositories.contains(Self.canonicalPath($0.repositoryPath)) }) {
            throw BridgeCommandError(
                code: "invalid_argument",
                message: "This repository is already attached to the task: \(duplicate.repositoryPath)"
            )
        }

        return try await withConversationTurnReservation(id) {
            return try await withTaskOperationLock(id) {
                return try await withRepositoryAllocationLocks(records.map(\.repositoryPath)) {
                    let task = try requireTask(id)
                    guard task.status != .done else {
                        throw BridgeCommandError(code: "invalid_transition", message: "Repositories can't be changed on a completed task.")
                    }

                    let currentRepositories = Set(task.repositoryWorktrees.map { Self.canonicalPath($0.repositoryPath) })
                    if let duplicate = records.first(where: { currentRepositories.contains(Self.canonicalPath($0.repositoryPath)) }) {
                        throw BridgeCommandError(
                            code: "invalid_argument",
                            message: "This repository is already attached to the task: \(duplicate.repositoryPath)"
                        )
                    }
                    try validateRepositoryAssignments(records, excludingTaskID: id)

                    let repositories = task.repositoryWorktrees + records
                    let contextFolders = try Self.normalizeOptionalRoots(
                        task.contextFolderPaths.filter {
                            !seenRepositories.contains(Self.canonicalPath($0))
                        }
                    )
                    let roots = try Self.normalizeOptionalRoots(repositories.map { $0.isPending ? $0.repositoryPath : $0.worktreePath } + contextFolders)
                    task.repositoryWorktrees = repositories
                    task.contextFolderPaths = contextFolders
                    task.workspaceRootPaths = roots
                    try modelContext.save()
                    return BoardTaskRecord(task: task)
                }
            }
        }
    }

    @discardableResult
    func updateRepository(
        _ id: UUID,
        repositoryPath: String,
        branch: String,
        branchFrom: String,
        mergeTarget: String?
    ) async throws -> BoardTaskRecord {
        let initialTask = try requireTask(id)
        guard initialTask.status != .done else {
            throw BridgeCommandError(code: "invalid_transition", message: "Repositories can't be changed on a completed task.")
        }
        guard !branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !branchFrom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BridgeCommandError(code: "invalid_argument", message: "Branch and merge-from values can't be empty.")
        }
        let initialRecord = try repositoryRecord(repositoryPath, in: initialTask)
        guard initialRecord.isPending else {
            throw BridgeCommandError(code: "invalid_transition", message: "Repository settings are locked after the task starts.")
        }
        let validated = try await worktreeService.pendingRecord(
            spec: RepositoryWorktreeSpec(
                repositoryPath: initialRecord.repositoryPath,
                branch: branch,
                branchFrom: branchFrom,
                mergeTarget: mergeTarget
            )
        )

        return try await withConversationTurnReservation(id) {
            try await withTaskOperationLock(id) {
                try await withRepositoryAllocationLocks([validated.repositoryPath]) {
                    let task = try requireTask(id)
                    guard task.status != .done,
                          let index = task.repositoryWorktrees.firstIndex(where: { $0.repositoryPath == initialRecord.repositoryPath }),
                          task.repositoryWorktrees[index] == initialRecord else {
                        throw BridgeCommandError(code: "invalid_transition", message: "Repository settings changed while they were being validated. Try again.")
                    }
                    try validateRepositoryAssignments([validated], excludingTaskID: id)
                    var repositories = task.repositoryWorktrees
                    repositories[index] = validated
                    task.repositoryWorktrees = repositories
                    try modelContext.save()
                    return BoardTaskRecord(task: task)
                }
            }
        }
    }

    @discardableResult
    func removeRepository(_ id: UUID, repositoryPath: String) async throws -> BoardTaskRecord {
        return try await withConversationTurnReservation(id) {
            try await self.removeRepositoryWhileTurnReserved(id, repositoryPath: repositoryPath)
        }
    }

    private func removeRepositoryWhileTurnReserved(
        _ id: UUID,
        repositoryPath: String
    ) async throws -> BoardTaskRecord {
        return try await withTaskOperationLock(id) {
            let task = try requireTask(id)
            guard task.status != .done else {
                throw BridgeCommandError(code: "invalid_transition", message: "Repositories can't be changed on a completed task.")
            }
            let record = try repositoryRecord(repositoryPath, in: task)
            let originalRepositories = task.repositoryWorktrees
            let originalRoots = task.workspaceRootPaths
            let updatedRepositories = originalRepositories.filter { $0.repositoryPath != record.repositoryPath }
            let roots = try Self.normalizeOptionalRoots(updatedRepositories.map(\.worktreePath) + task.contextFolderPaths)
            guard !roots.isEmpty else { throw StationAIManagerError.noWorkspaceRoots }

            let shouldRemoveWorktree = record.createdByStationAI && !record.isPending
                && FileManager.default.fileExists(atPath: record.worktreePath)

            return try await withRepositoryAllocationLocks([record.repositoryPath]) {
                let currentTask = try requireTask(id)
                guard currentTask.status != .done,
                      currentTask.repositoryWorktrees == originalRepositories,
                      currentTask.workspaceRootPaths == originalRoots else {
                    throw BridgeCommandError(code: "invalid_transition", message: "The task changed while its repository was being checked. Try again.")
                }
                if shouldRemoveWorktree, try await worktreeService.hasChanges(record) {
                    throw BridgeCommandError(
                        code: "operation_failed",
                        message: "Can't remove this repository because its worktree has uncommitted changes: \(record.worktreePath)"
                    )
                }

                currentTask.repositoryWorktrees = updatedRepositories
                currentTask.workspaceRootPaths = roots
                try modelContext.save()

                if shouldRemoveWorktree {
                    do {
                        try await worktreeService.remove(record)
                    } catch {
                        let removalError = error
                        guard let current = try? requireTask(id),
                              current.repositoryWorktrees == updatedRepositories,
                              current.workspaceRootPaths == roots else {
                            throw removalError
                        }
                        current.repositoryWorktrees = originalRepositories
                        current.workspaceRootPaths = originalRoots
                        do {
                            try modelContext.save()
                        } catch {
                            throw BridgeCommandError(
                                code: "operation_failed",
                                message: "Couldn't remove the repository worktree (\(removalError.localizedDescription)) or restore its task record (\(error.localizedDescription))."
                            )
                        }
                        throw removalError
                    }
                }
                return try get(id)
            }
        }
    }

    @discardableResult
    func move(
        _ id: UUID,
        to statusName: String,
        allowUnmergedPullRequests: Bool = false
    ) async throws -> BoardTaskRecord {
        guard let status = TaskStatus(rawValue: statusName) else {
            throw StationAIManagerError.invalidStatus(statusName)
        }
        guard status == .done else {
            throw StationAIManagerError.invalidTransition("Task status is controlled by Codex. Start or continue a conversation to update it.")
        }
        return try await withTaskOperationLock(id) {
            let initialTask = try requireTask(id)
            guard initialTask.status != .done else { return BoardTaskRecord(task: initialTask) }
            guard initialTask.status == .review else {
                throw StationAIManagerError.invalidTransition("Only a task in Review can move to Done.")
            }

            let originalRepositories = initialTask.repositoryWorktrees
            let linkedRecords = originalRepositories.filter { $0.pullRequestNumber != nil }
            if !linkedRecords.isEmpty && !allowUnmergedPullRequests {
                let executable = try pullRequestService.resolveExecutable()
                var unmerged: [RepositoryWorktreeRecord] = []
                for record in linkedRecords {
                    let isMerged = try await pullRequestService.isMerged(record, executable: executable)
                    if !isMerged { unmerged.append(record) }
                }
                if !unmerged.isEmpty {
                    throw StationAIManagerError.unmergedPullRequests(unmerged.compactMap(\.pullRequestNumber))
                }
            }
            let task = try requireTask(id)
            guard task.status == .review else {
                throw StationAIManagerError.invalidTransition("Only a task in Review can move to Done.")
            }
            guard task.repositoryWorktrees == originalRepositories else {
                throw BridgeCommandError(code: "invalid_transition", message: "The task's pull request links changed while they were being checked. Try again.")
            }
            task.status = .done
            task.statusMessage = nil
            clearProgressReport(task)
            try modelContext.save()
            return BoardTaskRecord(task: task)
        }
    }

    func createPullRequests(_ id: UUID, client: CodexAppServerClient) async throws -> BoardTaskRecord {
        let lookup = try await withTaskOperationLock(id) {
            let initialTask = try requireTask(id)
            let originalRecords = initialTask.repositoryWorktrees
            guard !originalRecords.isEmpty else {
                throw BridgeCommandError(code: "invalid_transition", message: "This task has no repository for a pull request.")
            }
            let gh = try pullRequestService.resolveExecutable()
            guard !originalRecords.contains(where: \.isPending) else {
                throw BridgeCommandError(code: "invalid_transition", message: "Start the task conversation before creating a pull request so its repository worktree is ready.")
            }
            var records = originalRecords
            for index in records.indices where records[index].pullRequestNumber == nil || records[index].pullRequestURL == nil {
                do {
                    // `--head` skips gh's push flow, and `gh pr list` also needs a
                    // published branch. Commit and publish before either GH request.
                    try await worktreeService.commitChanges(records[index], message: "Complete task: \(initialTask.title)")
                    try await worktreeService.publishBranch(records[index])
                } catch {
                    throw BridgeCommandError(code: "operation_failed", message: "GitHub CLI couldn't publish the task branch. \(error.localizedDescription)")
                }
                if let existing = try await pullRequestService.findOpen(records[index], executable: gh) {
                    records[index].pullRequestNumber = existing.number
                    records[index].pullRequestURL = existing.url
                }
            }
            let taskAfterLookup = try requireTask(id)
            guard taskAfterLookup.repositoryWorktrees == originalRecords else {
                throw BridgeCommandError(code: "invalid_transition", message: "The task repositories changed while pull requests were being checked. Try again.")
            }
            taskAfterLookup.repositoryWorktrees = records
            try modelContext.save()
            return (gh, records, BoardTaskRecord(task: taskAfterLookup))
        }
        let (gh, records, lookedUpRecords) = lookup
        guard records.contains(where: { $0.pullRequestNumber == nil || $0.pullRequestURL == nil }) else {
            return lookedUpRecords
        }

        let conversation = try await CodexConversationManager(tasks: self, client: client).history(taskID: id)
        let conversationText = conversation.messages.map { "\($0.role.rawValue): \($0.text)" }.joined(separator: "\n\n")
        let currentTitle = try requireTask(id).title
        let summary: String
        if !conversationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let roots = records.map { URL(fileURLWithPath: $0.worktreePath, isDirectory: true) }
            let workspace = try CodexWorkspaceContext(roots: roots)
            let summaryThread = try await client.startThread(workspace: workspace, modelID: CodexAppServerClient.modelID)
            var generated = ""
            try await client.sendMessage(
                "Write a very concise GitHub pull request description. Explain what problem this change solves, how it solves it, and briefly mention any special issue or caveat from the conversation. Use Markdown, no more than three short sections, and return only the description.\n\nTask: \(currentTitle)\n\nConversation:\n\(conversationText)",
                mode: .plan,
                modelID: CodexAppServerClient.modelID,
                threadID: summaryThread,
                workspace: workspace,
                onDelta: { _ in },
                onFinalMessage: { generated = $0.trimmingCharacters(in: .whitespacesAndNewlines) },
                onActivity: { _ in }, onDiff: { _ in }, onHistory: { _ in },
                onActionRequest: {}, onUserInput: { _ in }
            )
            guard !generated.isEmpty else {
                throw BridgeCommandError(code: "operation_failed", message: "Codex returned an empty pull request summary. Try again.")
            }
            summary = generated
        } else {
            summary = "Implements: \(currentTitle)."
        }

        let taskBeforeCreation = try requireTask(id)
        guard taskBeforeCreation.repositoryWorktrees == records,
              taskBeforeCreation.title == currentTitle else {
            throw BridgeCommandError(code: "invalid_transition", message: "The task changed while its pull request summary was being prepared. Try again.")
        }
        return try await withTaskOperationLock(id) {
            let taskAtCreation = try requireTask(id)
            guard taskAtCreation.repositoryWorktrees == records,
                  taskAtCreation.title == currentTitle else {
                throw BridgeCommandError(code: "invalid_transition", message: "The task changed while its pull request summary was being prepared. Try again.")
            }
            var updatedRecords = records
            var expectedRecords = records
            for index in updatedRecords.indices where updatedRecords[index].pullRequestNumber == nil || updatedRecords[index].pullRequestURL == nil {
                let record = updatedRecords[index]
                let pullRequest: GitHubPullRequestManager.PullRequest
                if let existing = try await pullRequestService.findOpen(record, executable: gh) {
                    pullRequest = existing
                } else {
                    do {
                        try await worktreeService.commitChanges(record, message: "Complete task: \(currentTitle)")
                        try await worktreeService.publishBranch(record)
                    } catch {
                        throw BridgeCommandError(code: "operation_failed", message: "GitHub CLI couldn't publish the task branch. \(error.localizedDescription)")
                    }
                    pullRequest = try await pullRequestService.create(record, title: currentTitle, body: summary, executable: gh)
                }
                updatedRecords[index].pullRequestNumber = pullRequest.number
                updatedRecords[index].pullRequestURL = pullRequest.url
                let currentTask = try requireTask(id)
                guard currentTask.repositoryWorktrees == expectedRecords else {
                    throw BridgeCommandError(code: "invalid_transition", message: "The task repositories changed while the pull request was being created.")
                }
                currentTask.repositoryWorktrees = updatedRecords
                try modelContext.save()
                expectedRecords = updatedRecords
            }
            return try get(id)
        }
    }

    func setLifecycleStatus(_ id: UUID, to status: TaskStatus, message: String? = nil) async throws -> BoardTaskRecord {
        try await withTaskOperationLock(id) {
            let task = try requireTask(id)
            guard task.status != .done else { return BoardTaskRecord(task: task) }
            task.status = status
            task.statusMessage = message
            if status != .inProgress { clearProgressReport(task) }
            try modelContext.save()
            return BoardTaskRecord(task: task)
        }
    }

    @discardableResult
    func publishProgressReport(_ id: UUID, type: TaskProgressType?, customLabel: String? = nil, detail: String? = nil) async throws -> BoardTaskRecord {
        let label = type?.label ?? customLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !label.isEmpty, label.count <= 60 else {
            throw BridgeCommandError(code: "invalid_argument", message: "Progress labels must contain 1 to 60 characters.")
        }
        let normalizedDetail = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (normalizedDetail?.count ?? 0) <= 200 else {
            throw BridgeCommandError(code: "invalid_argument", message: "Progress details must be 200 characters or fewer.")
        }
        return try await withTaskOperationLock(id) {
            let task = try requireTask(id)
            guard task.status == .inProgress else {
                throw BridgeCommandError(code: "invalid_transition", message: "Progress reports can only be published while a task is In Progress.")
            }
            task.progressTypeRawValue = type?.rawValue
            task.progressLabel = label
            task.progressDetail = normalizedDetail?.isEmpty == true ? nil : normalizedDetail
            try modelContext.save()
            return BoardTaskRecord(task: task)
        }
    }

    @discardableResult
    func clearProgressReport(_ id: UUID) async throws -> BoardTaskRecord {
        try await withTaskOperationLock(id) {
            let task = try requireTask(id)
            clearProgressReport(task)
            try modelContext.save()
            return BoardTaskRecord(task: task)
        }
    }

    private func clearProgressReport(_ task: BoardTask) {
        task.progressTypeRawValue = nil
        task.progressLabel = nil
        task.progressDetail = nil
    }

    func reconcileLifecycleStatusOnOpen(_ id: UUID, client: CodexAppServerClient) async throws -> BoardTaskRecord {
        try await withTaskOperationLock(id) {
            let task = try requireTask(id)
            guard let threadID = task.codexThreadID else {
                return BoardTaskRecord(task: task)
            }
            let hasActiveReservation = try hasConversationTurnReservation(id)
            guard !client.isTurnActive(threadID: threadID),
                  !CodexAppServerClient.isTurnActiveInProcess(threadID: threadID),
                  !hasActiveReservation else {
                return BoardTaskRecord(task: task)
            }
            let message: String
            switch task.status {
            case .inProgress:
                message = "StationAI reopened before Codex reported that this turn finished. Review the conversation and send a prompt to retry."
            case .waitingResponse:
                message = "StationAI reopened before the pending question was answered. Review the conversation and send a prompt to continue."
            default:
                return BoardTaskRecord(task: task)
            }
            task.status = .blocked
            task.statusMessage = message
            clearProgressReport(task)
            try modelContext.save()
            return BoardTaskRecord(task: task)
        }
    }

    func resetAllTasksForLifecycle() async throws -> [String] {
        let all = try listModels()
        var dirtyManagedWorktrees: [String] = []
        for snapshot in all {
            let dirtyForTask = try await withTaskOperationLock(snapshot.id) { () async throws -> [String] in
                let task: BoardTask
                do {
                    task = try requireTask(snapshot.id)
                } catch let error as StationAIManagerError {
                    if case .taskNotFound = error { return [] }
                    throw error
                }
                var dirtyPaths: [String] = []
                for record in task.repositoryWorktrees where record.createdByStationAI {
                    guard FileManager.default.fileExists(atPath: record.worktreePath) else { continue }
                    if (try? await worktreeService.hasChanges(record)) != false {
                        dirtyPaths.append(record.worktreePath)
                    } else {
                        try await worktreeService.remove(record)
                    }
                }
                modelContext.delete(task)
                try modelContext.save()
                return dirtyPaths
            }
            dirtyManagedWorktrees.append(contentsOf: dirtyForTask)
        }
        return dirtyManagedWorktrees
    }

    @discardableResult
    func rename(_ id: UUID, title: String) async throws -> BoardTaskRecord {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else { throw StationAIManagerError.invalidTitle }
        return try await withTaskOperationLock(id) {
            let task = try requireTask(id)
            task.title = normalizedTitle
            try modelContext.save()
            return BoardTaskRecord(task: task)
        }
    }

    @discardableResult
    func renameIfTitleMatches(_ id: UUID, expectedTitle: String, title: String) async throws -> BoardTaskRecord? {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else { throw StationAIManagerError.invalidTitle }
        return try await withTaskOperationLock(id) {
            let task = try requireTask(id)
            guard task.title == expectedTitle else { return nil }
            let previousTitle = task.title
            task.title = normalizedTitle
            do {
                try modelContext.save()
            } catch {
                task.title = previousTitle
                throw error
            }
            return BoardTaskRecord(task: task)
        }
    }

    @discardableResult
    func savePrompt(_ id: UUID, prompt: String, status: TaskStatus? = nil) async throws -> BoardTaskRecord {
        if let status, status != .backlog && status != .inProgress {
            throw StationAIManagerError.invalidTransition("Saving a task prompt can only place it in Backlog or Progress.")
        }
        return try await withTaskOperationLock(id) {
            let task = try requireTask(id)
            task.savedPrompt = prompt
            if let status {
                task.status = status
                if status != .inProgress { clearProgressReport(task) }
            }
            try modelContext.save()
            return BoardTaskRecord(task: task)
        }
    }

    func persistCodexThreadID(_ id: UUID, threadID: String) async throws -> BoardTaskRecord {
        guard !threadID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BridgeCommandError(code: "invalid_argument", message: "Codex returned an empty thread ID.")
        }
        return try await withTaskOperationLock(id) {
            let task = try requireTask(id)
            guard task.codexThreadID == nil || task.codexThreadID == threadID else {
                throw BridgeCommandError(code: "invalid_transition", message: "The task is already linked to a different Codex conversation.")
            }
            guard task.codexThreadID != threadID else { return BoardTaskRecord(task: task) }
            task.codexThreadID = threadID
            do {
                try modelContext.save()
            } catch {
                task.codexThreadID = nil
                throw error
            }
            return BoardTaskRecord(task: task)
        }
    }

    @discardableResult
    func setWorkspaceRoots(_ id: UUID, roots: [String]) async throws -> BoardTaskRecord {
        let initialTask = try requireTask(id)
        let initialRepositories = initialTask.repositoryWorktrees
        let initialWorkspaceRoots = initialTask.workspaceRootPaths
        let initialContextFolders = initialTask.contextFolderPaths
        if initialRepositories.isEmpty {
            let normalizedRoots = try Self.normalizeRoots(roots)
            return try await withConversationTurnReservation(id) {
                try await withTaskOperationLock(id) {
                    let task = try requireTask(id)
                    guard task.repositoryWorktrees == initialRepositories,
                          task.workspaceRootPaths == initialWorkspaceRoots,
                          task.contextFolderPaths == initialContextFolders else {
                        throw BridgeCommandError(code: "invalid_transition", message: "The task workspaces changed while folders were being validated. Try again.")
                    }
                    task.workspaceRootPaths = normalizedRoots
                    task.contextFolderPaths = normalizedRoots
                    try modelContext.save()
                    return BoardTaskRecord(task: task)
                }
            }
        } else {
            let paths = try Self.normalizeOptionalRoots(roots)
            let existingPaths = Set(initialRepositories.map { URL(fileURLWithPath: $0.worktreePath).standardizedFileURL.path })
            let retained = initialRepositories.filter { existingPaths.contains(URL(fileURLWithPath: $0.worktreePath).standardizedFileURL.path) && paths.contains(URL(fileURLWithPath: $0.worktreePath).standardizedFileURL.path) }
            var worktrees = retained
            var folders: [String] = []
            for path in paths where !existingPaths.contains(path) {
                if FileManager.default.fileExists(atPath: URL(fileURLWithPath: path).appendingPathComponent(".git").path) {
                    let record = try await worktreeService.pendingRecord(
                        spec: RepositoryWorktreeSpec(repositoryPath: path, branch: nil, branchFrom: nil)
                    )
                    worktrees.append(record)
                } else {
                    folders.append(path)
                }
            }
            return try await withConversationTurnReservation(id) {
                try await withTaskOperationLock(id) {
                    try await withRepositoryAllocationLocks(worktrees.map(\.repositoryPath)) {
                        let task = try requireTask(id)
                        guard task.repositoryWorktrees == initialRepositories,
                              task.workspaceRootPaths == initialWorkspaceRoots,
                              task.contextFolderPaths == initialContextFolders else {
                            throw BridgeCommandError(code: "invalid_transition", message: "The task workspaces changed while folders were being validated. Try again.")
                        }
                        try validateRepositoryAssignments(worktrees, excludingTaskID: id)
                        task.repositoryWorktrees = worktrees
                        task.contextFolderPaths = folders
                        let resolvedRoots = try Self.normalizeOptionalRoots(worktrees.map(\.worktreePath) + folders)
                        guard !resolvedRoots.isEmpty else { throw StationAIManagerError.noWorkspaceRoots }
                        task.workspaceRootPaths = resolvedRoots
                        try modelContext.save()
                        return BoardTaskRecord(task: task)
                    }
                }
            }
        }
    }

    func delete(_ id: UUID, diagnostics: [String: String] = [:]) async throws {
        try await withConversationTurnReservation(id) {
            try await self.deleteWhileTurnReserved(id, diagnostics: diagnostics)
        }
    }

    private func deleteWhileTurnReserved(_ id: UUID, diagnostics: [String: String]) async throws {
        try await withTaskOperationLock(id) {
            let task = try requireTask(id)
            try await withRepositoryAllocationLocks(task.repositoryWorktrees.map(\.repositoryPath)) {
                try await deleteTaskWhileLocked(task, diagnostics: diagnostics)
            }
        }
    }

    private func deleteTaskWhileLocked(_ task: BoardTask, diagnostics: [String: String]) async throws {
        var phase = "worktree-removal"
        var fields = [
            "taskID": task.id.uuidString,
            "taskStatus": task.status.rawValue,
            "threadID": task.codexThreadID ?? "",
            "worktreeCount": String(task.repositoryWorktrees.count),
            "storePath": StationAIDiagnostics.storeURL.path
        ]
        fields.merge(diagnostics) { _, new in new }
        StationAIDiagnostics.record("task.delete.started", fields: fields)
        do {
            for worktree in task.repositoryWorktrees {
                guard !worktree.isPending else { continue }
                fields["worktreePath"] = worktree.worktreePath
                StationAIDiagnostics.record("task.delete.worktree_removal_started", fields: fields)
                try await worktreeService.removeAfterConfirmation(worktree)
                StationAIDiagnostics.record("task.delete.worktree_removal_succeeded", fields: fields)
            }
            phase = "swiftdata-save"
            modelContext.delete(task)
            try modelContext.save()
            StationAIDiagnostics.record("task.delete.succeeded", fields: fields)
        } catch {
            fields["phase"] = phase
            fields.merge(
                StationAIDiagnostics.errorFields(error, redacting: [task.title, task.savedPrompt ?? ""])
            ) { _, new in new }
            StationAIDiagnostics.record("task.delete.failed", fields: fields)
            throw error
        }
    }

    func taskModel(_ id: UUID) throws -> BoardTask {
        try requireTask(id)
    }

    func prepareRepositoryWorktrees(_ id: UUID, fallbackPrompt: String? = nil) async throws -> BoardTask {
        let initialTask = try requireTask(id)
        let initialRecords = initialTask.repositoryWorktrees
        let pending = initialRecords.filter(\.isPending)
        guard !pending.isEmpty else { return initialTask }
        let branchTitle: String
        if ["Generating title…", "Untitled task"].contains(initialTask.title) {
            let prompt = initialTask.savedPrompt ?? fallbackPrompt ?? initialTask.title
            branchTitle = prompt.split(whereSeparator: \.isWhitespace).prefix(8).joined(separator: " ")
        } else {
            branchTitle = initialTask.title
        }
        return try await withTaskOperationLock(id) {
            let task = try requireTask(id)
            guard task.repositoryWorktrees == initialRecords else {
                throw BridgeCommandError(code: "invalid_transition", message: "The task repositories changed while worktrees were being prepared. Try again.")
            }
            return try await withRepositoryAllocationLocks(pending.map(\.repositoryPath)) {
                var resolved: [RepositoryWorktreeRecord] = []
                do {
                    try validateRepositoryAssignments(pending, excludingTaskID: id)
                    for item in pending {
                        let requestedBranch = item.branch == "auto" ? nil : item.branch
                        let record = try await worktreeService.resolve(
                            spec: RepositoryWorktreeSpec(
                                repositoryPath: item.repositoryPath,
                                branch: requestedBranch,
                                branchFrom: item.branchFrom,
                                mergeTarget: item.mergeTarget
                            ),
                            title: branchTitle,
                            root: worktreeRoot
                        )
                        resolved.append(record)
                    }
                    let currentTask = try requireTask(id)
                    guard currentTask.repositoryWorktrees == initialRecords else {
                        throw BridgeCommandError(code: "invalid_transition", message: "The task repositories changed while worktrees were being prepared. Try again.")
                    }
                    try validateRepositoryAssignments(resolved, excludingTaskID: id)
                    var iterator = resolved.makeIterator()
                    currentTask.repositoryWorktrees = currentTask.repositoryWorktrees.map { $0.isPending ? (iterator.next() ?? $0) : $0 }
                    currentTask.workspaceRootPaths = try Self.normalizeOptionalRoots(currentTask.repositoryWorktrees.map(\.worktreePath) + currentTask.contextFolderPaths)
                    try modelContext.save()
                    return currentTask
                } catch {
                    for record in resolved where record.createdByStationAI {
                        try? await worktreeService.remove(record)
                    }
                    throw error
                }
            }
        }
    }

    func deleteRequiresConfirmation(_ id: UUID) async throws -> Bool {
        let task = try requireTask(id)
        var dirtyWorktree = false
        for record in task.repositoryWorktrees where !record.isPending {
            if try await worktreeService.hasChanges(record) {
                dirtyWorktree = true
                break
            }
        }
        if dirtyWorktree { return true }
        let hasSavedConversation = task.codexThreadID != nil
            || !(task.savedPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        return dirtyWorktree || hasSavedConversation
    }

    private func requireTask(_ id: UUID) throws -> BoardTask {
        var descriptor = FetchDescriptor<BoardTask>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let task = try modelContext.fetch(descriptor).first else {
            throw StationAIManagerError.taskNotFound(id)
        }
        return task
    }

    private func validateRepositoryAssignments(
        _ candidates: [RepositoryWorktreeRecord],
        excludingTaskID: UUID?
    ) throws {
        for other in try listModels() where other.id != excludingTaskID && other.status != .done {
            for candidate in candidates {
                let repositoryPath = Self.canonicalPath(candidate.repositoryPath)
                if candidate.branch != "auto",
                   other.repositoryWorktrees.contains(where: {
                       Self.canonicalPath($0.repositoryPath) == repositoryPath && $0.branch == candidate.branch
                   }) {
                    throw StationAIManagerError.repositoryAssigned(candidate.repositoryPath)
                }

                let candidateWorkspacePath = Self.canonicalPath(
                    candidate.isPending ? candidate.repositoryPath : candidate.worktreePath
                )
                if other.repositoryWorktrees.contains(where: {
                    !$0.isPending && Self.canonicalPath($0.worktreePath) == candidateWorkspacePath
                }) {
                    throw StationAIManagerError.repositoryAssigned(candidateWorkspacePath)
                }
            }
        }
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func repositoryRecord(_ path: String, in task: BoardTask) throws -> RepositoryWorktreeRecord {
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        guard let record = task.repositoryWorktrees.first(where: {
            URL(fileURLWithPath: $0.repositoryPath).standardizedFileURL.path == normalizedPath
        }) else {
            throw BridgeCommandError(code: "not_found", message: "This repository isn't attached to the task: \(normalizedPath)")
        }
        return record
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

    var lastSelectedRepositories: [String] {
        defaults.stringArray(forKey: WorkspaceSettings.lastSelectedRepositoriesKey) ?? []
    }

    var appearance: String {
        let value = defaults.string(forKey: WorkspaceSettings.appearanceKey) ?? "dark"
        return value == "light" ? "light" : "dark"
    }

    func setAppearance(_ value: String) throws {
        guard value == "dark" || value == "light" else {
            throw BridgeCommandError(code: "invalid_argument", message: "Appearance must be 'dark' or 'light'.")
        }
        defaults.set(value, forKey: WorkspaceSettings.appearanceKey)
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

    func setLastSelectedRepositories(_ paths: [String]) throws {
        var normalized: [String] = []
        for path in paths {
            let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) else {
                throw StationAIManagerError.unavailableWorkspaceRoot(path)
            }
            if !normalized.contains(url.path) { normalized.append(url.path) }
        }
        defaults.set(normalized, forKey: WorkspaceSettings.lastSelectedRepositoriesKey)
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
    func setRoots(_ roots: [String], for taskID: UUID) async throws -> BoardTaskRecord {
        guard let taskManager else { throw BridgeCommandError(code: "internal_error", message: "Task manager is unavailable.") }
        return try await taskManager.setWorkspaceRoots(taskID, roots: roots)
    }

    @discardableResult
    func addRepository(_ repositoryPath: String, to taskID: UUID) async throws -> BoardTaskRecord {
        guard let taskManager else { throw BridgeCommandError(code: "internal_error", message: "Task manager is unavailable.") }
        return try await taskManager.addRepository(taskID, repositoryPath: repositoryPath)
    }

    @discardableResult
    func addRepositories(_ repositoryPaths: [String], to taskID: UUID) async throws -> BoardTaskRecord {
        guard let taskManager else { throw BridgeCommandError(code: "internal_error", message: "Task manager is unavailable.") }
        return try await taskManager.addRepositories(taskID, repositoryPaths: repositoryPaths)
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
    var userInputRequest: CodexUserInputRequest?
    var taskStatus: String?
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
        let historyRoots = task.workspaceRootPaths.isEmpty && task.status == .done
            ? task.repositoryWorktrees.map { $0.repositoryPath }
            : task.workspaceRootPaths
        let workspace = try CodexWorkspaceContext(roots: historyRoots.map {
            URL(fileURLWithPath: $0, isDirectory: true)
        })
        StationAIDiagnostics.record("conversation.history.started", fields: client.diagnosticFields([
            "taskID": taskID.uuidString,
            "threadID": threadID,
            "taskStatus": task.status.rawValue
        ]))
        do {
            let history = try await client.loadThread(id: threadID, workspace: workspace, onActionRequest: onActionRequest)
            StationAIDiagnostics.record("conversation.history.succeeded", fields: client.diagnosticFields([
                "taskID": taskID.uuidString,
                "threadID": threadID,
                "messageCount": String(history.messages.count),
                "activityCount": String(history.activities.count)
            ]))
            return history
        } catch {
            var fields = StationAIDiagnostics.errorFields(error, redacting: [task.title, task.savedPrompt ?? ""])
            fields["taskID"] = taskID.uuidString
            fields["threadID"] = threadID
            fields["taskStatus"] = task.status.rawValue
            fields.merge(client.diagnosticFields()) { _, new in new }
            StationAIDiagnostics.record("conversation.history.failed", fields: fields)
            throw error
        }
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
        imageDataURLs: [String] = [],
        mode: CodexConversationMode = .code,
        modelID: String = CodexAppServerClient.modelID,
        userInputAnswers: [String: [String]] = [:],
        onTurnStarting: (() -> Void)? = nil,
        onUpdate: @escaping (ConversationUpdate) -> Void = { _ in },
        onUserInput: @escaping (CodexUserInputRequest) async -> Void = { _ in }
    ) async throws -> CodexThreadHistory {
        try await tasks.withConversationTurnReservation(taskID) {
            try await self.sendReserved(
                taskID: taskID,
                text: text,
                imageDataURLs: imageDataURLs,
                mode: mode,
                modelID: modelID,
                userInputAnswers: userInputAnswers,
                onTurnStarting: onTurnStarting,
                onUpdate: onUpdate,
                onUserInput: onUserInput
            )
        }
    }

    private func sendReserved(
        taskID: UUID,
        text: String,
        imageDataURLs: [String],
        mode: CodexConversationMode,
        modelID: String,
        userInputAnswers: [String: [String]],
        onTurnStarting: (() -> Void)?,
        onUpdate: @escaping (ConversationUpdate) -> Void,
        onUserInput: @escaping (CodexUserInputRequest) async -> Void
    ) async throws -> CodexThreadHistory {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty || !imageDataURLs.isEmpty else { throw StationAIManagerError.invalidMessage }
        guard imageDataURLs.count <= 8, imageDataURLs.allSatisfy(Self.isValidImageDataURL) else {
            throw BridgeCommandError(code: "invalid_argument", message: "Attach up to 8 valid PNG or JPEG images, each smaller than 10 MB.")
        }
        guard Self.isValidModelID(modelID) else {
            throw BridgeCommandError(code: "invalid_argument", message: "Model ID must contain only letters, digits, dots, underscores, and hyphens.")
        }
        var task = try tasks.taskModel(taskID)
        var persistedThreadID = task.codexThreadID
        StationAIDiagnostics.record("conversation.send.started", fields: client.diagnosticFields([
            "taskID": taskID.uuidString,
            "threadID": task.codexThreadID ?? "new",
            "taskStatus": task.status.rawValue,
            "mode": mode.rawValue
        ]))
        defer {
            if let threadID = persistedThreadID {
                client.clearTurnStarting(threadID: threadID)
            }
        }
        guard task.status != .done else {
            throw StationAIManagerError.invalidTransition("Done tasks are closed. Create a new task for follow-up work.")
        }
        let shouldGenerateTitle = !normalizedText.isEmpty && ["Untitled task", "Generating title…"].contains(task.title)
        let titleMustPrecedeAutoWorktree = task.repositoryWorktrees.contains {
            $0.isPending && $0.branch == "auto"
        }
        let resolveTitleBeforeWorktree = shouldGenerateTitle && titleMustPrecedeAutoWorktree
        if resolveTitleBeforeWorktree {
            let reserved = try await tasks.renameIfTitleMatches(
                taskID,
                expectedTitle: task.title,
                title: "Generating title…"
            )
            if reserved != nil {
                let titleRoots = task.workspaceRootPaths.map { URL(fileURLWithPath: $0, isDirectory: true) }
                let titleWorkspace = try CodexWorkspaceContext(roots: titleRoots)
                let titleClient = CodexAppServerClient(
                    codexExecutableOverride: client.executableOverrideForTitleGeneration
                )
                try await generateAndApplyTitle(
                    taskID: taskID,
                    prompt: normalizedText,
                    workspace: titleWorkspace,
                    client: titleClient
                )
            }
            task = try tasks.taskModel(taskID)
            if ["Untitled task", "Generating title…"].contains(task.title) {
                throw BridgeCommandError(
                    code: "invalid_transition",
                    message: "The task title changed while it was being prepared. Try sending again."
                )
            }
        }
        task = try await tasks.prepareRepositoryWorktrees(taskID, fallbackPrompt: normalizedText)
        if !normalizedText.isEmpty {
            _ = try await tasks.savePrompt(taskID, prompt: normalizedText, status: .inProgress)
        }
        let roots = task.workspaceRootPaths.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let workspace = try CodexWorkspaceContext(roots: roots)
        _ = try await tasks.clearProgressReport(taskID)
        let titleGeneration: Task<Void, Never>?
        if shouldGenerateTitle && !resolveTitleBeforeWorktree {
            let latest = try tasks.taskModel(taskID)
            let titleReserved = ["Untitled task", "Generating title…"].contains(latest.title)
                ? try await tasks.renameIfTitleMatches(
                    taskID,
                    expectedTitle: latest.title,
                    title: "Generating title…"
                ) != nil
                : false
            if titleReserved {
                titleGeneration = Task { @MainActor in
                    let titleClient = CodexAppServerClient(
                        codexExecutableOverride: self.client.executableOverrideForTitleGeneration
                    )
                    do {
                        try await self.generateAndApplyTitle(
                            taskID: taskID,
                            prompt: normalizedText,
                            workspace: workspace,
                            client: titleClient
                        )
                    } catch {
                        // Background title generation has always been best-effort;
                        // the helper records persistence failures before returning.
                    }
                }
            } else {
                titleGeneration = nil
            }
        } else {
            titleGeneration = nil
        }
        let started = try await tasks.setLifecycleStatus(taskID, to: .inProgress)
        onUpdate(ConversationUpdate(type: "started", taskStatus: started.status))
        var phase = "thread-start"
        do {
            let threadID: String
            if let existing = task.codexThreadID {
                threadID = existing
            } else {
                threadID = try await client.startThread(
                    workspace: workspace,
                    modelID: modelID,
                    developerInstructions: TaskProgressReportInstructions.make(taskID: taskID)
                )
                phase = "thread-persistence"
                _ = try await tasks.persistCodexThreadID(taskID, threadID: threadID)
                persistedThreadID = threadID
            }
            if onTurnStarting != nil {
                client.markTurnStarting(threadID: threadID)
                onTurnStarting?()
            }
            phase = "codex-turn"
            try await client.sendMessage(
                normalizedText,
                imageDataURLs: imageDataURLs,
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
                },
                onUserInput: { request async in
                    let status: BoardTaskRecord?
                    if request.isBlocking {
                        status = try? await self.tasks.setLifecycleStatus(taskID, to: .waitingResponse)
                    } else {
                        status = try? await self.tasks.clearProgressReport(taskID)
                    }
                    onUpdate(ConversationUpdate(
                        type: "user_input",
                        userInputRequest: request,
                        taskStatus: status?.status
                    ))
                    if !userInputAnswers.isEmpty {
                        let answersAccepted = self.client.answerUserInput(
                            requestID: request.id,
                            threadID: request.threadID,
                            answers: userInputAnswers
                        )
                        if answersAccepted, request.isBlocking {
                            let resumed = try? await self.tasks.setLifecycleStatus(taskID, to: .inProgress)
                            onUpdate(ConversationUpdate(type: "task_status", taskStatus: resumed?.status))
                        } else if !answersAccepted {
                            onUpdate(ConversationUpdate(type: "action_notice", message: "The supplied answers didn't match Codex's questions."))
                        }
                    }
                    await onUserInput(request)
                }
            )
            phase = "worktree-finalization"
            phase = "review-status-persistence"
            _ = try await tasks.setLifecycleStatus(taskID, to: .review)
        } catch {
            await titleGeneration?.value
            var fields = StationAIDiagnostics.errorFields(error, redacting: [task.title, task.savedPrompt ?? ""])
            fields["taskID"] = taskID.uuidString
            fields["threadID"] = persistedThreadID ?? ""
            fields["phase"] = phase
            fields["storePath"] = StationAIDiagnostics.storeURL.path
            fields.merge(client.diagnosticFields()) { _, new in new }
            _ = try? await tasks.setLifecycleStatus(taskID, to: .blocked, message: error.localizedDescription)
            StationAIDiagnostics.record("conversation.send.failed", fields: fields)
            throw error
        }
        await titleGeneration?.value
        let finalHistory = try await history(taskID: taskID) {
            onUpdate(ConversationUpdate(
                type: "action_notice",
                message: "Codex requested an approval. StationAI denied it because approval prompts are disabled."
            ))
        }
        onUpdate(ConversationUpdate(type: "completed", history: finalHistory))
        return finalHistory
    }

    private func generateAndApplyTitle(
        taskID: UUID,
        prompt: String,
        workspace: CodexWorkspaceContext,
        client titleClient: CodexAppServerClient
    ) async throws {
        let generated = await CodexTaskTitleGenerator(client: titleClient)
            .generateTitle(from: prompt, workspace: workspace, taskID: taskID)
        let fallback = prompt.split(whereSeparator: \.isWhitespace).prefix(8).joined(separator: " ")
        let titleSource = generated == nil ? "prompt-fallback" : "codex"
        let latest: BoardTask
        do {
            latest = try tasks.taskModel(taskID)
        } catch {
            var fields = StationAIDiagnostics.errorFields(error)
            fields["taskID"] = taskID.uuidString
            fields["titleSource"] = titleSource
            StationAIDiagnostics.record("task.title_apply.skipped", fields: fields.merging(["reason": "task_unavailable"]) { _, new in new })
            return
        }
        guard latest.title == "Generating title…" else {
            StationAIDiagnostics.record("task.title_apply.skipped", fields: [
                "taskID": taskID.uuidString,
                "reason": "title_changed",
                "currentTitleState": StationAITaskTitleDiagnostics.state(of: latest.title),
                "titleSource": titleSource
            ])
            return
        }
        let resolvedTitle = generated.flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        do {
            guard try await tasks.renameIfTitleMatches(
                taskID,
                expectedTitle: "Generating title…",
                title: resolvedTitle
            ) != nil else {
                let currentTitle = (try? tasks.taskModel(taskID).title) ?? ""
                StationAIDiagnostics.record("task.title_apply.skipped", fields: [
                    "taskID": taskID.uuidString,
                    "reason": "title_changed",
                    "currentTitleState": StationAITaskTitleDiagnostics.state(of: currentTitle),
                    "titleSource": titleSource
                ])
                return
            }
            StationAIDiagnostics.record("task.title_apply.succeeded", fields: [
                "taskID": taskID.uuidString,
                "titleSource": titleSource,
                "fallbackWordCount": generated == nil ? String(fallback.split(whereSeparator: \.isWhitespace).count) : "0"
            ])
        } catch {
            var fields = StationAIDiagnostics.errorFields(error, redacting: [resolvedTitle, prompt])
            fields["taskID"] = taskID.uuidString
            fields["titleSource"] = titleSource
            StationAIDiagnostics.record("task.title_apply.failed", fields: fields)
            guard generated != nil else { throw error }

            // A generated title is optional; recover with the deterministic prompt
            // fallback before any auto-named worktree can be allocated.
            do {
                guard try await tasks.renameIfTitleMatches(
                    taskID,
                    expectedTitle: "Generating title…",
                    title: fallback
                ) != nil else {
                    let currentTitle = (try? tasks.taskModel(taskID).title) ?? ""
                    StationAIDiagnostics.record("task.title_apply.skipped", fields: [
                        "taskID": taskID.uuidString,
                        "reason": "title_changed",
                        "currentTitleState": StationAITaskTitleDiagnostics.state(of: currentTitle),
                        "titleSource": "prompt-fallback"
                    ])
                    return
                }
                StationAIDiagnostics.record("task.title_apply.succeeded", fields: [
                    "taskID": taskID.uuidString,
                    "titleSource": "prompt-fallback",
                    "fallbackWordCount": String(fallback.split(whereSeparator: \.isWhitespace).count)
                ])
            } catch {
                var recoveryFields = StationAIDiagnostics.errorFields(error, redacting: [fallback, prompt])
                recoveryFields["taskID"] = taskID.uuidString
                recoveryFields["titleSource"] = "prompt-fallback"
                recoveryFields["recoveryAttempt"] = "true"
                StationAIDiagnostics.record("task.title_apply.failed", fields: recoveryFields)
                throw error
            }
        }
    }

    private static func isValidModelID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 100 && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-").contains($0)
        }
    }

    private static func isValidImageDataURL(_ value: String) -> Bool {
        guard let separator = value.firstIndex(of: ",") else { return false }
        let mime = String(value[..<separator])
        guard let data = Data(base64Encoded: String(value[value.index(after: separator)...])), data.count <= 10_000_000 else { return false }
        let bytes = [UInt8](data.prefix(12))
        if mime == "data:image/png;base64" {
            return bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10])
        }
        if mime == "data:image/jpeg;base64" {
            return bytes.starts(with: [255, 216, 255])
        }
        return false
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
            try await StationAIStore.prepareLifecycle(container: container, dataDirectory: dataDirectory)
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
                result = try Self.value(await taskManager.create(title: title, repositories: repositories, contextFolders: roots))
            case "task.get", "task.show":
                let taskID = try request.requiredUUID("taskID")
                result = try Self.value(taskManager.get(taskID))
            case "task.move":
                let taskID = try request.requiredUUID("taskID")
                let status = try request.requiredString("status")
                result = try Self.value(await taskManager.move(
                    taskID,
                    to: status,
                    allowUnmergedPullRequests: request.arguments["allowUnmergedPullRequests"]?.bool ?? false
                ))
            case "task.pr.create":
                result = try Self.value(await taskManager.createPullRequests(
                    request.requiredUUID("taskID"),
                    client: CodexAppServerClient(codexExecutableOverride: request.arguments["__codexExecutable"]?.string)
                ))
            case "task.progress.publish":
                let rawType = try request.requiredString("type")
                guard let type = TaskProgressType(rawValue: rawType) else {
                    throw BridgeCommandError(code: "invalid_argument", message: "Unknown progress type '\(rawType)'. Valid types: \(TaskProgressType.allCases.map(\.rawValue).joined(separator: ", ")).")
                }
                let detail = request.arguments["detail"]?.string
                result = try Self.value(try await taskManager.publishProgressReport(request.requiredUUID("taskID"), type: type, detail: detail))
            case "task.progress.custom":
                result = try Self.value(try await taskManager.publishProgressReport(
                    request.requiredUUID("taskID"), type: nil,
                    customLabel: request.requiredString("label"),
                    detail: request.arguments["detail"]?.string
                ))
            case "task.progress.clear":
                result = try Self.value(try await taskManager.clearProgressReport(request.requiredUUID("taskID")))
            case "task.rename":
                let taskID = try request.requiredUUID("taskID")
                let title = try request.requiredString("title")
                result = try Self.value(try await taskManager.rename(taskID, title: title))
            case "task.repository.add":
                result = try Self.value(await workspaces.addRepository(
                    request.requiredString("repositoryPath"),
                    to: request.requiredUUID("taskID")
                ))
            case "task.repository.add-batch":
                result = try Self.value(await workspaces.addRepositories(
                    request.requiredStrings("repositoryPaths"),
                    to: request.requiredUUID("taskID")
                ))
            case "task.repository.edit":
                result = try Self.value(await taskManager.updateRepository(
                    request.requiredUUID("taskID"),
                    repositoryPath: request.requiredString("repositoryPath"),
                    branch: request.requiredString("branch"),
                    branchFrom: request.requiredString("branchFrom"),
                    mergeTarget: request.arguments["mergeTarget"]?.string
                ))
            case "task.repository.remove":
                result = try Self.value(await taskManager.removeRepository(
                    request.requiredUUID("taskID"),
                    repositoryPath: request.requiredString("repositoryPath")
                ))
            case "task.prompt.save":
                let status = try request.arguments["status"]?.string.map { value -> TaskStatus in
                    guard let status = TaskStatus(rawValue: value) else { throw StationAIManagerError.invalidStatus(value) }
                    return status
                }
                result = try Self.value(try await taskManager.savePrompt(
                    request.requiredUUID("taskID"), prompt: request.requiredString("prompt"), status: status
                ))
            case "task.delete":
                try await taskManager.delete(request.requiredUUID("taskID"))
                result = .object(["deleted": .boolean(true)])
            case "task.delete.requires-confirmation":
                let requiresConfirmation = try await taskManager.deleteRequiresConfirmation(request.requiredUUID("taskID"))
                result = .object(["requiresConfirmation": .boolean(requiresConfirmation)])
            case "task.roots.get", "workspace.roots":
                result = .object(["roots": .array(try workspaces.roots(for: request.requiredUUID("taskID")).map(BridgeValue.string))])
            case "task.roots.set":
                let roots = try request.requiredStrings("roots")
                result = try Self.value(await workspaces.setRoots(roots, for: request.requiredUUID("taskID")))
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
                    "defaultParentAvailable": .boolean(settings.defaultParentFolderURL != nil),
                    "lastSelectedRepositories": .array(settings.lastSelectedRepositories.map(BridgeValue.string)),
                    "appearance": .string(settings.appearance)
                ])
            case "settings.set-appearance":
                try settings.setAppearance(request.requiredString("appearance"))
                result = .object(["appearance": .string(settings.appearance)])
            case "settings.set-parent":
                try settings.setDefaultParentFolder(request.requiredString("path"))
                result = .object(["defaultParentFolder": .string(settings.defaultParentFolderPath)])
            case "settings.clear-parent":
                try settings.setDefaultParentFolder(nil)
                result = .object(["defaultParentFolder": .null])
            case "settings.set-last-repositories":
                let repositories = try request.requiredStrings("repositories")
                try settings.setLastSelectedRepositories(repositories)
                result = .object(["lastSelectedRepositories": .array(settings.lastSelectedRepositories.map(BridgeValue.string))])
            case "conversation.history":
                let conversations = CodexConversationManager(
                    tasks: taskManager,
                    client: CodexAppServerClient(codexExecutableOverride: request.arguments["__codexExecutable"]?.string)
                )
                result = try Self.value(await conversations.history(taskID: request.requiredUUID("taskID")))
            case "conversation.models":
                let conversations = CodexConversationManager(tasks: taskManager, client: CodexAppServerClient())
                result = .object(["models": .array(try await conversations.models(taskID: request.requiredUUID("taskID")).map { try Self.value($0) })])
            case "conversation.send":
                let taskID = try request.requiredUUID("taskID")
                let message = request.arguments["message"]?.string ?? ""
                let modeValue = request.arguments["mode"]?.string ?? CodexConversationMode.code.rawValue
                guard let mode = CodexConversationMode(rawValue: modeValue) else {
                    throw BridgeCommandError(
                        code: "invalid_argument",
                        message: "Unknown conversation mode '\(modeValue)'. Valid modes: default, plan."
                    )
                }
                let modelID = request.arguments["model"]?.string ?? CodexAppServerClient.modelID
                let answers = try request.optionalStringArrays("answers")
                let imageDataURLs = request.arguments["images"]?.strings ?? []
                let conversations = CodexConversationManager(
                    tasks: taskManager,
                    client: CodexAppServerClient(codexExecutableOverride: request.arguments["__codexExecutable"]?.string)
                )
                let history = try await conversations.send(taskID: taskID, text: message, imageDataURLs: imageDataURLs, mode: mode, modelID: modelID, userInputAnswers: answers, onUpdate: { update in
                    if let payload = try? Self.value(update) {
                        eventHandler(BridgeEvent(requestID: request.id, type: update.type, payload: payload))
                    }
                })
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
            case .invalidTransition: code = "invalid_argument"
            case .unmergedPullRequests: code = "invalid_transition"
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

    func requiredStringArrays(_ name: String) throws -> [String: [String]] {
        guard let object = arguments[name]?.object else {
            throw BridgeCommandError(code: "invalid_argument", message: "Missing required answer map: \(name).")
        }
        var result: [String: [String]] = [:]
        for (key, value) in object {
            guard case .array(let values) = value else {
                throw BridgeCommandError(code: "invalid_argument", message: "Answers for \(key) must be a list of strings.")
            }
            let strings = values.compactMap(\.string)
            guard strings.count == values.count else {
                throw BridgeCommandError(code: "invalid_argument", message: "Answers for \(key) must be a list of strings.")
            }
            result[key] = strings
        }
        return result
    }

    func optionalStringArrays(_ name: String) throws -> [String: [String]] {
        guard arguments[name] != nil else { return [:] }
        return try requiredStringArrays(name)
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
                branchFrom: object["branchFrom"]?.string,
                mergeTarget: object["mergeTarget"]?.string
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
