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
    case unviewed
    case viewed

    /// The raw value is the stable CLI/XPC term; this is what people read.
    var displayName: String {
        self == .viewed ? "reviewed" : "pending"
    }
}

struct WorkspaceViewedChange: Codable, Equatable, Identifiable {
    let repository: String
    let path: String
    let isPresent: Bool
    let contents: Data
    var id: String { "\(repository):\(path)" }
}

extension BoardTask {
    var viewedWorkspaceChanges: [WorkspaceViewedChange] {
        get {
            guard let viewedWorkspaceChangesData else { return [] }
            return (try? JSONDecoder().decode([WorkspaceViewedChange].self, from: viewedWorkspaceChangesData)) ?? []
        }
        set { viewedWorkspaceChangesData = try? JSONEncoder().encode(newValue) }
    }
}

struct WorkspaceChangeEntry: Codable, Equatable, Identifiable {
    let repository: String
    let path: String
    let originalPath: String?
    let status: String
    let statusCode: String
    let group: WorkspaceChangeGroup
    let isUncommitted: Bool
    let hasViewedSnapshot: Bool

    /// A file can be listed in both sections at once, so the group is part of its identity.
    var id: String {
        "\(group.rawValue):\(repository):\(path)"
    }
}

struct WorkspaceChangeInventory: Codable, Equatable {
    let unviewed: [WorkspaceChangeEntry]
    let viewed: [WorkspaceChangeEntry]

    var isEmpty: Bool { unviewed.isEmpty && viewed.isEmpty }
}

/// How a task's terminal panel starts its shell. `environment` holds only the variables
/// Playhouse sets on top of the app's own environment.
struct TaskTerminalLaunch: Codable, Equatable {
    let taskID: UUID
    let directory: String
    let shell: String
    /// The shell runs as a login shell, as Terminal.app starts it, so the user's profile applies.
    let arguments: [String]
    let environment: [String: String]

    /// The account's login shell, falling back to `$SHELL` and then zsh.
    static func loginShell() -> String {
        var candidates: [String] = []
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            candidates.append(String(cString: shell))
        }
        if let shell = ProcessInfo.processInfo.environment["SHELL"] { candidates.append(shell) }
        return candidates.first { !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0) } ?? "/bin/zsh"
    }

    static func environment(taskID: UUID) -> [String: String] {
        var environment = [
            "TERM": "xterm-256color",
            "COLORTERM": "truecolor",
            "TERM_PROGRAM": "Playhouse",
            "PLAYHOUSE_TASK_ID": taskID.uuidString
        ]
        // Apps launched from Finder get no locale, which leaves shells and CLIs in ASCII mode.
        if ProcessInfo.processInfo.environment["LANG"] == nil { environment["LANG"] = "en_US.UTF-8" }
        return environment
    }
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

    @MainActor
    static func inventory(workspaceRoots: [String], branchFromByRepository: [String: String] = [:], viewedChanges: [WorkspaceViewedChange] = []) async throws -> WorkspaceChangeInventory {
        let operationID = UUID().uuidString
        let startedAt = DispatchTime.now().uptimeNanoseconds
        PlayhouseDiagnostics.record("workspace.files.inventory.started", fields: [
            "operationID": operationID,
            "workspaceRoots": workspaceRoots.joined(separator: "\n"),
            "workspaceRootCount": String(workspaceRoots.count)
        ])
        do {
            let inventory = try await PlayhouseBackgroundOperation.run {
                try inventorySynchronously(workspaceRoots: workspaceRoots, branchFromByRepository: branchFromByRepository, viewedChanges: viewedChanges).changes
            }
            PlayhouseDiagnostics.record("workspace.files.inventory.succeeded", fields: [
                "operationID": operationID,
                "unviewedCount": String(inventory.unviewed.count),
                "viewedCount": String(inventory.viewed.count),
                "durationMilliseconds": String((DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000)
            ])
            return inventory
        } catch {
            var fields = PlayhouseDiagnostics.errorFields(error)
            fields["operationID"] = operationID
            fields["workspaceRoots"] = workspaceRoots.joined(separator: "\n")
            fields["durationMilliseconds"] = String((DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000)
            PlayhouseDiagnostics.record("workspace.files.inventory.failed", fields: fields)
            throw error
        }
    }

    @MainActor
    static func diff(
        workspaceRoots: [String],
        repositoryPath: String,
        relativePath: String,
        group: WorkspaceChangeGroup,
        branchFrom: String = "HEAD",
        viewedChanges: [WorkspaceViewedChange] = []
    ) async throws -> WorkspaceFileDiff {
        let operationID = UUID().uuidString
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let fields = [
            "operationID": operationID,
            "repositoryPath": repositoryPath,
            "path": relativePath,
            "group": group.rawValue,
            "workspaceRoots": workspaceRoots.joined(separator: "\n")
        ]
        PlayhouseDiagnostics.record("workspace.file.read.started", fields: fields)
        do {
            let diff = try await PlayhouseBackgroundOperation.run {
                try diffSynchronously(
                    workspaceRoots: workspaceRoots,
                    repositoryPath: repositoryPath,
                    relativePath: relativePath,
                    group: group,
                    branchFrom: branchFrom,
                    viewedChanges: viewedChanges
                )
            }
            PlayhouseDiagnostics.record("workspace.file.read.succeeded", fields: fields.merging([
                "originalBytes": String(diff.original?.utf8.count ?? 0),
                "modifiedBytes": String(diff.modified?.utf8.count ?? 0),
                "isText": String(diff.isText),
                "durationMilliseconds": String((DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000)
            ]) { _, new in new })
            return diff
        } catch {
            var failureFields = fields
            failureFields.merge(PlayhouseDiagnostics.errorFields(error)) { _, new in new }
            failureFields["durationMilliseconds"] = String((DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000)
            PlayhouseDiagnostics.record("workspace.file.read.failed", fields: failureFields)
            throw error
        }
    }

    @MainActor
    static func captureViewedChange(workspaceRoots: [String], repositoryPath: String, relativePath: String) async throws -> WorkspaceViewedChange {
        try await captureViewedChanges(workspaceRoots: workspaceRoots, files: [(repositoryPath, relativePath)])[0]
    }

    /// Snapshots and stages each file, reading the task's repositories once for the whole batch.
    @MainActor
    static func captureViewedChanges(workspaceRoots: [String], files: [(repository: String, path: String)]) async throws -> [WorkspaceViewedChange] {
        try await PlayhouseBackgroundOperation.run {
            guard files.allSatisfy({ isSafeRelativePath($0.path) }) else {
                throw BridgeCommandError(code: "invalid_argument", message: "The changed file path must be relative to its repository.")
            }
            let inventory = try inventorySynchronously(workspaceRoots: workspaceRoots)
            return try files.map { file in
                let repository = URL(fileURLWithPath: file.repository, isDirectory: true).standardizedFileURL
                guard inventory.repositories.contains(repository) else {
                    throw BridgeCommandError(code: "invalid_argument", message: "The repository isn't inside this task's working folders.")
                }
                let fileURL = repository.appendingPathComponent(file.path).standardizedFileURL
                let isPresent = FileManager.default.fileExists(atPath: fileURL.path)
                let contents = isPresent ? try worktreeBytes(repository: repository, path: file.path) : Data()
                try stageViewedChange(repository: repository, path: file.path)
                return WorkspaceViewedChange(repository: URL(fileURLWithPath: file.repository).standardizedFileURL.path, path: file.path, isPresent: isPresent, contents: contents)
            }
        }
    }

    /// Records the file in the Git index when it is marked viewed, so later edits to a formerly
    /// untracked file are reported as ordinary worktree changes against a staged baseline.
    /// A missing file is recorded as a deletion with `rm --cached`, which also accepts a deletion
    /// that is already staged; `add` rejects that path because it matches nothing left to add.
    private static func stageViewedChange(repository: URL, path: String) throws {
        // `attributesOfItem` doesn't follow symlinks, so a dangling link still counts as present.
        let isPresent = (try? FileManager.default.attributesOfItem(atPath: repository.appendingPathComponent(path).path)) != nil
        let arguments = isPresent
            ? ["add", "--all", "--", path]
            : ["rm", "--cached", "--ignore-unmatch", "--force", "--quiet", "--", path]
        let result = try runGit(repository: repository, arguments: arguments)
        guard result.status == 0 else {
            throw BridgeCommandError(
                code: "operation_failed",
                message: "Git couldn't stage \(path): \(result.error.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
        }
    }

    private static func inventorySynchronously(
        workspaceRoots: [String],
        branchFromByRepository: [String: String] = [:],
        viewedChanges: [WorkspaceViewedChange] = []
    ) throws -> RepositoryInventory {
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
        let repositories = repositoriesByPath.values.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        let snapshots = Dictionary(grouping: viewedChanges, by: \.repository).mapValues { Dictionary($0.map { ($0.path, $0) }) { _, latest in latest } }
        var unviewed: [WorkspaceChangeEntry] = []
        var viewed: [WorkspaceChangeEntry] = []
        for repository in repositories {
            let statusResult = try runGit(repository: repository, arguments: ["status", "--porcelain=v1", "-z", "--untracked-files=all"])
            guard statusResult.status == 0 else {
                throw BridgeCommandError(code: "operation_failed", message: "Git couldn't read changes in \(repository.path): \(statusResult.error.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            let statusRecords = try parseStatus(statusResult.output)
            // A path can appear twice when a staged deletion is followed by an untracked recreation;
            // the tracked record carries the meaningful index state, so it wins.
            let statusByPath = Dictionary(statusRecords.map { ($0.path, $0) }) { existing, candidate in
                existing.indexStatus == 63 && existing.worktreeStatus == 63 ? candidate : existing
            }
            let baseRef = try comparisonBase(repository: repository, branchFrom: branchFromByRepository[repository.path] ?? "HEAD")
            let mergeBaseResult = try runGit(repository: repository, arguments: ["merge-base", baseRef, "HEAD"])
            guard mergeBaseResult.status == 0, let mergeBase = String(data: mergeBaseResult.output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !mergeBase.isEmpty else {
                throw BridgeCommandError(code: "operation_failed", message: "Git couldn't find the common ancestor of \(baseRef) and the current branch in \(repository.path).")
            }
            let branchDiff = try runGit(repository: repository, arguments: ["diff", "--name-only", "-z", "--find-renames", mergeBase, "--"])
            guard branchDiff.status == 0 else {
                throw BridgeCommandError(code: "operation_failed", message: "Git couldn't compare the task branch with \(baseRef) in \(repository.path).")
            }
            let committedPaths = branchDiff.output.split(separator: 0).compactMap { String(data: Data($0), encoding: .utf8) }
            let viewedPaths = snapshots[repository.path].map { Array($0.keys) } ?? []
            let paths = Set(committedPaths + statusRecords.map(\.path) + viewedPaths)
            for path in paths.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
                let statusRecord = statusByPath[path]
                let isUntracked = statusRecord?.indexStatus == 63 && statusRecord?.worktreeStatus == 63
                let isUncommitted = statusRecord != nil
                let snapshot = snapshots[repository.path]?[path]
                let fileURL = repository.appendingPathComponent(path).standardizedFileURL
                let fileExists = FileManager.default.fileExists(atPath: fileURL.path)
                let code = statusRecord.map { String(decoding: [$0.indexStatus, $0.worktreeStatus], as: UTF8.self) } ?? "M "
                if let snapshot {
                    // The Viewed entry keeps showing what was already reviewed: branch base to snapshot.
                    let baseBytes = try gitBlob(repository: repository, revision: mergeBase, path: path, missingAllowed: true)
                    // A path with no content in the branch base, no current file, and a snapshot
                    // that already recorded its absence nets to zero change (for example a file
                    // created, later renamed away by a tool rather than `git mv`, and whose
                    // resulting deletion has itself since been reviewed). A stale snapshot like
                    // that is noise, not a change worth pinning; a deletion that hasn't been
                    // reviewed yet still needs to surface as a change to review.
                    guard baseBytes != nil || fileExists || snapshot.isPresent else { continue }
                    let viewedStatus: String
                    if !snapshot.isPresent { viewedStatus = "deleted" }
                    else if baseBytes == nil { viewedStatus = "added" }
                    else { viewedStatus = "modified" }
                    viewed.append(WorkspaceChangeEntry(
                        repository: repository.path,
                        path: path,
                        originalPath: statusRecord?.originalPath,
                        status: viewedStatus,
                        statusCode: porcelainCode(for: viewedStatus),
                        group: .viewed,
                        isUncommitted: isUncommitted,
                        hasViewedSnapshot: true
                    ))
                    // Anything done since then is listed separately, as a change still to review.
                    let currentBytes = fileExists ? try worktreeBytes(repository: repository, path: path) : Data()
                    guard snapshot.isPresent != fileExists || currentBytes != snapshot.contents else { continue }
                    let pendingStatus: String
                    if !fileExists { pendingStatus = "deleted" }
                    else if snapshot.isPresent { pendingStatus = "modified" }
                    else { pendingStatus = "added" }
                    unviewed.append(WorkspaceChangeEntry(
                        repository: repository.path,
                        path: path,
                        originalPath: statusRecord?.originalPath,
                        status: pendingStatus,
                        statusCode: porcelainCode(for: pendingStatus),
                        group: .unviewed,
                        isUncommitted: isUncommitted,
                        hasViewedSnapshot: true
                    ))
                    continue
                }
                let isBranchChange = committedPaths.contains(path)
                guard isBranchChange || isUncommitted else { continue }
                let status: String
                if isUntracked { status = "untracked" }
                else if !fileExists { status = "deleted" }
                else if let statusRecord {
                    let name = statusName(index: statusRecord.indexStatus, worktree: statusRecord.worktreeStatus)
                    // A staged deletion whose file was recreated still exists on disk.
                    status = name == "deleted" ? "modified" : name
                }
                else { status = "modified" }
                unviewed.append(WorkspaceChangeEntry(repository: repository.path, path: path, originalPath: statusRecord?.originalPath, status: status, statusCode: code, group: .unviewed, isUncommitted: isUncommitted, hasViewedSnapshot: false))
            }
        }
        func sort(_ entries: [WorkspaceChangeEntry]) -> [WorkspaceChangeEntry] {
            entries.sorted { $0.repository == $1.repository ? $0.path.localizedStandardCompare($1.path) == .orderedAscending : $0.repository.localizedStandardCompare($1.repository) == .orderedAscending }
        }
        return RepositoryInventory(repositories: repositories, changes: WorkspaceChangeInventory(unviewed: sort(unviewed), viewed: sort(viewed)))
    }

    private static func diffSynchronously(
        workspaceRoots: [String],
        repositoryPath: String,
        relativePath: String,
        group: WorkspaceChangeGroup,
        branchFrom: String = "HEAD",
        viewedChanges: [WorkspaceViewedChange] = []
    ) throws -> WorkspaceFileDiff {
        guard isSafeRelativePath(relativePath) else {
            throw BridgeCommandError(code: "invalid_argument", message: "The changed file path must be relative to its repository.")
        }
        let repository = URL(fileURLWithPath: repositoryPath, isDirectory: true).standardizedFileURL.path
        let inventory = try inventorySynchronously(workspaceRoots: workspaceRoots, branchFromByRepository: [repository: branchFrom], viewedChanges: viewedChanges)
        guard inventory.repositories.contains(where: { $0.path == repository }) else {
            throw BridgeCommandError(code: "invalid_argument", message: "The repository isn't inside this task's working folders.")
        }
        let entries = group == .viewed ? inventory.changes.viewed : inventory.changes.unviewed
        if entries.contains(where: { $0.repository == repository && $0.path == relativePath && $0.status == "conflict" }) {
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
        guard entries.contains(where: { $0.repository == repository && $0.path == relativePath }) else {
            throw BridgeCommandError(code: "not_found", message: "The file no longer has a \(group.displayName) change.")
        }
        let repositoryURL = URL(fileURLWithPath: repository, isDirectory: true)
        let snapshot = viewedChanges.first { $0.repository == repository && $0.path == relativePath }
        func branchBaseBytes() throws -> Data {
            let baseRef = try comparisonBase(repository: repositoryURL, branchFrom: branchFrom)
            let mergeBase = try runGit(repository: repositoryURL, arguments: ["merge-base", baseRef, "HEAD"])
            guard mergeBase.status == 0, let revision = String(data: mergeBase.output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                throw BridgeCommandError(code: "operation_failed", message: "Git couldn't find the branch comparison point.")
            }
            return try gitBlob(repository: repositoryURL, revision: revision, path: relativePath, missingAllowed: true) ?? Data()
        }
        let originalBytes: Data
        let modifiedBytes: Data
        if group == .viewed {
            // Viewed keeps showing the already-reviewed work: branch base to the saved snapshot.
            guard let snapshot else {
                throw BridgeCommandError(code: "not_found", message: "The viewed snapshot no longer exists.")
            }
            originalBytes = try branchBaseBytes()
            modifiedBytes = snapshot.isPresent ? snapshot.contents : Data()
        } else {
            let modifiedURL = repositoryURL.appendingPathComponent(relativePath).standardizedFileURL
            modifiedBytes = FileManager.default.fileExists(atPath: modifiedURL.path)
                ? try worktreeBytes(repository: repositoryURL, path: relativePath)
                : Data()
            if let snapshot {
                originalBytes = snapshot.isPresent ? snapshot.contents : Data()
            } else {
                originalBytes = try branchBaseBytes()
            }
        }
        guard let original = text(originalBytes), let modified = text(modifiedBytes) else {
            return WorkspaceFileDiff(repository: repository, path: relativePath, group: group, original: nil, modified: nil, isText: false, message: "This binary or non-UTF-8 file can't be shown as a text diff.")
        }
        return WorkspaceFileDiff(repository: repository, path: relativePath, group: group, original: original, modified: modified, isText: true, message: nil)
    }

    /// The ref a task's changes are measured against. A local branch such as `master` is rarely
    /// fetched, so when its remote-tracking counterpart is at or ahead of it, measure against that
    /// instead; otherwise every commit that landed upstream since the local branch was last
    /// updated shows up as the task's own change. A local branch that is ahead of or diverged from
    /// its remote holds work the task was started from, so it stays the base.
    private static func comparisonBase(repository: URL, branchFrom: String) throws -> String {
        let remoteRef = "refs/remotes/origin/\(branchFrom)"
        guard try runGit(repository: repository, arguments: ["rev-parse", "--verify", "--quiet", "\(remoteRef)^{commit}"]).status == 0,
              try runGit(repository: repository, arguments: ["merge-base", "--is-ancestor", branchFrom, remoteRef]).status == 0 else {
            return branchFrom
        }
        return remoteRef
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

    /// Snapshot-based rows are measured against a saved baseline rather than the index,
    /// so their badge comes from the row's own status instead of Git's porcelain code.
    private static func porcelainCode(for status: String) -> String {
        switch status {
        case "deleted": return "D "
        case "added": return "A "
        default: return "M "
        }
    }

    private static func statusName(index: UInt8, worktree: UInt8) -> String {
        if index == 85 || worktree == 85 || (index == 68 && worktree == 68) { return "conflict" }
        let status = worktree != 32 && worktree != 63 ? worktree : index
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
        let environmentPaths = (PlayhouseProcessEnvironment.current["PATH"] ?? "")
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

        var environment = PlayhouseProcessEnvironment.current
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
