import AppKit
import Darwin
import Foundation
import OSLog
import SwiftUI

private struct ButtonHoverPointer: ViewModifier {
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .onHover { isInside in
                guard isInside != isHovering else { return }
                isHovering = isInside
                if isInside {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
            .onDisappear {
                if isHovering {
                    NSCursor.pop()
                    isHovering = false
                }
            }
    }
}

extension View {
    func buttonHoverPointer() -> some View {
        modifier(ButtonHoverPointer())
    }
}

private struct ActionButtonHoverEmphasis: ViewModifier {
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .padding(4)
            .background {
                Capsule()
                    .fill(Color.accentColor.opacity(isHovering ? 0.14 : 0))
            }
            .scaleEffect(isHovering ? 1.06 : 1)
            .animation(.easeOut(duration: 0.14), value: isHovering)
            .onHover { isHovering = $0 }
    }
}

extension View {
    func actionButtonHoverEmphasis() -> some View {
        modifier(ActionButtonHoverEmphasis())
    }
}

enum WorkspaceSettings {
    static let defaultParentFolderKey = "defaultWorkspaceParentFolderPath"
    static let lastSelectedRepositoriesKey = "lastSelectedRepositories"
    static let appearanceKey = "appearance"
    static let pullRequestConflictActionKey = "pullRequestConflictAction"

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
    static let conversationText = adaptive(dark: (0xC5, 0xC5, 0xC5), light: .labelColor)
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
    var childThreadID: String? = nil
    var agentPath: String? = nil
    var model: String? = nil
    var reasoningEffort: String? = nil

    var isSubagent: Bool { childThreadID != nil }

    var statusLabel: String {
        switch status.lowercased() {
        case "completed": "Completed"
        case "failed": "Failed"
        case "interrupted": "Interrupted"
        case "inprogress", "running": "In progress"
        default: status
        }
    }

    var timelineStatus: String {
        switch status.lowercased() {
        case "inprogress", "running": "started working"
        case "completed": "finished working"
        case "interrupted": "was interrupted"
        case "failed": "failed"
        default: "working · \(statusLabel.lowercased())"
        }
    }

    static func from(item: [String: Any]) -> CodexActivity? {
        guard let id = item["id"] as? String, let type = item["type"] as? String else { return nil }
        let status = item["status"] as? String ?? "inProgress"
        switch type {
        case "subAgentActivity":
            guard let childThreadID = item["agentThreadId"] as? String else { return nil }
            let kind = item["kind"] as? String ?? "unknown"
            let status: String
            switch kind.lowercased() {
            case "started", "interacted": status = "inProgress"
            case "completed": status = "completed"
            case "interrupted": status = "interrupted"
            default: status = kind
            }
            let path = item["agentPath"] as? String ?? "Subagent"
            let pathName = path.split(separator: "/").last.map(String.init) ?? path
            let spacedName = pathName.replacingOccurrences(of: "_", with: " ")
            let name = spacedName.prefix(1).uppercased() + spacedName.dropFirst()
            let metadata = [item["model"] as? String, item["reasoningEffort"] as? String]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            return CodexActivity(
                id: childThreadID,
                title: name.isEmpty ? "Subagent" : name,
                detail: [path, metadata].filter { !$0.isEmpty }.joined(separator: "\n"),
                status: status,
                childThreadID: childThreadID,
                agentPath: path,
                model: item["model"] as? String,
                reasoningEffort: item["reasoningEffort"] as? String
            )
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

enum StationAIAppIdentity {
    static var applicationIdentifier: String {
        Bundle.main.infoDictionary?["StationAIApplicationBundleIdentifier"] as? String
            ?? Bundle.main.bundleIdentifier ?? ""
    }

    static var isTestBundle: Bool {
        #if DEBUG
        return applicationIdentifier.contains(".e2e.")
        #else
        return false
        #endif
    }

    static var worktreeKey: String? {
        let prefix = "com.stationai.app.worktree."
        guard applicationIdentifier.hasPrefix(prefix) else { return nil }
        let remainder = String(applicationIdentifier.dropFirst(prefix.count))
        let key = String(remainder.prefix(17))
        guard key.count == 17, key.first == "w",
              key.dropFirst().allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
        let suffix = remainder.dropFirst(key.count)
        guard suffix.isEmpty || (isTestBundle && suffix.hasPrefix(".e2e.")) else { return nil }
        return key
    }

    static func defaultDataDirectory() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("StationAI", isDirectory: true)
        guard let worktreeKey else { return support }
        return support.appendingPathComponent("Worktrees", isDirectory: true)
            .appendingPathComponent(worktreeKey, isDirectory: true)
    }
}

enum StationAIWorktreeManager {
    static func defaultRoot() -> URL {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["STATIONAI_E2E_WORKTREE_DIRECTORY"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
        }
        #endif
        var root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".stationAI/worktrees", isDirectory: true)
        if let key = StationAIAppIdentity.worktreeKey {
            root.appendPathComponent(key, isDirectory: true)
        }
        return root.standardizedFileURL
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
        return try defaultBranches(repository: repository).branchFrom
    }

    static func defaultLocalBranch(repositoryPath: String) throws -> String {
        let repository = try repositoryRoot(repositoryPath)
        let current = try defaultBranches(repository: repository).mergeTarget
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
            throw BridgeCommandError(code: "invalid_argument", message: "'\(branch)' isn't a valid Git branch name.")
        }
        let defaults = try defaultBranchOptionsIfNeeded(repository: repository, spec: spec)
        let branchFrom = try resolveBase(repository: repository, requested: spec.branchFrom, defaults: defaults)
        let mergeTarget = try resolveMergeTarget(repository: repository, requested: spec.mergeTarget, defaults: defaults)
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
        let defaults = try defaultBranchOptionsIfNeeded(repository: repository, spec: spec)
        let branchFrom = try resolveBase(repository: repository, requested: spec.branchFrom, defaults: defaults)
        let mergeTarget = try resolveMergeTarget(repository: repository, requested: spec.mergeTarget, defaults: defaults)
        let branch = spec.branch?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let branch, !branch.isEmpty {
            guard !branch.hasPrefix("-"), try git(repository, ["check-ref-format", "--branch", branch], allowFailure: true).status == 0 else {
                throw BridgeCommandError(code: "invalid_argument", message: "'\(branch)' isn't a valid Git branch name.")
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

    static func publishBranch(_ record: RepositoryWorktreeRecord) throws {
        let configuredRemote = try git(record.worktreePath, ["config", "--get", "branch.\(record.branch).remote"], allowFailure: true)
        let remotes = Set(try git(record.worktreePath, ["remote"]).output
            .split(whereSeparator: \.isNewline).map(String.init))
        let configuredName = configuredRemote.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let remote = remotes.contains(configuredName) ? configuredName : (remotes.contains("origin") ? "origin" : nil)
        guard let remote else {
            throw BridgeCommandError(code: "operation_failed", message: "The task branch has no Git remote configured for publishing.")
        }
        _ = try git(record.worktreePath, ["push", "--set-upstream", remote, record.branch])
    }

    static func hasChanges(_ record: RepositoryWorktreeRecord) throws -> Bool {
        let status = try git(record.worktreePath, ["status", "--porcelain", "--untracked-files=all"]).output
        return !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func hasMergeConflicts(_ record: RepositoryWorktreeRecord) throws -> Bool {
        guard record.mergeTarget?.isEmpty == false else { return false }
        let targetRef = try mergeTargetRef(record)
        let merge = try git(record.worktreePath, ["merge-tree", "--write-tree", "HEAD", targetRef], allowFailure: true)
        guard merge.status == 0 || merge.status == 1 else {
            throw BridgeCommandError(code: "operation_failed", message: merge.output.isEmpty ? "Git couldn't check the configured merge target." : merge.output)
        }
        return merge.status == 1
    }

    static func mergeTarget(_ record: RepositoryWorktreeRecord, target: String) throws {
        let targetRef = try mergeTargetRef(record)
        let result = try git(record.worktreePath, ["merge", "--no-commit", "--no-ff", targetRef], allowFailure: true)
        guard result.status == 0 || result.status == 1 else {
            throw BridgeCommandError(code: "operation_failed", message: result.output.isEmpty ? "Git couldn't merge the target branch." : result.output)
        }
    }

    private static func mergeTargetRef(_ record: RepositoryWorktreeRecord) throws -> String {
        guard let target = record.mergeTarget, !target.isEmpty else {
            throw BridgeCommandError(code: "invalid_transition", message: "This repository has no configured merge target.")
        }
        let remotes = Set(try git(record.worktreePath, ["remote"]).output.split(whereSeparator: \.isNewline).map(String.init))
        let configured = try git(record.worktreePath, ["config", "--get", "branch.\(target).remote"], allowFailure: true)
            .output.trimmingCharacters(in: .whitespacesAndNewlines)
        let remote = remotes.contains(configured) ? configured : (remotes.contains("origin") ? "origin" : nil)
        if let remote {
            _ = try git(record.worktreePath, ["fetch", "--quiet", remote, target])
            return "FETCH_HEAD"
        }
        let localTarget = try git(record.worktreePath, ["rev-parse", "--verify", "refs/heads/\(target)"], allowFailure: true)
        guard localTarget.status == 0 else {
            throw BridgeCommandError(code: "operation_failed", message: "The configured merge target '\(target)' is not available locally or on a configured remote.")
        }
        return target
    }

    static func hasUnmergedFiles(_ record: RepositoryWorktreeRecord) throws -> Bool {
        let result = try git(record.worktreePath, ["diff", "--name-only", "--diff-filter=U"])
        return !result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func hasMergeInProgress(_ record: RepositoryWorktreeRecord) throws -> Bool {
        let result = try git(record.worktreePath, ["rev-parse", "--verify", "MERGE_HEAD"], allowFailure: true)
        return result.status == 0
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

    private struct DefaultBranches {
        let branchFrom: String
        let mergeTarget: String
        let hasLocalMergeTarget: Bool
    }

    private static func defaultBranchOptionsIfNeeded(
        repository: String,
        spec: RepositoryWorktreeSpec
    ) throws -> DefaultBranches? {
        let needsBranchFrom = spec.branchFrom?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        let needsMergeTarget = spec.mergeTarget?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        guard needsBranchFrom || needsMergeTarget else { return nil }
        return try defaultBranches(repository: repository)
    }

    private static func defaultBranches(repository: String) throws -> DefaultBranches {
        let output = try git(repository, ["for-each-ref", "--format=%(refname:short)", "refs/heads"]).output
        let localBranches = Set(output.split(whereSeparator: \.isNewline).map(String.init))
        let remoteHead = try? git(repository, ["symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"]).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteBranch = remoteHead?.replacingOccurrences(of: "refs/remotes/origin/", with: "")

        let branchFrom: String
        if localBranches.contains("master") {
            branchFrom = "master"
        } else if let remoteBranch, !remoteBranch.isEmpty {
            branchFrom = remoteBranch
        } else {
            branchFrom = try currentBranch(repository: repository)
        }

        let mergeTarget: String
        if let remoteBranch, localBranches.contains(remoteBranch) {
            mergeTarget = remoteBranch
        } else if localBranches.contains("main") {
            mergeTarget = "main"
        } else if localBranches.contains("master") {
            mergeTarget = "master"
        } else {
            mergeTarget = try currentBranch(repository: repository)
        }
        return DefaultBranches(
            branchFrom: branchFrom,
            mergeTarget: mergeTarget,
            hasLocalMergeTarget: localBranches.contains(mergeTarget)
        )
    }

    private static func currentBranch(repository: String) throws -> String {
        try git(repository, ["branch", "--show-current"]).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func resolveBase(
        repository: String,
        requested: String?,
        defaults: DefaultBranches? = nil
    ) throws -> String {
        if let requested, !requested.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let base = requested.trimmingCharacters(in: .whitespacesAndNewlines)
            guard try git(repository, ["rev-parse", "--verify", "--quiet", "\(base)^{commit}"], allowFailure: true).status == 0 else {
                throw BridgeCommandError(code: "invalid_argument", message: "Branch-from '\(base)' doesn't exist in \(repository).")
            }
            return base
        }
        return try (defaults ?? defaultBranches(repository: repository)).branchFrom
    }

    private static func resolveMergeTarget(
        repository: String,
        requested: String?,
        defaults: DefaultBranches? = nil
    ) throws -> String {
        guard let requested,
              !requested.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let branchOptions = try defaults ?? defaultBranches(repository: repository)
            let candidate = branchOptions.mergeTarget
            guard !candidate.isEmpty else {
                throw BridgeCommandError(code: "operation_failed", message: "Choose a local branch as the merge target for \(repository).")
            }
            guard branchOptions.hasLocalMergeTarget else {
                throw BridgeCommandError(code: "invalid_argument", message: "Merge target '\(candidate)' must name an existing local branch.")
            }
            return candidate
        }
        let candidate = requested.trimmingCharacters(in: .whitespacesAndNewlines)
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
        let result = try StationAIProcessRunner.run(
            executable: executable,
            arguments: ["-C", path] + arguments
        )
        let text = String(data: result.stdout, encoding: .utf8) ?? ""
        guard result.status == 0 || allowFailure else {
            let detail = String(data: result.stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw BridgeCommandError(code: "operation_failed", message: detail.isEmpty ? "Git command failed." : detail)
        }
        return GitResult(status: result.status, output: text)
    }
}

struct StationAIProcessResult {
    let status: Int32
    let stdout: Data
    let stderr: Data
}

enum StationAIProcessRunner {
    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var outputData = Data()
        private var errorData = Data()

        func setOutput(_ data: Data) {
            lock.lock()
            outputData = data
            lock.unlock()
        }

        func setError(_ data: Data) {
            lock.lock()
            errorData = data
            lock.unlock()
        }

        func values() -> (Data, Data) {
            lock.lock()
            defer { lock.unlock() }
            return (outputData, errorData)
        }
    }

    static func run(
        executable: String,
        arguments: [String],
        directory: String? = nil
    ) throws -> StationAIProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let directory {
            process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        }
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        try? output.fileHandleForWriting.close()
        try? error.fileHandleForWriting.close()

        let box = OutputBox()
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            box.setOutput(output.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            box.setError(error.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }
        readers.wait()
        process.waitUntilExit()
        let (stdout, stderr) = box.values()
        return StationAIProcessResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }
}

enum StationAIBackgroundOperation {
    static func run<Value: Sendable>(
        priority: TaskPriority = .utility,
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await Task.detached(priority: priority) {
            try operation()
        }.value
    }
}

@MainActor
struct StationAIWorktreeService {

    private func perform<T>(
        _ operation: String,
        record: RepositoryWorktreeRecord? = nil,
        fields extraFields: [String: String] = [:],
        body: () async throws -> T
    ) async throws -> T {
        var fields = extraFields
        fields["operation"] = operation
        if let record {
            fields["repositoryPath"] = record.repositoryPath
            fields["branch"] = record.branch
            fields["worktreePath"] = record.worktreePath
            fields["isPending"] = String(record.isPending)
            fields["createdByStationAI"] = String(record.createdByStationAI)
        }
        fields["operationID"] = UUID().uuidString
        let startedAt = DispatchTime.now().uptimeNanoseconds
        StationAIDiagnostics.record("git.operation.started", fields: fields)
        do {
            let result = try await body()
            var resultFields = fields
            resultFields["durationMilliseconds"] = String((DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000)
            if let changed = result as? Bool { resultFields["hasChanges"] = String(changed) }
            StationAIDiagnostics.record("git.operation.succeeded", fields: resultFields)
            return result
        } catch {
            var failureFields = fields
            failureFields.merge(StationAIDiagnostics.errorFields(error)) { _, new in new }
            failureFields["durationMilliseconds"] = String((DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000)
            StationAIDiagnostics.record("git.operation.failed", fields: failureFields)
            throw error
        }
    }

    func pendingRecord(spec: RepositoryWorktreeSpec) async throws -> RepositoryWorktreeRecord {
        try await perform("worktree.prepare", fields: ["repositoryPath": spec.repositoryPath]) {
            try await StationAIBackgroundOperation.run {
                try StationAIWorktreeManager.pendingRecord(spec: spec)
            }
        }
    }

    func resolve(
        spec: RepositoryWorktreeSpec,
        title: String,
        root: URL
    ) async throws -> RepositoryWorktreeRecord {
        try await perform("worktree.create", fields: [
            "repositoryPath": spec.repositoryPath,
            "branch": spec.branch ?? "auto",
            "branchFrom": spec.branchFrom ?? "",
            "mergeTarget": spec.mergeTarget ?? "",
            "managedRoot": root.path
        ]) {
            try await StationAIBackgroundOperation.run {
                try StationAIWorktreeManager.resolve(spec: spec, title: title, root: root)
            }
        }
    }

    func hasChanges(_ record: RepositoryWorktreeRecord) async throws -> Bool {
        try await perform("worktree.check_changes", record: record) {
            try await StationAIBackgroundOperation.run {
                try StationAIWorktreeManager.hasChanges(record)
            }
        }
    }

    func hasMergeConflicts(_ record: RepositoryWorktreeRecord) async throws -> Bool {
        try await perform("git.check_merge_conflicts", record: record, fields: ["mergeTarget": record.mergeTarget ?? ""]) {
            try await StationAIBackgroundOperation.run {
                try StationAIWorktreeManager.hasMergeConflicts(record)
            }
        }
    }

    func mergeTarget(_ record: RepositoryWorktreeRecord, target: String) async throws {
        try await perform("git.merge_target", record: record, fields: ["mergeTarget": target]) {
            try await StationAIBackgroundOperation.run { try StationAIWorktreeManager.mergeTarget(record, target: target) }
        }
    }

    func hasUnmergedFiles(_ record: RepositoryWorktreeRecord) async throws -> Bool {
        try await perform("git.check_unmerged_files", record: record) {
            try await StationAIBackgroundOperation.run { try StationAIWorktreeManager.hasUnmergedFiles(record) }
        }
    }

    func hasMergeInProgress(_ record: RepositoryWorktreeRecord) async throws -> Bool {
        try await perform("git.check_merge_in_progress", record: record) {
            try await StationAIBackgroundOperation.run { try StationAIWorktreeManager.hasMergeInProgress(record) }
        }
    }

    func remove(_ record: RepositoryWorktreeRecord) async throws {
        try await perform("worktree.remove", record: record) {
            try await StationAIBackgroundOperation.run {
                try StationAIWorktreeManager.remove(record)
            }
        }
    }

    func removeAfterConfirmation(_ record: RepositoryWorktreeRecord) async throws {
        try await perform("worktree.remove_after_confirmation", record: record) {
            try await StationAIBackgroundOperation.run {
                try StationAIWorktreeManager.removeAfterConfirmation(record)
            }
        }
    }

    func commitChanges(_ record: RepositoryWorktreeRecord, message: String) async throws {
        try await perform("git.commit", record: record, fields: ["commitMessageBytes": String(message.utf8.count)]) {
            try await StationAIBackgroundOperation.run {
                try StationAIWorktreeManager.commitChanges(record, message: message)
            }
        }
    }

    func publishBranch(_ record: RepositoryWorktreeRecord) async throws {
        try await perform("git.publish_branch", record: record) {
            try await StationAIBackgroundOperation.run {
                try StationAIWorktreeManager.publishBranch(record)
            }
        }
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
                .buttonHoverPointer()
                .help("Browse folders")
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
                            .buttonHoverPointer()
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
                            .buttonHoverPointer()
                            .help("Add repository \(repository.lastPathComponent)")
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
    @AppStorage(WorkspaceSettings.pullRequestConflictActionKey, store: WorkspaceSettings.preferencesStore) private var pullRequestConflictAction = "ask"
    @State private var pickerError: String?

    private var parentFolderURL: URL? {
        WorkspaceSettings.validDirectoryURL(for: defaultParentFolderPath)
    }

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: Binding(
                    get: { appearance },
                    set: { value in
                        do {
                            try WorkspaceSettingsManager().setAppearance(value)
                        } catch {
                            pickerError = error.localizedDescription
                        }
                    }
                )) {
                    Text("Dark").tag("dark")
                    Text("Light").tag("light")
                }
                .accessibilityIdentifier("appearance-picker")
                .accessibilityValue(appearance)
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
                    .buttonHoverPointer()
                    .help("Choose parent folder")
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
                        .buttonHoverPointer()
                        .help("Clear default parent folder")
                        .accessibilityIdentifier("clear-default-parent-folder-button")
                    }
                }
                if !defaultParentFolderPath.isEmpty && parentFolderURL == nil {
                    Label("This folder is unavailable. Choose another parent folder.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            Section("Pull request conflicts") {
                Picker("When conflicts are found", selection: Binding(
                    get: { WorkspaceSettingsManager().pullRequestConflictAction },
                    set: { value in
                        do {
                            try WorkspaceSettingsManager().setPullRequestConflictAction(value)
                            pullRequestConflictAction = value
                        } catch {
                            pickerError = error.localizedDescription
                        }
                    }
                )) {
                    Text("Ask each time").tag("ask")
                    Text("Resolve and push").tag("resolve-and-push")
                    Text("Resolve without pushing").tag("resolve-only")
                    Text("Keep the PR as is").tag("keep")
                }
                .accessibilityIdentifier("pr-conflict-action-picker")
                .accessibilityValue(pullRequestConflictAction)
            }
            Section {
                    Text("Workspace suggestions affect new tasks. Pull request conflict behavior controls how StationAI handles conflicts when creating a pull request.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 420)
        .preferredColorScheme(appearance == "light" ? .light : .dark)
        .alert("Couldn't choose folder", isPresented: Binding(
            get: { pickerError != nil },
            set: { if !$0 { pickerError = nil } }
        )) {
            Button("OK", role: .cancel) { pickerError = nil }
            .buttonHoverPointer()
            .help("Dismiss folder error")
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
    private static var ingressPendingBytes = 0
    private static var ingressDroppedEvents = 0
    nonisolated private static let writeLock = NSLock()
    nonisolated(unsafe) private static var logDescriptor: Int32 = -1
    nonisolated(unsafe) private static var lockDescriptor: Int32 = -1
    nonisolated(unsafe) private static var openedLockPath: String?
    nonisolated(unsafe) private static var openedLogPath: String?
    nonisolated(unsafe) private static var flushScheduled = false
    nonisolated(unsafe) private static var bufferedEvents = Data()
    nonisolated(unsafe) private static var bufferedURL: URL?
    nonisolated(unsafe) private static var pendingWriterBytes = 0
    nonisolated(unsafe) private static var droppedBufferedEvents = 0
    nonisolated(unsafe) private static var failedWriteCount = 0
    nonisolated(unsafe) private static var lastWriteFailure = ""
    nonisolated private static let totalLogLimit = 10 * 1024 * 1024
    nonisolated private static let perFileLimit = totalLogLimit / 2
    nonisolated private static let eventLimit = 512 * 1024
    nonisolated private static let batchLimit = 128 * 1024
    nonisolated private static let pendingWriterLimit = 2 * 1024 * 1024
    nonisolated private static let logger = Logger(subsystem: "com.stationai.app", category: "diagnostics")
    nonisolated private static let writerQueue = DispatchQueue(label: "com.stationai.diagnostics.writer", qos: .utility)

    static func useDataDirectory(_ path: String?) {
        directoryOverride = path.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static var logURL: URL {
        let directory: URL
        if let directoryOverride {
            directory = directoryOverride
        } else if let dataDirectory = ProcessInfo.processInfo.environment["STATIONAI_DATA_DIRECTORY"] {
            directory = URL(fileURLWithPath: dataDirectory, isDirectory: true)
        } else if StationAIAppIdentity.worktreeKey != nil,
                  let worktreeDirectory = try? StationAIAppIdentity.defaultDataDirectory() {
            directory = worktreeDirectory
        } else if let logsDirectory = try? FileManager.default.url(
            for: .libraryDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            directory = logsDirectory.appendingPathComponent("Logs/StationAI", isDirectory: true)
        } else {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("StationAI", isDirectory: true)
        }
        return directory.appendingPathComponent("Diagnostics.jsonl")
    }

    static var storeURL: URL {
        let directory: URL
        if let directoryOverride {
            directory = directoryOverride
        } else if let dataDirectory = ProcessInfo.processInfo.environment["STATIONAI_DATA_DIRECTORY"] {
            directory = URL(fileURLWithPath: dataDirectory, isDirectory: true)
        } else if let supportDirectory = try? StationAIAppIdentity.defaultDataDirectory() {
            directory = supportDirectory
        } else {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("StationAI", isDirectory: true)
        }
        return directory.appendingPathComponent("StationAI-v2.store")
    }

    static func storeContextFields(for storeURL: URL?) -> [String: String] {
        guard let storeURL else { return ["storePathAvailable": "false"] }

        let fileManager = FileManager.default
        let directoryURL = storeURL.deletingLastPathComponent()
        var fields = [
            "storePathAvailable": "true",
            "storePath": storeURL.standardizedFileURL.path,
            "storeDirectoryExists": String(fileManager.fileExists(atPath: directoryURL.path)),
            "storeDirectoryReadable": String(fileManager.isReadableFile(atPath: directoryURL.path)),
            "storeDirectoryWritable": String(fileManager.isWritableFile(atPath: directoryURL.path))
        ]
        appendFileSnapshot(storeURL, prefix: "storeFile", to: &fields)
        appendFileSnapshot(
            URL(fileURLWithPath: storeURL.path + "-wal"),
            prefix: "storeWAL",
            to: &fields
        )
        appendFileSnapshot(
            URL(fileURLWithPath: storeURL.path + "-shm"),
            prefix: "storeSHM",
            to: &fields
        )
        return fields
    }

    private static func appendFileSnapshot(_ url: URL, prefix: String, to fields: inout [String: String]) {
        let fileManager = FileManager.default
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        fields["\(prefix)Exists"] = String(attributes != nil)
        fields["\(prefix)Readable"] = String(fileManager.isReadableFile(atPath: url.path))
        fields["\(prefix)Writable"] = String(fileManager.isWritableFile(atPath: url.path))
        if let size = attributes?[.size] as? NSNumber {
            fields["\(prefix)SizeBytes"] = size.stringValue
        }
        if let permissions = attributes?[.posixPermissions] as? NSNumber {
            fields["\(prefix)Permissions"] = String(format: "%04o", permissions.intValue)
        }
        if let modified = attributes?[.modificationDate] as? Date {
            fields["\(prefix)ModifiedAt"] = ISO8601DateFormatter().string(from: modified)
        }
    }

    static func jsonString<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return "<encoding-failed>"
        }
        let safeObject = sanitizeImagePayloads(object)
        guard let safeData = try? JSONSerialization.data(withJSONObject: safeObject, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return "<encoding-failed>"
        }
        return String(data: safeData, encoding: .utf8) ?? "<encoding-failed>"
    }

    nonisolated static func jsonStringOffMain<T: Encodable>(_ value: T) async -> String {
        let transfer = DiagnosticValueTransfer(value)
        return await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: jsonStringForDiagnostic(transfer.value))
            }
        }
    }

    nonisolated private static func jsonStringForDiagnostic<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return "<encoding-failed>"
        }
        let safeObject = sanitizeImagePayloads(object)
        guard let safeData = try? JSONSerialization.data(withJSONObject: safeObject, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return "<encoding-failed>"
        }
        return String(data: safeData, encoding: .utf8) ?? "<encoding-failed>"
    }

    nonisolated static func jsonString(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return String(describing: value)
        }
        let safeObject = sanitizeImagePayloads(object)
        guard let safeData = try? JSONSerialization.data(withJSONObject: safeObject, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return "<encoding-failed>"
        }
        return String(data: safeData, encoding: .utf8) ?? "<encoding-failed>"
    }

    nonisolated private static func sanitizeImagePayloads(_ value: Any) -> Any {
        if let string = value as? String, string.hasPrefix("data:image/") {
            let mime = string.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? "unknown"
            return ["mime": mime, "encodedCharacterCount": string.count]
        }
        if let values = value as? [Any] {
            return values.map(sanitizeImagePayloads)
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.mapValues(sanitizeImagePayloads)
        }
        return value
    }

    static func endBatch() async {
        let ingressDrops = ingressDroppedEvents
        ingressDroppedEvents = 0
        let url = logURL
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writerQueue.async {
                droppedBufferedEvents += ingressDrops
                flushBufferedEvents(at: url)
                continuation.resume()
            }
        }
    }

    static func recordAndFlush(_ event: String, fields: [String: String] = [:]) {
        record(event, fields: fields)
        let url = logURL
        writerQueue.sync {
            flushBufferedEvents(at: url)
        }
    }

    static func record(_ event: String, fields: [String: String] = [:]) {
        var entry = fields
        entry["timestamp"] = ISO8601DateFormatter().string(from: Date())
        entry["event"] = event
        entry["process"] = ProcessInfo.processInfo.processName
        entry["processID"] = String(ProcessInfo.processInfo.processIdentifier)
        enqueue(entry, structuredFields: [:])
    }

    static func record(_ event: String, fields: [String: String] = [:], structuredFields: [String: Any]) {
        var entry = fields
        entry["timestamp"] = ISO8601DateFormatter().string(from: Date())
        entry["event"] = event
        entry["process"] = ProcessInfo.processInfo.processName
        entry["processID"] = String(ProcessInfo.processInfo.processIdentifier)
        enqueue(entry, structuredFields: structuredFields)
    }

    private static func enqueue(_ originalEntry: [String: String], structuredFields originalStructuredFields: [String: Any]) {
        var entry = originalEntry
        var structuredFields = originalStructuredFields
        var estimatedBytes = estimateRetainedBytes(entry) + estimateRetainedBytes(structuredFields)
        if estimatedBytes > pendingWriterLimit {
            entry = [
                "timestamp": entry["timestamp"] ?? ISO8601DateFormatter().string(from: Date()),
                "event": entry["event"] ?? "diagnostics.event",
                "process": ProcessInfo.processInfo.processName,
                "processID": String(ProcessInfo.processInfo.processIdentifier),
                "recording": "omitted_event_larger_than_writer_queue_limit",
                "originalByteCount": String(estimatedBytes)
            ]
            structuredFields = [:]
            estimatedBytes = entry.reduce(into: 0) { total, pair in
                total += pair.key.utf8.count + pair.value.utf8.count + 8
            }
        }
        guard ingressPendingBytes + estimatedBytes <= pendingWriterLimit else {
            ingressDroppedEvents += 1
            return
        }
        ingressPendingBytes += estimatedBytes
        let ingressDrops = ingressDroppedEvents
        ingressDroppedEvents = 0
        let url = logURL
        let transfer = DiagnosticValueTransfer(structuredFields)
        writerQueue.async {
            droppedBufferedEvents += ingressDrops
            var encodedEntry = entry
            for (key, value) in transfer.value {
                encodedEntry[key] = jsonString(value)
            }
            appendSerializedEvent(encodedEntry, at: url)
            Task { @MainActor in
                ingressPendingBytes = max(0, ingressPendingBytes - estimatedBytes)
            }
        }
    }

    nonisolated private static func estimateRetainedBytes(_ value: Any, limit: Int = pendingWriterLimit) -> Int {
        let overLimit = limit + 1
        if let string = value as? String { return min(string.utf8.count, overLimit) }
        if let dictionary = value as? [String: String] {
            var total = 0
            for (key, value) in dictionary {
                total += key.utf8.count + min(value.utf8.count, overLimit) + 8
                if total > limit { return overLimit }
            }
            return total
        }
        if let dictionary = value as? [String: Any] {
            var total = 0
            for (key, nestedValue) in dictionary {
                total += key.utf8.count + 8
                if total > limit { return overLimit }
                total += estimateRetainedBytes(nestedValue, limit: limit - total)
                if total > limit { return overLimit }
            }
            return total
        }
        if let values = value as? [Any] {
            var total = 0
            for nestedValue in values {
                total += estimateRetainedBytes(nestedValue, limit: limit - total) + 4
                if total > limit { return overLimit }
            }
            return total
        }
        if value is NSNull { return 4 }
        return min(16, overLimit)
    }

    nonisolated private static func appendSerializedEvent(_ originalEntry: [String: String], at url: URL) {
        var entry = originalEntry
        guard var data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        if data.count + 1 > eventLimit {
            guard data.count <= perFileLimit else {
                entry = [
                    "timestamp": ISO8601DateFormatter().string(from: Date()),
                    "event": originalEntry["event"] ?? "diagnostics.event",
                    "process": ProcessInfo.processInfo.processName,
                    "processID": String(ProcessInfo.processInfo.processIdentifier),
                    "recording": "omitted_event_larger_than_per_file_limit",
                    "originalByteCount": String(data.count + 1)
                ]
                guard let compactData = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
                data = compactData
                data.append(0x0A)
                buffer(data, at: url)
                return
            }
            let payload = data.base64EncodedString()
            let payloadChunkSize = eventLimit / 2
            let chunks = stride(from: 0, to: payload.count, by: payloadChunkSize).map { offset in
                let start = payload.index(payload.startIndex, offsetBy: offset)
                let end = payload.index(start, offsetBy: min(payloadChunkSize, payload.distance(from: start, to: payload.endIndex)))
                return String(payload[start..<end])
            }
            for (index, chunk) in chunks.enumerated() {
                let chunkEntry: [String: String] = [
                    "timestamp": entry["timestamp"] ?? ISO8601DateFormatter().string(from: Date()),
                    "event": "session.payload.chunk",
                    "payloadEvent": originalEntry["event"] ?? "diagnostics.event",
                    "payloadEncoding": "base64-json",
                    "chunkIndex": String(index),
                    "chunkCount": String(chunks.count),
                    "payload": chunk,
                    "process": ProcessInfo.processInfo.processName,
                    "processID": String(ProcessInfo.processInfo.processIdentifier)
                ]
                guard var chunkData = try? JSONSerialization.data(withJSONObject: chunkEntry, options: [.sortedKeys]) else { continue }
                chunkData.append(0x0A)
                buffer(chunkData, at: url)
            }
            return
        }
        data.append(0x0A)
        buffer(data, at: url)
    }

    nonisolated private static func buffer(_ data: Data, at url: URL) {
        if bufferedURL == nil { bufferedURL = url }
        bufferedEvents.append(data)
        if bufferedEvents.count >= batchLimit {
            flushBufferedEvents(at: url)
        } else if !flushScheduled {
            flushScheduled = true
            writerQueue.asyncAfter(deadline: .now() + .milliseconds(250)) {
                flushScheduled = false
                flushBufferedEvents(at: url)
            }
        }
    }

    nonisolated private static func flushBufferedEvents(at url: URL? = nil) {
        guard !bufferedEvents.isEmpty || droppedBufferedEvents > 0 || failedWriteCount > 0 else { return }
        var data = bufferedEvents
        bufferedEvents.removeAll(keepingCapacity: true)
        let targetURL = url ?? bufferedURL ?? URL(fileURLWithPath: "/")
        bufferedURL = nil
        do {
            try FileManager.default.createDirectory(
                at: targetURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: targetURL.deletingLastPathComponent().path
            )
        } catch {
            droppedBufferedEvents += data.reduce(into: 0) { if $1 == 0x0A { $0 += 1 } }
            logger.error("StationAI couldn't create diagnostics directory: \(error.localizedDescription, privacy: .private)")
            return
        }
        let lossLockPath = targetURL.path + ".loss.lock"
        let lossLockDescriptor = open(lossLockPath, O_WRONLY | O_CREAT, S_IRUSR | S_IWUSR)
        guard lossLockDescriptor >= 0 else {
            droppedBufferedEvents += data.reduce(into: 0) { if $1 == 0x0A { $0 += 1 } }
            logger.error("StationAI couldn't open diagnostics loss-state lock: \(String(cString: strerror(errno)), privacy: .private)")
            return
        }
        _ = fchmod(lossLockDescriptor, S_IRUSR | S_IWUSR)
        guard flock(lossLockDescriptor, LOCK_EX) == 0 else {
            let lockError = String(cString: strerror(errno))
            close(lossLockDescriptor)
            droppedBufferedEvents += data.reduce(into: 0) { if $1 == 0x0A { $0 += 1 } }
            logger.error("StationAI couldn't lock diagnostics loss state: \(lockError, privacy: .private)")
            return
        }
        defer {
            _ = flock(lossLockDescriptor, LOCK_UN)
            close(lossLockDescriptor)
        }
        if !data.isEmpty && pendingWriterBytes + data.count > pendingWriterLimit {
            droppedBufferedEvents += data.reduce(into: 0) { if $1 == 0x0A { $0 += 1 } }
            return
        }
        let persistedLoss = readPendingLoss(at: targetURL)
        let reportedDrops = (persistedLoss?.droppedEventCount ?? 0) + droppedBufferedEvents
        let reportedFailures = (persistedLoss?.failedWriteCount ?? 0) + failedWriteCount
        let reportedError = lastWriteFailure
            .isEmpty ? (persistedLoss?.lastWriteError ?? "") : lastWriteFailure
        let reportsLoss = reportedDrops > 0 || reportedFailures > 0
        var includedLossMarker = false
        if reportsLoss,
           let marker = try? JSONSerialization.data(withJSONObject: [
               "timestamp": ISO8601DateFormatter().string(from: Date()),
               "event": "diagnostics.writer.loss",
                "droppedEventCount": String(reportedDrops),
               "failedWriteCount": String(reportedFailures),
               "lastWriteError": reportedError
           ], options: [.sortedKeys]) {
            var markerData = marker
            markerData.append(0x0A)
            if pendingWriterBytes + data.count + markerData.count <= pendingWriterLimit {
                data.insert(contentsOf: markerData, at: 0)
                includedLossMarker = true
            }
        }
        pendingWriterBytes += data.count
        if let error = write(data, at: targetURL) {
            let saved = persistPendingLoss(
                droppedEventCount: reportedDrops,
                failedWriteCount: reportedFailures + 1,
                lastWriteError: error,
                at: targetURL
            )
            if saved {
                droppedBufferedEvents = 0
                failedWriteCount = 0
                lastWriteFailure = ""
            } else {
                failedWriteCount += 1
                lastWriteFailure = error
            }
        } else if reportsLoss && includedLossMarker {
            droppedBufferedEvents = 0
            failedWriteCount = 0
            lastWriteFailure = ""
            try? FileManager.default.removeItem(at: pendingLossURL(for: targetURL))
        }
        pendingWriterBytes = max(0, pendingWriterBytes - data.count)
    }

    private struct PendingLoss: Decodable {
        let droppedEventCount: Int
        let failedWriteCount: Int
        let lastWriteError: String
    }

    nonisolated private static func pendingLossURL(for url: URL) -> URL {
        url.appendingPathExtension("loss")
    }

    nonisolated private static func readPendingLoss(at url: URL) -> PendingLoss? {
        guard let data = try? Data(contentsOf: pendingLossURL(for: url)) else { return nil }
        return try? JSONDecoder().decode(PendingLoss.self, from: data)
    }

    nonisolated private static func persistPendingLoss(
        droppedEventCount: Int,
        failedWriteCount: Int,
        lastWriteError: String,
        at url: URL
    ) -> Bool {
        let state: [String: Any] = [
            "droppedEventCount": droppedEventCount,
            "failedWriteCount": failedWriteCount,
            "lastWriteError": lastWriteError
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) else { return false }
        let stateURL = pendingLossURL(for: url)
        do {
            try data.write(to: stateURL, options: .atomic)
            do {
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
            } catch {
                logger.error("StationAI couldn't secure diagnostics loss state: \(error.localizedDescription, privacy: .private)")
            }
            return true
        } catch {
            logger.error("StationAI couldn't persist diagnostics loss state: \(error.localizedDescription, privacy: .private)")
            return false
        }
    }

    nonisolated private static func write(_ data: Data, at url: URL) -> String? {
        writeLock.lock()
        defer { writeLock.unlock() }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: url.deletingLastPathComponent().path
            )
            let lockPath = url.path + ".lock"
            if openedLockPath != lockPath {
                if lockDescriptor >= 0 { close(lockDescriptor) }
                lockDescriptor = -1
                openedLockPath = lockPath
            }
            if lockDescriptor < 0 {
                lockDescriptor = open(lockPath, O_WRONLY | O_CREAT, S_IRUSR | S_IWUSR)
                guard lockDescriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            }
            guard flock(lockDescriptor, LOCK_EX) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            defer { _ = flock(lockDescriptor, LOCK_UN) }
            try rotateLogIfNeeded(for: data.count, at: url)
            var descriptorInfo = stat()
            var pathInfo = stat()
            let descriptorExists = logDescriptor >= 0 && fstat(logDescriptor, &descriptorInfo) == 0
            let pathExists = lstat(url.path, &pathInfo) == 0
            let descriptorMatchesPath = descriptorExists && pathExists
                && descriptorInfo.st_dev == pathInfo.st_dev
                && descriptorInfo.st_ino == pathInfo.st_ino
            if openedLogPath != url.path || !descriptorMatchesPath {
                if logDescriptor >= 0 { close(logDescriptor) }
                logDescriptor = -1
                openedLogPath = url.path
            }
            if logDescriptor < 0 {
                logDescriptor = open(url.path, O_WRONLY | O_CREAT | O_APPEND, S_IRUSR | S_IWUSR)
                guard logDescriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            }
            var fileInfo = stat()
            guard fstat(logDescriptor, &fileInfo) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let originalSize = fileInfo.st_size
            var writeFailureErrno = EIO
            let writeResult = data.withUnsafeBytes { buffer -> Bool in
                guard let baseAddress = buffer.baseAddress else { return data.isEmpty }
                var offset = 0
                while offset < buffer.count {
                    let written = Darwin.write(logDescriptor, baseAddress.advanced(by: offset), buffer.count - offset)
                    guard written > 0 else {
                        writeFailureErrno = errno
                        return false
                    }
                    offset += written
                }
                return true
            }
            guard writeResult else {
                _ = ftruncate(logDescriptor, originalSize)
                close(logDescriptor)
                logDescriptor = -1
                throw POSIXError(POSIXErrorCode(rawValue: writeFailureErrno) ?? .EIO)
            }
            return nil
        } catch {
            logger.error("StationAI couldn't write diagnostics: \(error.localizedDescription, privacy: .private)")
            return error.localizedDescription
        }
    }

    nonisolated private static func rotateLogIfNeeded(for incomingBytes: Int, at url: URL) throws {
        let previousURL = url.appendingPathExtension("1")
        let currentSize = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.intValue ?? 0
        let previousSize = ((try? FileManager.default.attributesOfItem(atPath: previousURL.path)[.size]) as? NSNumber)?.intValue ?? 0
        if previousSize > perFileLimit || currentSize + previousSize + incomingBytes > totalLogLimit {
            try? FileManager.default.removeItem(at: previousURL)
        }
        guard currentSize + incomingBytes > perFileLimit else { return }

        if logDescriptor >= 0 {
            close(logDescriptor)
            logDescriptor = -1
        }
        try? FileManager.default.removeItem(at: previousURL)
        if currentSize > 0 {
            try FileManager.default.moveItem(at: url, to: previousURL)
        }
        openedLogPath = nil

        // The two files are each bounded to half the total allowance.
        // This also trims an older generation immediately during rotation.
        let rotatedSize = ((try? FileManager.default.attributesOfItem(atPath: previousURL.path)[.size]) as? NSNumber)?.intValue ?? 0
        if rotatedSize > perFileLimit { try FileManager.default.removeItem(at: previousURL) }
    }

    static func errorFields(_ error: Error, includeUserInfoDetails: Bool = false) -> [String: String] {
        var fields: [String: String] = [:]
        fields["errorDescription"] = error.localizedDescription
        var underlying: NSError? = error as NSError
        var depth = 0
        while let current = underlying, depth < 5 {
            let prefix = "error\(depth)"
            fields["\(prefix)Domain"] = current.domain
            fields["\(prefix)Code"] = String(current.code)
            fields["\(prefix)Description"] = String(current.localizedDescription.prefix(4_096))
            let userInfoKeys = current.userInfo.keys.map(String.init(describing:)).sorted()
            fields["\(prefix)UserInfoKeys"] = userInfoKeys.joined(separator: ",")
            fields["\(prefix)UserInfoKeyCount"] = String(userInfoKeys.count)
            if let reason = current.localizedFailureReason { fields["\(prefix)Reason"] = reason }
            if includeUserInfoDetails {
                let diagnosticUserInfo = current.userInfo
                    .filter { $0.key != NSUnderlyingErrorKey }
                    .reduce(into: [String: Any]()) { result, item in
                        result[item.key] = diagnosticUserInfoValue(item.value)
                    }
                if let data = try? JSONSerialization.data(withJSONObject: diagnosticUserInfo, options: [.sortedKeys]),
                   let summary = String(data: data, encoding: .utf8) {
                    fields["\(prefix)UserInfo"] = String(summary.prefix(8_192))
                    fields["\(prefix)UserInfoTruncated"] = String(summary.utf8.count > 8_192)
                }
                if let debugDescription = current.userInfo["NSDebugDescription"] as? String {
                    fields["\(prefix)DebugDescription"] = String(debugDescription.prefix(4_096))
                }
                if let filePath = current.userInfo[NSFilePathErrorKey] as? String {
                    fields["\(prefix)FilePath"] = String(filePath.prefix(4_096))
                }
                if let recoverySuggestion = current.localizedRecoverySuggestion {
                    fields["\(prefix)RecoverySuggestion"] = String(recoverySuggestion.prefix(2_048))
                }
                if let failingURL = current.userInfo["NSURLErrorKey"] as? URL {
                    var components = URLComponents(url: failingURL, resolvingAgainstBaseURL: false)
                    components?.query = nil
                    components?.fragment = nil
                    fields["\(prefix)URL"] = components?.string ?? failingURL.path
                } else if let failingURL = current.userInfo["NSURLErrorKey"] as? String {
                    var components = URLComponents(string: failingURL)
                    components?.query = nil
                    components?.fragment = nil
                    fields["\(prefix)URL"] = components?.string ?? String(failingURL.prefix(4_096))
                }
            }
            underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return fields
    }

    private static func diagnosticUserInfoValue(_ value: Any, depth: Int = 0) -> Any {
        guard depth < 3 else { return "<nested-value-truncated>" }
        if let string = value as? String { return String(string.prefix(4_096)) }
        if let number = value as? NSNumber { return number }
        if let url = value as? URL {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.query = nil
            components?.fragment = nil
            return components?.string ?? url.path
        }
        if let date = value as? Date { return ISO8601DateFormatter().string(from: date) }
        if let data = value as? Data { return ["byteCount": data.count] }
        if let error = value as? NSError {
            return ["domain": error.domain, "code": error.code, "description": String(error.localizedDescription.prefix(4_096))]
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.keys.sorted().prefix(32).reduce(into: [String: Any]()) { result, key in
                if let nested = dictionary[key] {
                    result[key] = diagnosticUserInfoValue(nested, depth: depth + 1)
                }
            }
        }
        if let values = value as? [Any] {
            return values.prefix(32).map { diagnosticUserInfoValue($0, depth: depth + 1) }
        }
        return ["type": String(reflecting: type(of: value))]
    }

    static func errorFields(_ error: Error, redacting values: [String]) -> [String: String] {
        var fields = errorFields(error, includeUserInfoDetails: true)
        let secrets = values.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
        guard !secrets.isEmpty else { return fields }

        let redactableFields = ["errorDescription"] + (0..<5).flatMap { index in
            ["Description", "Reason", "UserInfo", "DebugDescription", "FilePath", "RecoverySuggestion", "URL"].map {
                "error\(index)\($0)"
            }
        }
        for key in redactableFields {
            guard var value = fields[key] else { continue }
            for secret in secrets {
                value = value.replacingOccurrences(of: secret, with: "[redacted]")
            }
            fields[key] = value
        }
        return fields
    }
}

private struct DiagnosticValueTransfer<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
