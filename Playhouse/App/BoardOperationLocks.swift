import Foundation
import AppKit
import SwiftData
import Darwin
import SQLite3

extension BoardTaskManager {
    func withTaskOperationLock<T>(
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

    static func isStoreOpenFailure(_ error: Error) -> Bool {
        var underlying: NSError? = error as NSError
        var depth = 0
        while let current = underlying, depth < 5 {
            if current.domain == NSCocoaErrorDomain, current.code == 256 {
                return true
            }
            underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return false
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

    /// Runs `operation` holding the task's turn reservation only if no one holds it now;
    /// returns nil, without waiting, when another send or process does.
    func withConversationTurnReservationIfFree<T>(
        _ id: UUID,
        operation: @MainActor () async throws -> T
    ) async throws -> T? {
        guard let conversationTurnLockDirectory else {
            throw BridgeFileLockError(message: "Couldn't determine the task-store location for the conversation-turn reservation.")
        }
        guard try !hasConversationTurnReservation(id) else { return nil }
        let lockURL = conversationTurnLockDirectory.appendingPathComponent("\(id.uuidString).lock")
        do {
            return try await withExclusiveFileLocks(at: [lockURL], purpose: "conversation-turn", waitingForHolder: false) {
                try await operation()
            }
        } catch is FileLockHeldError {
            return nil
        }
    }

    func hasConversationTurnReservation(_ id: UUID) throws -> Bool {
        guard let conversationTurnLockDirectory else {
            throw BridgeFileLockError(message: "Couldn't determine the task-store location for the conversation-turn reservation.")
        }
        let lockURL = conversationTurnLockDirectory.appendingPathComponent("\(id.uuidString).lock")
        return try hasReservation(at: lockURL, purpose: "conversation-turn")
    }

    func hasReservation(at url: URL, purpose: String) throws -> Bool {
        let lockURL = url.standardizedFileURL
        let key = lockURL.path
        guard !TaskOperationLockGate.isHeld(key) else { return true }

        let descriptor = Darwin.open(lockURL.path, O_RDWR | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return false }
            throw BridgeFileLockError(message: "Couldn't inspect the \(purpose) reservation (errno \(errno)).")
        }
        defer { _ = Darwin.close(descriptor) }

        var lock = flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        guard Darwin.fcntl(descriptor, F_GETLK, &lock) == 0 else {
            throw BridgeFileLockError(message: "Couldn't inspect the \(purpose) reservation (errno \(errno)).")
        }
        return lock.l_type != Int16(F_UNLCK)
    }

    func queueDeferredRepositoryRemoval(taskID: UUID, record: RepositoryWorktreeRecord) throws -> URL {
        guard let conversationTurnLockDirectory else {
            throw BridgeFileLockError(message: "Couldn't determine the task-store location for deferred repository cleanup.")
        }
        try FileManager.default.createDirectory(at: conversationTurnLockDirectory, withIntermediateDirectories: true)
        let payload = DeferredRepositoryRemoval(taskID: taskID, record: record)
        let url = conversationTurnLockDirectory.appendingPathComponent("\(taskID.uuidString).\(UUID().uuidString).repository-removal.json")
        try JSONEncoder().encode(payload).write(to: url, options: .atomic)
        guard Darwin.chmod(url.path, mode_t(0o600)) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: url)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        return url
    }

    func deferredRepositoryRemovals() throws -> [(URL, DeferredRepositoryRemoval)] {
        guard let conversationTurnLockDirectory else {
            throw BridgeFileLockError(message: "Couldn't determine the task-store location for deferred repository cleanup.")
        }
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: conversationTurnLockDirectory,
            includingPropertiesForKeys: nil
        ) else { return [] }
        return try urls.filter { $0.lastPathComponent.hasSuffix(".repository-removal.json") }.compactMap { url in
            (url, try JSONDecoder().decode(DeferredRepositoryRemoval.self, from: Data(contentsOf: url)))
        }
    }

    func clearDeferredRepositoryRemoval(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    func conversationTurnOutcomeURL(_ id: UUID) throws -> URL {
        guard let conversationTurnLockDirectory else {
            throw BridgeFileLockError(message: "Couldn't determine the task-store location for the conversation outcome.")
        }
        return conversationTurnLockDirectory.appendingPathComponent("\(id.uuidString).outcome")
    }

    func conversationTurnActiveURL(_ id: UUID) throws -> URL {
        guard let conversationTurnLockDirectory else {
            throw BridgeFileLockError(message: "Couldn't determine the task-store location for the active conversation turn.")
        }
        return conversationTurnLockDirectory.appendingPathComponent("\(id.uuidString).active")
    }

    func prepareConversationTurnOutcome(_ id: UUID) throws {
        for marker in [try conversationTurnOutcomeURL(id), try conversationTurnActiveURL(id)]
        where FileManager.default.fileExists(atPath: marker.path) {
            try FileManager.default.removeItem(at: marker)
        }
    }

    func activateConversationTurnOutcome(_ id: UUID) throws {
        guard try hasConversationTurnReservation(id) else {
            throw BridgeCommandError(code: "invalid_transition", message: "A turn outcome requires an active conversation turn.")
        }
        let marker = try conversationTurnActiveURL(id)
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        // The service whose daemon runs the turn: after a restart, only that service's next
        // daemon goes back to it, even when another service shares this data folder.
        try Data(AgentRunService.name.utf8).write(to: marker, options: .atomic)
    }

    func clearConversationTurnOutcome(_ id: UUID) {
        try? FileManager.default.removeItem(at: try conversationTurnOutcomeURL(id))
        try? FileManager.default.removeItem(at: try conversationTurnActiveURL(id))
    }

    /// Tasks whose turn was running when the daemon running it exited: the turn's active marker
    /// outlived it, and no process holds the task's turn reservation any more.
    func tasksWithCutOffTurns() -> [UUID] {
        guard let conversationTurnLockDirectory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: conversationTurnLockDirectory.path) else { return [] }
        return names.compactMap { name -> UUID? in
            guard name.hasSuffix(".active") else { return nil }
            let owner = (try? String(contentsOf: conversationTurnLockDirectory.appendingPathComponent(name), encoding: .utf8)) ?? ""
            guard owner.isEmpty || owner == AgentRunService.name else { return nil }
            return UUID(uuidString: String(name.dropLast(".active".count)))
        }.filter { (try? hasConversationTurnReservation($0)) == false }
    }

    func finishConversationTurnOutcome(_ id: UUID) async throws -> String? {
        let outcomeURL = try conversationTurnOutcomeURL(id)
        let activeURL = try conversationTurnActiveURL(id)
        let lockURL = outcomeURL.appendingPathExtension("lock")
        return try await withExclusiveFileLocks(at: [lockURL], purpose: "conversation-outcome") {
            try? FileManager.default.removeItem(at: activeURL)
            defer { try? FileManager.default.removeItem(at: outcomeURL) }
            guard let data = try? Data(contentsOf: outcomeURL) else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }

    func withRepositoryAllocationLocks<T>(
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

    /// Thrown instead of waiting when a lock taken with `waitingForHolder: false` is held.
    struct FileLockHeldError: Error {}

    func withExclusiveFileLocks<T>(
        at lockURLs: [URL],
        purpose: String,
        waitingForHolder: Bool = true,
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
                                guard waitingForHolder else {
                                    _ = Darwin.close(descriptor)
                                    throw FileLockHeldError()
                                }
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
}
