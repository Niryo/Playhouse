import Foundation
import CoreServices

final class WorkspaceChangeWatcher {
    private let paths: [String]
    private let onChange: () -> Void
    private var stream: FSEventStreamRef?
    private var pendingRefresh: DispatchWorkItem?

    init(paths: [String], onChange: @escaping () -> Void) {
        self.paths = paths
        self.onChange = onChange
    }

    static func watchPaths(workspaceRoots: [String]) async -> [String] {
        await Task.detached(priority: .utility) {
            var paths = Set(workspaceRoots.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path })
            for rootPath in workspaceRoots {
                let root = URL(fileURLWithPath: rootPath, isDirectory: true)
                for repository in RepositoryScanner.scanSynchronously(parent: root) {
                    let marker = repository.appendingPathComponent(".git")
                    guard let contents = try? String(contentsOf: marker, encoding: .utf8),
                          contents.hasPrefix("gitdir: ") else { continue }
                    let reference = contents.dropFirst("gitdir: ".count).trimmingCharacters(in: .whitespacesAndNewlines)
                    let gitDirectory = URL(fileURLWithPath: reference, relativeTo: repository).standardizedFileURL
                    if WorkspaceSettings.validDirectoryURL(for: gitDirectory.path) != nil {
                        paths.insert(gitDirectory.path)
                    }
                }
            }
            return paths.sorted()
        }.value
    }

    func start() {
        guard stream == nil, !paths.isEmpty else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<WorkspaceChangeWatcher>.fromOpaque(info).takeUnretainedValue().scheduleRefresh()
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }
        self.stream = stream
    }

    func stop() {
        pendingRefresh?.cancel()
        pendingRefresh = nil
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func scheduleRefresh() {
        pendingRefresh?.cancel()
        let refresh = DispatchWorkItem { [weak self] in self?.onChange() }
        pendingRefresh = refresh
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250), execute: refresh)
    }

    deinit { stop() }
}

enum WorkspaceChangeGroup: String, Codable, CaseIterable {
    case staged
    case working
}

struct WorkspaceChangeEntry: Codable, Equatable, Identifiable {
    let repository: String
    let path: String
    let originalPath: String?
    let status: String
    let statusCode: String
    let group: WorkspaceChangeGroup

    var id: String {
        "\(group.rawValue):\(repository):\(path)"
    }
}

struct WorkspaceChangeInventory: Codable, Equatable {
    let staged: [WorkspaceChangeEntry]
    let working: [WorkspaceChangeEntry]

    var isEmpty: Bool { staged.isEmpty && working.isEmpty }
}

struct WorkspaceFileDiff: Codable, Equatable {
    let repository: String
    let path: String
    let group: WorkspaceChangeGroup
    let original: String?
    let modified: String?
    let isText: Bool
    let message: String?
}

enum WorkspaceChangeScanner {
    private struct StatusRecord {
        let indexStatus: UInt8
        let worktreeStatus: UInt8
        let path: String
        let originalPath: String?
    }

    private struct RepositoryInventory {
        let repositories: [URL]
        let changes: WorkspaceChangeInventory
    }

    private struct GitResult {
        let status: Int32
        let output: Data
        let error: String
    }

    private final class OutputBox {
        private let lock = NSLock()
        private var storedOutput = Data()
        private var storedError = Data()

        func setOutput(_ data: Data) {
            lock.lock()
            storedOutput = data
            lock.unlock()
        }

        func setError(_ data: Data) {
            lock.lock()
            storedError = data
            lock.unlock()
        }

        func values() -> (Data, Data) {
            lock.lock()
            defer { lock.unlock() }
            return (storedOutput, storedError)
        }
    }

    static func inventory(workspaceRoots: [String]) async throws -> WorkspaceChangeInventory {
        try await Task.detached(priority: .utility) {
            try inventorySynchronously(workspaceRoots: workspaceRoots).changes
        }.value
    }

    static func diff(
        workspaceRoots: [String],
        repositoryPath: String,
        relativePath: String,
        group: WorkspaceChangeGroup
    ) async throws -> WorkspaceFileDiff {
        try await Task.detached(priority: .utility) {
            try diffSynchronously(
                workspaceRoots: workspaceRoots,
                repositoryPath: repositoryPath,
                relativePath: relativePath,
                group: group
            )
        }.value
    }

    private static func inventorySynchronously(workspaceRoots: [String]) throws -> RepositoryInventory {
        var repositoriesByPath: [String: URL] = [:]
        for rootPath in workspaceRoots {
            let root = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
            guard WorkspaceSettings.validDirectoryURL(for: root.path) != nil else {
                throw BridgeCommandError(code: "invalid_argument", message: "The working folder is unavailable: \(root.path)")
            }

            for repository in RepositoryScanner.scanSynchronously(parent: root) {
                let normalizedRepository = repository.standardizedFileURL
                guard isPath(normalizedRepository.path, inside: root.path) else { continue }
                repositoriesByPath[normalizedRepository.path] = normalizedRepository
            }
        }

        let repositories = repositoriesByPath.values.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
        var staged: [WorkspaceChangeEntry] = []
        var working: [WorkspaceChangeEntry] = []

        for repository in repositories {
            let result = try runGit(
                repository: repository,
                arguments: ["status", "--porcelain=v1", "-z", "--untracked-files=all"]
            )
            guard result.status == 0 else {
                throw BridgeCommandError(
                    code: "operation_failed",
                    message: "Git couldn't read changes in \(repository.path): \(result.error.trimmingCharacters(in: .whitespacesAndNewlines))"
                )
            }

            for record in try parseStatus(result.output) {
                let code = String(decoding: [record.indexStatus, record.worktreeStatus], as: UTF8.self)
                if record.indexStatus != 32 && record.indexStatus != 63 {
                    staged.append(WorkspaceChangeEntry(
                        repository: repository.path,
                        path: record.path,
                        originalPath: record.originalPath,
                        status: statusName(index: record.indexStatus, worktree: record.worktreeStatus, group: .staged),
                        statusCode: code,
                        group: .staged
                    ))
                }
                if record.worktreeStatus != 32 && record.worktreeStatus != 63 ||
                    (record.indexStatus == 63 && record.worktreeStatus == 63) {
                    working.append(WorkspaceChangeEntry(
                        repository: repository.path,
                        path: record.path,
                        originalPath: record.originalPath,
                        status: statusName(index: record.indexStatus, worktree: record.worktreeStatus, group: .working),
                        statusCode: code,
                        group: .working
                    ))
                }
            }
        }

        func sort(_ entries: [WorkspaceChangeEntry]) -> [WorkspaceChangeEntry] {
            entries.sorted {
                if $0.repository != $1.repository {
                    return $0.repository.localizedStandardCompare($1.repository) == .orderedAscending
                }
                return $0.path.localizedStandardCompare($1.path) == .orderedAscending
            }
        }

        return RepositoryInventory(
            repositories: repositories,
            changes: WorkspaceChangeInventory(staged: sort(staged), working: sort(working))
        )
    }

    private static func diffSynchronously(
        workspaceRoots: [String],
        repositoryPath: String,
        relativePath: String,
        group: WorkspaceChangeGroup
    ) throws -> WorkspaceFileDiff {
        guard isSafeRelativePath(relativePath) else {
            throw BridgeCommandError(code: "invalid_argument", message: "The changed file path must be relative to its repository.")
        }

        let inventory = try inventorySynchronously(workspaceRoots: workspaceRoots)
        let repository = URL(fileURLWithPath: repositoryPath, isDirectory: true).standardizedFileURL.path
        guard inventory.repositories.contains(where: { $0.path == repository }) else {
            throw BridgeCommandError(code: "invalid_argument", message: "The repository isn't inside this task's working folders.")
        }

        let entries = group == .staged ? inventory.changes.staged : inventory.changes.working
        guard let entry = entries.first(where: { $0.repository == repository && $0.path == relativePath }) else {
            throw BridgeCommandError(code: "not_found", message: "The file no longer has a \(group.rawValue) change.")
        }

        if entry.status == "conflict" {
            return WorkspaceFileDiff(
                repository: repository,
                path: relativePath,
                group: group,
                original: nil,
                modified: nil,
                isText: false,
                message: "Resolve the merge conflict before previewing this file."
            )
        }

        let bytes: (Data, Data)
        switch group {
        case .staged:
            let indexStatus = entry.statusCode.utf8.first ?? 32
            let original = indexStatus == 65
                ? Data()
                : try gitBlob(
                    repository: URL(fileURLWithPath: repository, isDirectory: true),
                    revision: "HEAD",
                    path: entry.originalPath ?? relativePath,
                    missingAllowed: indexStatus == 65
                ) ?? Data()
            let modified = indexStatus == 68
                ? Data()
                : try gitBlob(
                    repository: URL(fileURLWithPath: repository, isDirectory: true),
                    revision: "",
                    path: relativePath,
                    missingAllowed: false
                ) ?? Data()
            bytes = (original, modified)
        case .working:
            let statusBytes = Array(entry.statusCode.utf8)
            let worktreeStatus = statusBytes.count > 1 ? statusBytes[1] : 32
            let isUntracked = statusBytes == [63, 63]
            let original = isUntracked || worktreeStatus == 65
                ? Data()
                : try gitBlob(
                    repository: URL(fileURLWithPath: repository, isDirectory: true),
                    revision: "",
                    path: entry.originalPath ?? relativePath,
                    missingAllowed: false
                ) ?? Data()
            let modified = worktreeStatus == 68
                ? Data()
                : try worktreeBytes(repository: URL(fileURLWithPath: repository, isDirectory: true), path: relativePath)
            bytes = (original, modified)
        }

        guard let original = text(bytes.0), let modified = text(bytes.1) else {
            return WorkspaceFileDiff(
                repository: repository,
                path: relativePath,
                group: group,
                original: nil,
                modified: nil,
                isText: false,
                message: "This binary or non-UTF-8 file can't be shown as a text diff."
            )
        }

        return WorkspaceFileDiff(
            repository: repository,
            path: relativePath,
            group: group,
            original: original,
            modified: modified,
            isText: true,
            message: nil
        )
    }

    private static func parseStatus(_ data: Data) throws -> [StatusRecord] {
        let bytes = Array(data)
        var result: [StatusRecord] = []
        var start = 0

        func pathString(_ range: Range<Int>) throws -> String {
            guard let path = String(bytes: bytes[range], encoding: .utf8) else {
                throw BridgeCommandError(code: "operation_failed", message: "Git returned a path that isn't valid UTF-8.")
            }
            return path
        }

        while start < bytes.count {
            guard let end = bytes[start...].firstIndex(of: 0) else {
                throw BridgeCommandError(code: "operation_failed", message: "Git returned an incomplete change list.")
            }
            let token = bytes[start..<end]
            guard token.count >= 4, token[token.startIndex + 2] == 32 else {
                throw BridgeCommandError(code: "operation_failed", message: "Git returned an invalid change-list entry.")
            }
            let indexStatus = token[token.startIndex]
            let worktreeStatus = token[token.startIndex + 1]
            let path = try pathString((start + 3)..<end)
            start = end + 1

            var originalPath: String?
            if indexStatus == 82 || indexStatus == 67 || worktreeStatus == 82 || worktreeStatus == 67 {
                guard start < bytes.count,
                      let originalEnd = bytes[start...].firstIndex(of: 0) else {
                    throw BridgeCommandError(code: "operation_failed", message: "Git returned an incomplete rename entry.")
                }
                originalPath = try pathString(start..<originalEnd)
                start = originalEnd + 1
            }

            result.append(StatusRecord(
                indexStatus: indexStatus,
                worktreeStatus: worktreeStatus,
                path: path,
                originalPath: originalPath
            ))
        }
        return result
    }

    private static func statusName(index: UInt8, worktree: UInt8, group: WorkspaceChangeGroup) -> String {
        if index == 85 || worktree == 85 || (index == 68 && worktree == 68) { return "conflict" }
        let status = group == .staged ? index : worktree
        if status == 82 { return "renamed" }
        if status == 67 { return "copied" }
        if status == 68 { return "deleted" }
        if index == 63 && worktree == 63 { return "untracked" }
        if status == 65 { return "added" }
        return "modified"
    }

    private static func gitBlob(
        repository: URL,
        revision: String,
        path: String,
        missingAllowed: Bool
    ) throws -> Data? {
        let object = revision.isEmpty ? ":\(path)" : "\(revision):\(path)"
        let result = try runGit(repository: repository, arguments: ["show", "--no-ext-diff", "--format=", object])
        if result.status == 0 { return result.output }
        if missingAllowed { return nil }
        throw BridgeCommandError(
            code: "not_found",
            message: "Git couldn't read the selected version of \(path): \(result.error.trimmingCharacters(in: .whitespacesAndNewlines))"
        )
    }

    private static func worktreeBytes(repository: URL, path: String) throws -> Data {
        let fileURL = repository.appendingPathComponent(path).standardizedFileURL
        guard isPath(fileURL.path, inside: repository.standardizedFileURL.path) else {
            throw BridgeCommandError(code: "invalid_argument", message: "The changed file is outside its repository.")
        }

        var currentURL = repository.standardizedFileURL
        let components = path.split(separator: "/").map(String.init)
        for (index, component) in components.enumerated() {
            currentURL.appendPathComponent(component)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: currentURL.path) else {
                throw BridgeCommandError(code: "not_found", message: "The changed file no longer exists: \(path)")
            }
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                guard index == components.count - 1 else {
                    throw BridgeCommandError(code: "invalid_argument", message: "A changed file can't be read through a symbolic-link directory.")
                }
                let destination = try FileManager.default.destinationOfSymbolicLink(atPath: currentURL.path)
                return Data("link \(destination)\n".utf8)
            }
        }

        do {
            return try Data(contentsOf: fileURL, options: .mappedIfSafe)
        } catch {
            throw BridgeCommandError(code: "operation_failed", message: "Couldn't read \(path): \(error.localizedDescription)")
        }
    }

    private static func text(_ data: Data) -> String? {
        guard !data.contains(0) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~") else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false).contains { $0 == ".." || $0.isEmpty }
    }

    private static func isPath(_ candidate: String, inside root: String) -> Bool {
        candidate == root || candidate.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    private static func gitExecutable() throws -> URL {
        let environmentPaths = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent("git").path }
        let candidates = ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"] + environmentPaths
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw BridgeCommandError(code: "operation_failed", message: "Git isn't installed or couldn't be found.")
        }
        return URL(fileURLWithPath: path)
    }

    private static func runGit(repository: URL, arguments: [String]) throws -> GitResult {
        let process = Process()
        process.executableURL = try gitExecutable()
        process.arguments = ["-c", "core.fsmonitor=false", "-C", repository.path] + arguments

        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_PAGER"] = "cat"
        environment["LC_ALL"] = "C"
        process.environment = environment

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let outputBox = OutputBox()
        let readers = DispatchGroup()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw BridgeCommandError(code: "operation_failed", message: "Couldn't start Git: \(error.localizedDescription)")
        }
        try? outputPipe.fileHandleForWriting.close()
        try? errorPipe.fileHandleForWriting.close()

        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            outputBox.setOutput(outputPipe.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            outputBox.setError(errorPipe.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }

        process.waitUntilExit()
        readers.wait()
        let (output, errorData) = outputBox.values()
        return GitResult(
            status: process.terminationStatus,
            output: output,
            error: String(decoding: errorData, as: UTF8.self)
        )
    }
}
