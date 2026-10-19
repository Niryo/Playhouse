import AppKit
import Darwin
import Foundation
import SwiftUI

enum WorkspaceSettings {
    static let defaultParentFolderKey = "defaultWorkspaceParentFolderPath"
    static let lastSelectedRepositoriesKey = "lastSelectedRepositories"
    static let appearanceKey = "appearance"

    static var preferencesStore: UserDefaults {
        #if DEBUG
        if let suiteName = ProcessInfo.processInfo.environment["STATIONAI_E2E_DEFAULTS_SUITE"],
           let suite = UserDefaults(suiteName: suiteName) {
            return suite
        }
        #endif
        return .standard
    }

    static func validDirectoryURL(for path: String) -> URL? {
        guard !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return url
    }
}

enum WorkspaceTheme {
    static let windowBackground = adaptive(dark: (0x1E, 0x1E, 0x1E), light: .windowBackgroundColor)
    static let panelBackground = adaptive(dark: (0x25, 0x25, 0x26), light: .controlBackgroundColor)
    static let inputBackground = adaptive(dark: (0x3C, 0x3C, 0x3C), light: .textBackgroundColor)
    static let accent = Color(nsColor: NSColor(srgbRed: 0, green: 122.0 / 255.0, blue: 204.0 / 255.0, alpha: 1))

    private static func adaptive(dark: (UInt8, UInt8, UInt8), light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            guard appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua else { return light }
            return NSColor(
                srgbRed: CGFloat(dark.0) / 255,
                green: CGFloat(dark.1) / 255,
                blue: CGFloat(dark.2) / 255,
                alpha: 1
            )
        })
    }
}

struct CodexWorkspaceContext {
    let roots: [URL]

    var cwd: URL { roots[0] }

    init(roots: [URL]) throws {
        let normalized = roots.map(\.standardizedFileURL)
        guard !normalized.isEmpty else {
            throw WorkspaceError.noRoots
        }
        guard normalized.allSatisfy({ WorkspaceSettings.validDirectoryURL(for: $0.path) != nil }) else {
            throw WorkspaceError.unavailableRoot
        }
        self.roots = Array(NSOrderedSet(array: normalized.map(\.path))).compactMap {
            ($0 as? String).map { URL(fileURLWithPath: $0, isDirectory: true) }
        }
    }
}

enum WorkspaceError: LocalizedError {
    case noRoots
    case unavailableRoot

    var errorDescription: String? {
        switch self {
        case .noRoots:
            "Choose at least one working folder before sending a message."
        case .unavailableRoot:
            "One or more working folders are unavailable. Edit the task folders and try again."
        }
    }
}

struct CodexActivity: Codable, Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let status: String

    var statusLabel: String {
        switch status.lowercased() {
        case "completed": "Completed"
        case "failed": "Failed"
        case "interrupted": "Interrupted"
        case "inprogress", "running": "In progress"
        default: status
        }
    }

    static func from(item: [String: Any]) -> CodexActivity? {
        guard let id = item["id"] as? String, let type = item["type"] as? String else { return nil }
        let status = item["status"] as? String ?? "inProgress"
        switch type {
        case "commandExecution":
            let command = item["command"] as? String ?? (item["command"] as? [String])?.joined(separator: " ") ?? ""
            let cwd = item["cwd"] as? String
            let output = item["aggregatedOutput"] as? String
            let detail = [cwd.map { "in \($0)" }, output.map { String($0.suffix(2_000)) }]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            return CodexActivity(
                id: id,
                title: command.isEmpty ? "Running command" : "Running \(command)",
                detail: detail,
                status: status
            )
        case "fileChange":
            let changes = item["changes"] as? [[String: Any]] ?? []
            let paths = changes.compactMap { $0["path"] as? String }
            return CodexActivity(
                id: id,
                title: paths.isEmpty ? "Editing files" : "Editing \(paths.count) \(paths.count == 1 ? "file" : "files")",
                detail: paths.joined(separator: ", "),
                status: status
            )
        case "webSearch":
            return CodexActivity(id: id, title: "Searching the web", detail: item["query"] as? String ?? "", status: status)
        case "imageView":
            return CodexActivity(id: id, title: "Viewing image", detail: item["path"] as? String ?? "", status: status)
        case "collabAgentToolCall":
            guard item["tool"] as? String == "spawnAgent" else { return nil }
            let prompt = item["prompt"] as? String ?? ""
            let agentStates = item["agentsStates"] as? [String: [String: Any]] ?? [:]
            let stateDetails = agentStates.values.compactMap { state -> String? in
                guard let agentStatus = state["status"] as? String else { return nil }
                let message = state["message"] as? String
                return [agentStatus, message].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ": ")
            }
            let detail = ([prompt] + stateDetails).filter { !$0.isEmpty }.joined(separator: "\n")
            return CodexActivity(id: id, title: "Task delegated to subagent", detail: detail, status: status)
        default:
            return nil
        }
    }
}

struct CodexTurnDiff: Codable, Equatable {
    let unifiedDiff: String

    private struct FileChunk {
        let path: String
        let text: String
    }

    var changedFiles: [String] {
        var paths: [String] = []
        for line in unifiedDiff.split(separator: "\n", omittingEmptySubsequences: false) {
            guard line.hasPrefix("+++ b/") else { continue }
            let path = String(line.dropFirst(6))
            if path != "/dev/null", !paths.contains(path) { paths.append(path) }
        }
        return paths
    }

    func merging(_ update: CodexTurnDiff) -> CodexTurnDiff {
        var chunks = fileChunks()
        for updateChunk in update.fileChunks() {
            if let index = chunks.firstIndex(where: { $0.path == updateChunk.path }) {
                chunks[index] = updateChunk
            } else {
                chunks.append(updateChunk)
            }
        }
        guard !chunks.isEmpty else { return CodexTurnDiff(unifiedDiff: update.unifiedDiff) }
        return CodexTurnDiff(unifiedDiff: chunks.map(\.text).joined(separator: "\n"))
    }

    private func fileChunks() -> [FileChunk] {
        let lines = unifiedDiff.components(separatedBy: "\n")
        var chunks: [FileChunk] = []
        var chunkStart = 0
        var currentPath: String?

        func appendCurrentChunk(endingAt end: Int) {
            guard let path = currentPath else {
                chunkStart = end
                return
            }
            let text = lines[chunkStart..<end].joined(separator: "\n")
            chunks.append(FileChunk(path: path, text: text))
            chunkStart = end
            currentPath = nil
        }

        for index in lines.indices {
            let line = lines[index]
            if line.hasPrefix("diff --git "), index > chunkStart {
                appendCurrentChunk(endingAt: index)
            } else if line.hasPrefix("--- a/"), currentPath != nil {
                appendCurrentChunk(endingAt: index)
            }

            if line.hasPrefix("+++ b/") {
                currentPath = String(line.dropFirst(6))
            } else if line.hasPrefix("--- a/"), currentPath == nil {
                currentPath = String(line.dropFirst(6))
            }
        }
        appendCurrentChunk(endingAt: lines.count)
        return chunks
    }

    static func fromFileChangeItems(_ items: [[String: Any]]) -> CodexTurnDiff? {
        var chunks: [String] = []
        for item in items where item["type"] as? String == "fileChange" {
            let changes = item["changes"] as? [[String: Any]] ?? []
            for change in changes {
                guard let path = change["path"] as? String,
                      let diff = change["diff"] as? String, !diff.isEmpty else { continue }
                chunks.append("--- a/\(path)\n+++ b/\(path)\n\(diff)")
            }
        }
        guard !chunks.isEmpty else { return nil }
        return CodexTurnDiff(unifiedDiff: chunks.joined(separator: "\n"))
    }
}

struct CodexThreadHistory: Codable, Equatable {
    let messages: [CodexChatMessage]
    let activities: [CodexActivity]
    let diff: CodexTurnDiff?
}

enum RepositoryScanner {
    static func scan(parent: URL) async -> [URL] {
        await Task.detached(priority: .utility) {
            scanSynchronously(parent: parent)
        }.value
    }

    static func scanSynchronously(parent: URL) -> [URL] {
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

enum StationAIWorktreeManager {
    static func defaultRoot() -> URL {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["STATIONAI_E2E_WORKTREE_DIRECTORY"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
        }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".stationAI/worktrees", isDirectory: true)
            .standardizedFileURL
    }

    static func branchSlug(_ title: String) -> String {
        let lower = title.lowercased()
        var result = ""
        var needsSeparator = false
        for scalar in lower.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if needsSeparator, !result.isEmpty { result.append("-") }
                result.unicodeScalars.append(scalar)
                needsSeparator = false
            } else {
                needsSeparator = true
            }
        }
        return result.isEmpty ? "task" : result
    }

    static func branchTitle(_ branch: String) -> String {
        branch
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    static func repositoryRoot(_ path: String) throws -> String {
        let result = try git(path, ["rev-parse", "--show-toplevel"]).output
        return URL(fileURLWithPath: result.trimmingCharacters(in: .whitespacesAndNewlines), isDirectory: true)
            .standardizedFileURL.path
    }

    static func defaultBranchFrom(repositoryPath: String) throws -> String {
        let repository = try repositoryRoot(repositoryPath)
        return try resolveBase(repository: repository, requested: nil)
    }

    static func defaultLocalBranch(repositoryPath: String) throws -> String {
        let repository = try repositoryRoot(repositoryPath)
        if let remoteHead = try? git(repository, ["symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"]).output
            .trimmingCharacters(in: .whitespacesAndNewlines) {
            let candidate = remoteHead.replacingOccurrences(of: "refs/remotes/origin/", with: "")
            if try git(repository, ["show-ref", "--verify", "--quiet", "refs/heads/\(candidate)"], allowFailure: true).status == 0 {
                return candidate
            }
        }
        for candidate in ["main", "master"] {
            if try git(repository, ["show-ref", "--verify", "--quiet", "refs/heads/\(candidate)"], allowFailure: true).status == 0 {
                return candidate
            }
        }
        let current = try git(repository, ["branch", "--show-current"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty else {
            throw BridgeCommandError(code: "operation_failed", message: "Choose a local branch as the merge target for \(repository).")
        }
        return current
    }

    static func resolve(spec: RepositoryWorktreeSpec, title: String, root: URL) throws -> RepositoryWorktreeRecord {
        let repository = try repositoryRoot(spec.repositoryPath)
        let branch = (spec.branch?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? spec.branch!.trimmingCharacters(in: .whitespacesAndNewlines)
            : branchSlug(title)
        guard !branch.hasPrefix("-") else {
            throw BridgeCommandError(code: "invalid_argument", message: "Branch names can't begin with a hyphen.")
        }
        let branchCheck = try git(repository, ["check-ref-format", "--branch", branch], allowFailure: true)
        guard branchCheck.status == 0 else {
            throw BridgeCommandError(code: "invalid_argument", message: "'(branch)' isn't a valid Git branch name.")
        }
        let branchFrom = try resolveBase(repository: repository, requested: spec.branchFrom)
        let mergeTarget = try resolveMergeTarget(repository: repository, requested: spec.mergeTarget)
        guard branch != mergeTarget else {
            throw BridgeCommandError(code: "invalid_argument", message: "A task branch can't also be its merge target: \(branch).")
        }
        let existing = try worktrees(repository: repository)
        if let path = existing.first(where: { $0.branch == branch })?.path {
            return RepositoryWorktreeRecord(repositoryPath: repository, branch: branch, worktreePath: path, branchFrom: branchFrom, createdByStationAI: false, mergeTarget: mergeTarget)
        }
        let branchExists = try git(repository, ["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"], allowFailure: true).status == 0
        let destination = managedPath(root: root, repository: repository, branch: branch)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw BridgeCommandError(code: "operation_failed", message: "The worktree destination already exists: \(destination.path)")
        }
        if branchExists {
            _ = try git(repository, ["worktree", "add", destination.path, branch])
        } else {
            _ = try git(repository, ["worktree", "add", "-b", branch, destination.path, branchFrom])
        }
        return RepositoryWorktreeRecord(repositoryPath: repository, branch: branch, worktreePath: destination.path, branchFrom: branchFrom, createdByStationAI: true, mergeTarget: mergeTarget)
    }

    static func pendingRecord(spec: RepositoryWorktreeSpec) throws -> RepositoryWorktreeRecord {
        let repository = try repositoryRoot(spec.repositoryPath)
        let branchFrom = try resolveBase(repository: repository, requested: spec.branchFrom)
        let mergeTarget = try resolveMergeTarget(repository: repository, requested: spec.mergeTarget)
        let branch = spec.branch?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let branch, !branch.isEmpty {
            guard !branch.hasPrefix("-"), try git(repository, ["check-ref-format", "--branch", branch], allowFailure: true).status == 0 else {
                throw BridgeCommandError(code: "invalid_argument", message: "'(branch)' isn't a valid Git branch name.")
            }
            guard branch != mergeTarget else {
                throw BridgeCommandError(code: "invalid_argument", message: "A task branch can't also be its merge target: \(branch).")
            }
        }
        return RepositoryWorktreeRecord(
            repositoryPath: repository,
            branch: branch.flatMap { $0.isEmpty ? nil : $0 } ?? "auto",
            worktreePath: repository,
            branchFrom: branchFrom,
            createdByStationAI: false,
            mergeTarget: mergeTarget,
            isPending: true
        )
    }

    static func preflightMerge(_ record: RepositoryWorktreeRecord) throws -> Bool {
        try preflightRemoval(record)
        guard let target = record.mergeTarget,
              try git(record.repositoryPath, ["check-ref-format", "--branch", target], allowFailure: true).status == 0,
              try git(record.repositoryPath, ["show-ref", "--verify", "--quiet", "refs/heads/\(target)"], allowFailure: true).status == 0 else {
            throw BridgeCommandError(code: "operation_failed", message: "The merge target for \(URL(fileURLWithPath: record.repositoryPath).lastPathComponent) isn't an available local branch.")
        }
        guard target != record.branch else {
            throw BridgeCommandError(code: "operation_failed", message: "The task branch and merge target are both '\(target)'.")
        }
        let targetWorktrees = try worktrees(repository: record.repositoryPath).filter { $0.branch == target }
        if let targetWorktree = targetWorktrees.first {
            guard URL(fileURLWithPath: targetWorktree.path).standardizedFileURL == URL(fileURLWithPath: record.repositoryPath).standardizedFileURL else {
                throw BridgeCommandError(code: "operation_failed", message: "The merge target '\(target)' is checked out in another worktree: \(targetWorktree.path).")
            }
            let targetStatus = try git(targetWorktree.path, ["status", "--porcelain", "--untracked-files=all"]).output
            guard targetStatus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw BridgeCommandError(code: "operation_failed", message: "The merge target '\(target)' has uncommitted changes in \(targetWorktree.path).")
            }
        }
        let mergeTree = try git(record.repositoryPath, ["merge-tree", "--write-tree", target, record.branch], allowFailure: true)
        if mergeTree.status == 0 { return false }
        if mergeTree.output.contains("CONFLICT") || mergeTree.output.contains("changed in both") { return true }
        throw BridgeCommandError(code: "operation_failed", message: "Couldn't check whether '\(record.branch)' can merge into '\(target)': \(mergeTree.output.trimmingCharacters(in: .whitespacesAndNewlines))")
    }

    static func beginConflictResolution(_ record: RepositoryWorktreeRecord) throws {
        guard let target = record.mergeTarget else {
            throw BridgeCommandError(code: "operation_failed", message: "This task has no merge target branch.")
        }
        let result = try git(record.worktreePath, ["merge", "--no-commit", "--no-ff", target], allowFailure: true)
        guard result.status != 0 else {
            throw BridgeCommandError(code: "operation_failed", message: "The merge changed while preparing conflict resolution. Try moving the task to Done again.")
        }
        let unmerged = try git(record.worktreePath, ["ls-files", "-u"]).output
        guard !unmerged.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            _ = try? git(record.worktreePath, ["merge", "--abort"])
            throw BridgeCommandError(code: "operation_failed", message: result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    static func finishConflictResolution(_ record: RepositoryWorktreeRecord) throws {
        guard FileManager.default.fileExists(atPath: URL(fileURLWithPath: record.worktreePath).appendingPathComponent(".git").path) else {
            throw BridgeCommandError(code: "operation_failed", message: "The conflict-resolution worktree is unavailable: \(record.worktreePath)")
        }
        let unmerged = try git(record.worktreePath, ["ls-files", "-u"]).output
        guard unmerged.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BridgeCommandError(code: "operation_failed", message: "Codex finished with unresolved merge conflicts in \(record.worktreePath).")
        }
        let mergeHead = try git(record.worktreePath, ["rev-parse", "--verify", "--quiet", "MERGE_HEAD"], allowFailure: true)
        guard mergeHead.status == 0 else { return }
        _ = try git(record.worktreePath, ["add", "-A"])
        _ = try git(record.worktreePath, ["commit", "--no-edit"])
    }

    static func mergeIntoTarget(_ record: RepositoryWorktreeRecord) throws {
        guard let target = record.mergeTarget else {
            throw BridgeCommandError(code: "operation_failed", message: "This task has no merge target branch.")
        }
        let currentBranch = try git(record.repositoryPath, ["branch", "--show-current"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetWorktree: String
        var temporaryWorktree: String?
        if currentBranch == target {
            targetWorktree = record.repositoryPath
        } else {
            let worktrees = try worktrees(repository: record.repositoryPath)
            guard !worktrees.contains(where: { $0.branch == target }) else {
                throw BridgeCommandError(code: "operation_failed", message: "The merge target '\(target)' is checked out in another worktree.")
            }
            let tempPath = URL(fileURLWithPath: record.worktreePath)
                .deletingLastPathComponent()
                .appendingPathComponent("merge-\(UUID().uuidString)", isDirectory: true).path
            _ = try git(record.repositoryPath, ["worktree", "add", tempPath, target])
            targetWorktree = tempPath
            temporaryWorktree = tempPath
        }
        defer {
            if let temporaryWorktree {
                _ = try? git(record.repositoryPath, ["worktree", "remove", "--force", temporaryWorktree])
            }
        }
        let status = try git(targetWorktree, ["status", "--porcelain", "--untracked-files=all"]).output
        guard status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BridgeCommandError(code: "operation_failed", message: "The merge target '\(target)' has uncommitted changes in \(targetWorktree).")
        }
        let ancestry = try git(targetWorktree, ["merge-base", "--is-ancestor", record.branch, target], allowFailure: true)
        guard ancestry.status == 0 || ancestry.status == 1 else {
            throw BridgeCommandError(code: "operation_failed", message: "Couldn't check whether task branch '\(record.branch)' is already contained in merge target '\(target)': \(ancestry.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        guard ancestry.status != 0 else { return }
        let changes = try git(targetWorktree, ["diff", "--quiet", target, record.branch], allowFailure: true)
        guard changes.status == 0 || changes.status == 1 else {
            throw BridgeCommandError(code: "operation_failed", message: "Couldn't compare task branch '\(record.branch)' with merge target '\(target)': \(changes.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        guard changes.status != 0 else { return }
        let targetHead = try git(targetWorktree, ["rev-parse", "HEAD"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try git(targetWorktree, ["merge", "--squash", record.branch])
            _ = try git(targetWorktree, ["commit", "-m", branchTitle(record.branch)])
        } catch {
            let currentHead = try? git(targetWorktree, ["rev-parse", "HEAD"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
            if currentHead == targetHead {
                _ = try? git(targetWorktree, ["reset", "--hard", targetHead])
            }
            throw BridgeCommandError(code: "operation_failed", message: "Squash merge failed: \(error.localizedDescription)")
        }
    }

    static func preflightRemoval(_ record: RepositoryWorktreeRecord) throws {
        let status = try git(record.worktreePath, ["status", "--porcelain", "--untracked-files=all"]).output
        guard status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BridgeCommandError(code: "operation_failed", message: "Can't mark this task Done because its worktree has uncommitted changes: \(record.worktreePath)")
        }
    }

    static func commitChanges(_ record: RepositoryWorktreeRecord, message: String) throws {
        let status = try git(record.worktreePath, ["status", "--porcelain", "--untracked-files=all"]).output
        guard !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        _ = try git(record.worktreePath, ["add", "-A"])
        _ = try git(record.worktreePath, ["commit", "-m", message])
    }

    static func hasChanges(_ record: RepositoryWorktreeRecord) throws -> Bool {
        let status = try git(record.worktreePath, ["status", "--porcelain", "--untracked-files=all"]).output
        return !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func removeAfterConfirmation(_ record: RepositoryWorktreeRecord) throws {
        guard record.createdByStationAI,
              FileManager.default.fileExists(atPath: record.worktreePath) else { return }
        _ = try git(record.repositoryPath, ["worktree", "remove", "--force", record.worktreePath])
    }

    static func remove(_ record: RepositoryWorktreeRecord) throws {
        try preflightRemoval(record)
        _ = try git(record.repositoryPath, ["worktree", "remove", record.worktreePath])
    }

    private struct ExistingWorktree { let path: String; let branch: String? }

    private static func worktrees(repository: String) throws -> [ExistingWorktree] {
        let output = try git(repository, ["worktree", "list", "--porcelain"]).output
        var result: [ExistingWorktree] = []
        var path: String?
        var branch: String?
        func flush() {
            if let path { result.append(ExistingWorktree(path: URL(fileURLWithPath: path).standardizedFileURL.path, branch: branch?.replacingOccurrences(of: "refs/heads/", with: ""))) }
            path = nil
            branch = nil
        }
        for line in output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.isEmpty { flush() }
            else if line.hasPrefix("worktree ") { path = String(line.dropFirst(9)) }
            else if line.hasPrefix("branch ") { branch = String(line.dropFirst(7)) }
        }
        flush()
        return result
    }

    private static func resolveBase(repository: String, requested: String?) throws -> String {
        if let requested, !requested.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let base = requested.trimmingCharacters(in: .whitespacesAndNewlines)
            guard try git(repository, ["rev-parse", "--verify", "--quiet", "\(base)^{commit}"], allowFailure: true).status == 0 else {
                throw BridgeCommandError(code: "invalid_argument", message: "Branch-from '(base)' doesn't exist in \(repository).")
            }
            return base
        }
        if try git(repository, ["show-ref", "--verify", "--quiet", "refs/heads/master"], allowFailure: true).status == 0 { return "master" }
        if let remoteHead = try? git(repository, ["symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"]).output
            .trimmingCharacters(in: .whitespacesAndNewlines), !remoteHead.isEmpty {
            return remoteHead.replacingOccurrences(of: "refs/remotes/origin/", with: "")
        }
        return try git(repository, ["branch", "--show-current"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func resolveMergeTarget(repository: String, requested: String?) throws -> String {
        let candidate = (requested?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? requested!.trimmingCharacters(in: .whitespacesAndNewlines)
            : try defaultLocalBranch(repositoryPath: repository)
        guard !candidate.hasPrefix("-") else {
            throw BridgeCommandError(code: "invalid_argument", message: "Merge target names can't begin with a hyphen.")
        }
        guard try git(repository, ["check-ref-format", "--branch", candidate], allowFailure: true).status == 0,
              try git(repository, ["show-ref", "--verify", "--quiet", "refs/heads/\(candidate)"], allowFailure: true).status == 0 else {
            throw BridgeCommandError(code: "invalid_argument", message: "Merge target '\(candidate)' must name an existing local branch.")
        }
        return candidate
    }

    private static func managedPath(root: URL, repository: String, branch: String) -> URL {
        let name = URL(fileURLWithPath: repository).lastPathComponent
        var hash: UInt64 = 14695981039346656037
        for byte in repository.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        let branchToken = branch.utf8.map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent("\(name)-\(String(hash, radix: 16))", isDirectory: true)
            .appendingPathComponent(branchToken, isDirectory: true)
    }

    private struct GitResult { let status: Int32; let output: String }

    private static func git(_ path: String, _ arguments: [String], allowFailure: Bool = false) throws -> GitResult {
        let candidates = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map {
            URL(fileURLWithPath: String($0)).appendingPathComponent("git").path
        } + ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"]
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw BridgeCommandError(code: "operation_failed", message: "Git couldn't be found. Install Git and try again.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-C", path] + arguments
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        let out = output.fileHandleForReading.readDataToEndOfFile()
        let err = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: out, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 || allowFailure else {
            let detail = String(data: err, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw BridgeCommandError(code: "operation_failed", message: detail.isEmpty ? "Git command failed." : detail)
        }
        return GitResult(status: process.terminationStatus, output: text)
    }
}

struct WorkspaceRootSelector: View {
    let parentFolderURL: URL?
    @Binding var roots: [URL]
    var displayNames: [String: String] = [:]
    @State private var repositories: [URL] = []
    @State private var searchText = ""
    @State private var isScanning = false

    private var filteredRepositories: [URL] {
        let available = repositories.filter { candidate in
            !roots.contains(where: { $0.standardizedFileURL.path == candidate.standardizedFileURL.path })
        }
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return available }
        let query = searchText.lowercased()
        return available.filter {
            $0.lastPathComponent.lowercased().contains(query) || $0.path.lowercased().contains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Working folders")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: browseForFolders) {
                    Label("Browse…", systemImage: "folder")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("browse-workspace-roots-button")
            }

            if roots.isEmpty {
                Text("Choose one or more folders. Git repositories under your parent folder appear as suggestions.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                FlowLayout(spacing: 7) {
                    ForEach(roots, id: \.standardizedFileURL.path) { root in
                        HStack(spacing: 5) {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 10))
                            Text(displayNames[root.standardizedFileURL.path] ?? (root.lastPathComponent.isEmpty ? root.path : root.lastPathComponent))
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                            Button {
                                roots.removeAll { $0.standardizedFileURL.path == root.standardizedFileURL.path }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                            .help("Remove \(displayNames[root.standardizedFileURL.path] ?? root.path)")
                            .accessibilityLabel("Remove \(displayNames[root.standardizedFileURL.path] ?? root.lastPathComponent)")
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.accentColor.opacity(0.1), in: Capsule())
                    }
                }
            }

            TextField("Search suggested repositories…", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("workspace-repository-search")

            if isScanning {
                ProgressView("Finding Git repositories…")
                    .controlSize(.small)
                    .font(.system(size: 11))
            } else if filteredRepositories.isEmpty {
                Text(parentFolderURL == nil ? "Choose a default parent folder in Settings to see repository suggestions." : "No matching repositories. Browse to add any folder.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(filteredRepositories, id: \.path) { repository in
                            Button {
                                add(repository)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(repository.lastPathComponent)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.primary)
                                    Text(repository.path)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 7)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("repository-suggestion-\(repository.lastPathComponent)")
                        }
                    }
                }
                .frame(maxHeight: 142)
                .background(WorkspaceTheme.panelBackground.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .task(id: parentFolderURL?.path) {
            guard let parentFolderURL else {
                repositories = []
                return
            }
            isScanning = true
            repositories = (try? await WorkspaceManager().suggestedRepositories(parentPath: parentFolderURL.path).map {
                URL(fileURLWithPath: $0, isDirectory: true)
            }) ?? []
            isScanning = false
        }
    }

    private func add(_ url: URL) {
        let path = url.standardizedFileURL.path
        guard !roots.contains(where: { $0.standardizedFileURL.path == path }) else { return }
        roots.append(URL(fileURLWithPath: path, isDirectory: true))
    }

    private func browseForFolders() {
        let panel = NSOpenPanel()
        panel.title = "Choose working folders"
        panel.message = "Choose one or more folders Codex should use as task context."
        panel.prompt = "Add Folders"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = parentFolderURL
        panel.begin { response in
            guard response == .OK else { return }
            DispatchQueue.main.async {
                panel.urls.forEach(add)
            }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += (x > 0 ? spacing : 0) + size.width
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(maxWidth, x), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

struct WorkspaceSettingsView: View {
    @AppStorage(WorkspaceSettings.defaultParentFolderKey, store: WorkspaceSettings.preferencesStore) private var defaultParentFolderPath = ""
    @AppStorage(WorkspaceSettings.appearanceKey, store: WorkspaceSettings.preferencesStore) private var appearance = "dark"
    @State private var pickerError: String?

    private var parentFolderURL: URL? {
        WorkspaceSettings.validDirectoryURL(for: defaultParentFolderPath)
    }

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    Text("Dark").tag("dark")
                    Text("Light").tag("light")
                }
                .accessibilityIdentifier("appearance-picker")
            }
            Section("Workspace suggestions") {
                Text("Choose a parent folder. New tasks will search below it for Git repositories to suggest as working folders.")
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    Text(parentFolderURL?.path ?? "No default parent folder selected")
                        .lineLimit(2)
                        .textSelection(.enabled)
                        .accessibilityLabel(parentFolderURL?.path ?? "No default parent folder selected")
                        .accessibilityIdentifier("default-parent-folder-path")
                    Spacer()
                    Button(parentFolderURL == nil ? "Choose…" : "Change…", action: chooseParentFolder)
                        .accessibilityIdentifier("choose-default-parent-folder-button")
                    if parentFolderURL != nil {
                        Button("Clear") {
                            do {
                                try WorkspaceSettingsManager().setDefaultParentFolder(nil)
                                defaultParentFolderPath = ""
                            } catch {
                                pickerError = error.localizedDescription
                            }
                        }
                        .accessibilityIdentifier("clear-default-parent-folder-button")
                    }
                }
                if !defaultParentFolderPath.isEmpty && parentFolderURL == nil {
                    Label("This folder is unavailable. Choose another parent folder.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            Section {
                Text("Changing this setting affects suggestions for new tasks. It does not change the working folders saved on existing tasks.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 320)
        .preferredColorScheme(appearance == "light" ? .light : .dark)
        .alert("Couldn't choose folder", isPresented: Binding(
            get: { pickerError != nil },
            set: { if !$0 { pickerError = nil } }
        )) {
            Button("OK", role: .cancel) { pickerError = nil }
        } message: {
            Text(pickerError ?? "Please try again.")
        }
    }

    private func chooseParentFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose default parent folder"
        panel.message = "StationAI will suggest Git repositories found under this folder."
        panel.prompt = "Use This Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = parentFolderURL ?? FileManager.default.homeDirectoryForCurrentUser
        panel.begin { response in
            guard response == .OK, let selected = panel.url else { return }
            DispatchQueue.main.async {
                let path = selected.standardizedFileURL.path
                do {
                    try WorkspaceSettingsManager().setDefaultParentFolder(path)
                    defaultParentFolderPath = path
                } catch {
                    pickerError = error.localizedDescription
                }
            }
        }
    }
}

@MainActor
enum StationAIDiagnostics {
    private static var directoryOverride: URL?

    static func useDataDirectory(_ path: String?) {
        directoryOverride = path.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static var logURL: URL {
        let directory: URL
        if let directoryOverride {
            directory = directoryOverride
        } else if let dataDirectory = ProcessInfo.processInfo.environment["STATIONAI_DATA_DIRECTORY"] {
            directory = URL(fileURLWithPath: dataDirectory, isDirectory: true)
        } else if let supportDirectory = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            directory = supportDirectory.appendingPathComponent("StationAI", isDirectory: true)
        } else {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("StationAI", isDirectory: true)
        }
        return directory.appendingPathComponent("Diagnostics.jsonl")
    }

    static var storeURL: URL {
        logURL.deletingLastPathComponent().appendingPathComponent("StationAI.store")
    }

    static func record(_ event: String, fields: [String: String] = [:]) {
        var entry = fields
        entry["timestamp"] = ISO8601DateFormatter().string(from: Date())
        entry["event"] = event
        entry["process"] = ProcessInfo.processInfo.processName
        entry["processID"] = String(ProcessInfo.processInfo.processIdentifier)
        guard var data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        data.append(0x0A)

        let url = logURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let descriptor = open(url.path, O_WRONLY | O_CREAT | O_APPEND, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { close(descriptor) }
            let written = data.withUnsafeBytes { buffer in
                Darwin.write(descriptor, buffer.baseAddress, buffer.count)
            }
            guard written == data.count else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            NSLog("StationAI couldn't write diagnostics: %@", error.localizedDescription)
        }
    }

    static func errorFields(_ error: Error, redacting sensitiveValues: [String] = []) -> [String: String] {
        let values = sensitiveValues.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        func sanitized(_ value: String?) -> String? {
            guard var value else { return nil }
            for sensitiveValue in values {
                value = value.replacingOccurrences(of: sensitiveValue, with: "[redacted]", options: [.caseInsensitive])
            }
            return value
        }

        var fields: [String: String] = [:]
        fields["errorDescription"] = sanitized(error.localizedDescription)
        var underlying: NSError? = error as NSError
        var depth = 0
        while let current = underlying, depth < 5 {
            let prefix = "error\(depth)"
            fields["\(prefix)Domain"] = current.domain
            fields["\(prefix)Code"] = String(current.code)
            if let reason = sanitized(current.localizedFailureReason) { fields["\(prefix)Reason"] = reason }
            underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return fields
    }
}
