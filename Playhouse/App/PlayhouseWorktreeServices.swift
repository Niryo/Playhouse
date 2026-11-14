import AppKit
import Darwin
import Foundation
import OSLog
import SwiftUI

enum PlayhouseWorktreeManager {
    /// Task worktrees live in the app's data directory, so removing that one
    /// folder removes them too. Worktrees made before this stay at the paths
    /// their tasks recorded.
    static func defaultRoot(dataDirectory: String? = nil) -> URL {
        #if DEBUG
        if let override = PlayhouseProcessEnvironment.current["PLAYHOUSE_E2E_WORKTREE_DIRECTORY"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
        }
        #endif
        // The same data directory the store opens: a window reads it from its
        // launch environment, the daemon from each request.
        let base = (dataDirectory ?? PlayhouseProcessEnvironment.current["PLAYHOUSE_DATA_DIRECTORY"])
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? (try? PlayhouseAppIdentity.defaultDataDirectory())
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".playhouse", isDirectory: true)
        // Not "Worktrees": that folder already holds each worktree build's data
        // directory, and the file system ignores case.
        return base.appendingPathComponent("task-worktrees", isDirectory: true).standardizedFileURL
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

    static func defaultLocalBranch(repositoryPath: String) throws -> String {
        let repository = try repositoryRoot(repositoryPath)
        let current = try defaultBranches(repository: repository).mergeTarget
        guard !current.isEmpty else {
            throw BridgeCommandError(code: "operation_failed", message: "Choose a local branch as the merge target for \(repository).")
        }
        return current
    }

    /// `reservedBranches` are branch names other active tasks already use in this
    /// repository; an auto-named branch avoids them (and any other taken name).
    static func resolve(
        spec: RepositoryWorktreeSpec,
        title: String,
        root: URL,
        reservedBranches: Set<String> = []
    ) throws -> RepositoryWorktreeRecord {
        let repository = try repositoryRoot(spec.repositoryPath)
        let requested = spec.branch?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let isAuto = requested.isEmpty || requested == "auto"
        var branch = isAuto ? branchSlug(title) : requested
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
        if isAuto {
            branch = try uniqueAutoBranch(slug: branch, repository: repository, root: root, reserved: reservedBranches)
        }
        guard branch != mergeTarget else {
            throw BridgeCommandError(code: "invalid_argument", message: "A task branch can't also be its merge target: \(branch).")
        }
        let existing = try worktrees(repository: repository)
        if let path = existing.first(where: { $0.branch == branch })?.path {
            return RepositoryWorktreeRecord(repositoryPath: repository, branch: branch, worktreePath: path, branchFrom: branchFrom, createdByPlayhouse: false, mergeTarget: mergeTarget)
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
            try refreshOriginBase(repository: repository, base: branchFrom)
            // A remote branch-from must not become the task branch's upstream.
            _ = try git(repository, ["worktree", "add", "--no-track", "-b", branch, destination.path, branchFrom])
        }
        return RepositoryWorktreeRecord(repositoryPath: repository, branch: branch, worktreePath: destination.path, branchFrom: branchFrom, createdByPlayhouse: true, mergeTarget: mergeTarget)
    }

    private static let suffixAlphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")

    /// The slug when nothing uses it yet, else the slug plus a short random suffix
    /// that is also free, so an auto task always gets a fresh branch and worktree.
    private static func uniqueAutoBranch(slug: String, repository: String, root: URL, reserved: Set<String>) throws -> String {
        let taken = try takenBranchNames(repository: repository, reserved: reserved)
        func isTaken(_ name: String) -> Bool {
            taken.contains(name)
                || FileManager.default.fileExists(atPath: managedPath(root: root, repository: repository, branch: name).path)
        }
        guard isTaken(slug) else { return slug }
        for _ in 0..<10 {
            let suffix = String((0..<4).map { _ in suffixAlphabet.randomElement()! })
            let candidate = "\(slug)-\(suffix)"
            guard !isTaken(candidate) else { continue }
            guard try git(repository, ["check-ref-format", "--branch", candidate], allowFailure: true).status == 0 else { continue }
            return candidate
        }
        throw BridgeCommandError(code: "operation_failed", message: "Couldn't find an unused branch name based on '\(slug)'. Choose a branch name instead.")
    }

    private static func takenBranchNames(repository: String, reserved: Set<String>) throws -> Set<String> {
        var names = reserved
        let refs = try git(repository, ["for-each-ref", "--format=%(refname)", "refs/heads", "refs/remotes"]).output
        for ref in refs.split(whereSeparator: \.isNewline).map(String.init) {
            if ref.hasPrefix("refs/heads/") {
                names.insert(String(ref.dropFirst("refs/heads/".count)))
            } else if ref.hasPrefix("refs/remotes/") {
                // refs/remotes/<remote>/<branch>
                let parts = ref.dropFirst("refs/remotes/".count).split(separator: "/", maxSplits: 1)
                if parts.count == 2 { names.insert(String(parts[1])) }
            }
        }
        for worktree in try worktrees(repository: repository) {
            if let branch = worktree.branch { names.insert(branch) }
        }
        return names
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
            createdByPlayhouse: false,
            mergeTarget: mergeTarget,
            isPending: true
        )
    }

    /// The base for follow-up work after a task's pull request merged: the merge target as
    /// the remote has it now, so the merged commits are included even when the local
    /// branch is stale. Without a reachable remote branch, the local merge target is used.
    static func freshMergeTargetBase(repositoryPath: String, mergeTarget: String?) throws -> String {
        let repository = try repositoryRoot(repositoryPath)
        let target = try mergeTarget ?? defaultBranches(repository: repository).mergeTarget
        let remotes = try git(repository, ["remote"]).output.split(whereSeparator: \.isNewline).map(String.init)
        if let remote = remotes.first(where: { $0 == "origin" }) ?? remotes.first,
           try git(repository, ["check-ref-format", "--branch", target], allowFailure: true).status == 0 {
            let trackingRef = "refs/remotes/\(remote)/\(target)"
            let fetch = try git(
                repository,
                ["fetch", "--quiet", "--no-tags", remote, "+refs/heads/\(target):\(trackingRef)"],
                allowFailure: true
            )
            if fetch.status == 0, try isCommit(repository: repository, trackingRef) { return "\(remote)/\(target)" }
        }
        guard try isCommit(repository: repository, target) else {
            throw BridgeCommandError(code: "operation_failed", message: "The merge target '\(target)' doesn't exist in \(repository) or on its remotes.")
        }
        return target
    }

    static func preflightRemoval(_ record: RepositoryWorktreeRecord) throws {
        let status = try git(record.worktreePath, ["status", "--porcelain", "--untracked-files=all"]).output
        guard status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BridgeCommandError(code: "operation_failed", message: "Can't mark this task Done because its worktree has uncommitted changes: \(record.worktreePath)")
        }
    }

    /// Commits the worktree's changes. An in-progress merge is always concluded, even
    /// when its result matches HEAD (the remote commits were already present), so a
    /// leftover MERGE_HEAD can't make the next merge fail.
    static func commitChanges(_ record: RepositoryWorktreeRecord, message: String) throws {
        let status = try git(record.worktreePath, ["status", "--porcelain", "--untracked-files=all"]).output
        guard try !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hasMergeInProgress(record) else { return }
        _ = try git(record.worktreePath, ["add", "-A"])
        _ = try git(record.worktreePath, ["commit", "-m", message])
    }

    static func publishBranch(_ record: RepositoryWorktreeRecord) throws {
        guard let remote = try resolvedRemote(record) else {
            throw BridgeCommandError(code: "operation_failed", message: "The task branch has no Git remote configured for publishing.")
        }
        _ = try git(record.worktreePath, ["push", "--set-upstream", remote, record.branch])
    }

    /// The remote the task branch publishes to: its configured remote, else origin.
    static func resolvedRemote(_ record: RepositoryWorktreeRecord) throws -> String? {
        let configuredRemote = try git(record.worktreePath, ["config", "--get", "branch.\(record.branch).remote"], allowFailure: true)
        let remotes = Set(try git(record.worktreePath, ["remote"]).output
            .split(whereSeparator: \.isNewline).map(String.init))
        let configuredName = configuredRemote.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return remotes.contains(configuredName) ? configuredName : (remotes.contains("origin") ? "origin" : nil)
    }

    /// Fetches the task branch from its remote and reports how the local branch
    /// relates to it. FETCH_HEAD is left pointing at the remote branch so a
    /// following merge uses exactly the fetched commit.
    static func fetchRemoteBranchState(_ record: RepositoryWorktreeRecord) throws -> RemoteBranchSyncState {
        guard let remote = try resolvedRemote(record) else {
            return RemoteBranchSyncState(remote: nil, remoteBranchExists: false, aheadCount: 0, behindCount: 0)
        }
        let fetch = try git(record.worktreePath, ["fetch", "--quiet", remote, record.branch], allowFailure: true)
        guard fetch.status == 0 else {
            if fetch.error.localizedCaseInsensitiveContains("couldn't find remote ref") {
                return RemoteBranchSyncState(remote: remote, remoteBranchExists: false, aheadCount: 0, behindCount: 0)
            }
            throw BridgeCommandError(code: "operation_failed", message: fetch.error.isEmpty ? "Git couldn't fetch the task branch from \(remote)." : fetch.error)
        }
        let ahead = Int(try git(record.worktreePath, ["rev-list", "--count", "FETCH_HEAD..HEAD"]).output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let behind = Int(try git(record.worktreePath, ["rev-list", "--count", "HEAD..FETCH_HEAD"]).output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        return RemoteBranchSyncState(remote: remote, remoteBranchExists: true, aheadCount: ahead, behindCount: behind)
    }

    /// Merges the branch commit the last fetch produced, leaving conflicts in the
    /// working tree for resolution. Status 1 means the merge stopped on conflicts.
    static func mergeFetchedRemoteBranch(_ record: RepositoryWorktreeRecord) throws {
        let result = try git(record.worktreePath, ["merge", "--no-commit", "--no-ff", "FETCH_HEAD"], allowFailure: true)
        guard result.status == 0 || result.status == 1 else {
            throw BridgeCommandError(code: "operation_failed", message: gitFailureMessage(result, fallback: "Git couldn't merge the remote task branch."))
        }
    }

    /// Git reports fatal errors on stderr, so prefer it over stdout in failure messages.
    private static func gitFailureMessage(_ result: GitResult, fallback: String) -> String {
        let detail = [result.error, result.output.trimmingCharacters(in: .whitespacesAndNewlines)].first { !$0.isEmpty }
        return detail.map { "\(fallback) \($0)" } ?? fallback
    }

    /// Syncing commits, merges, and pushes through the worktree's HEAD, so it is only
    /// safe while HEAD is the task branch. An agent that switched the worktree to
    /// another branch would otherwise get the PR branch merged into that branch.
    static func requireTaskBranchCheckedOut(_ record: RepositoryWorktreeRecord) throws {
        let current = try git(record.worktreePath, ["branch", "--show-current"]).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard current == record.branch else {
            let checkedOut = current.isEmpty ? "a detached HEAD" : "branch '\(current)'"
            throw BridgeCommandError(
                code: "operation_failed",
                message: "The task worktree \(record.worktreePath) is on \(checkedOut), not its pull request branch '\(record.branch)'. Switch it back to '\(record.branch)' and sync again."
            )
        }
    }

    static func hasChanges(_ record: RepositoryWorktreeRecord) throws -> Bool {
        let status = try git(record.worktreePath, ["status", "--porcelain", "--untracked-files=all"]).output
        return !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether the branch holds commits its merge target lacks. GitHub rejects a
    /// pull request without any ("No commits between ..."). Without a configured
    /// merge target there is nothing to compare, so GitHub decides.
    static func hasCommitsAheadOfMergeTarget(_ record: RepositoryWorktreeRecord) throws -> Bool {
        guard record.mergeTarget?.isEmpty == false else { return true }
        let targetRef = try mergeTargetRef(record)
        let count = try git(record.worktreePath, ["rev-list", "--count", "\(targetRef)..HEAD"]).output
        return (Int(count.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1) > 0
    }

    static func headOid(_ record: RepositoryWorktreeRecord) throws -> String {
        try git(record.worktreePath, ["rev-parse", "HEAD"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
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
            throw BridgeCommandError(code: "operation_failed", message: gitFailureMessage(result, fallback: "Git couldn't merge the target branch."))
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
        guard record.createdByPlayhouse,
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
            guard !base.hasPrefix("-") else {
                throw BridgeCommandError(code: "invalid_argument", message: "Branch-from names can't begin with a hyphen.")
            }
            if try isCommit(repository: repository, base) { return base }
            if let remoteBase = try remoteBase(repository: repository, branch: base) { return remoteBase }
            throw BridgeCommandError(code: "invalid_argument", message: "Branch-from '\(base)' doesn't exist in \(repository) or on its remotes.")
        }
        // New tasks start from the remote's copy of the default branch rather than a
        // possibly stale local one; the worktree refreshes it when it's created.
        let local = try (defaults ?? defaultBranches(repository: repository)).branchFrom
        guard !local.isEmpty, try isCommit(repository: repository, "refs/remotes/origin/\(local)") else { return local }
        return "origin/\(local)"
    }

    /// Brings an `origin/<branch>` base up to date before a worktree starts from it.
    /// A failed fetch (offline, auth) keeps the last fetched commit, so the task still starts.
    private static func refreshOriginBase(repository: String, base: String) throws {
        let prefix = "origin/"
        guard base.hasPrefix(prefix), base.count > prefix.count else { return }
        let branch = String(base.dropFirst(prefix.count))
        guard try isCommit(repository: repository, "refs/remotes/origin/\(branch)") else { return }
        _ = try fetchTrackingRef(repository: repository, remote: "origin", branch: branch)
    }

    /// Fetches one branch into its remote-tracking ref without ever waiting on a person or
    /// a dead connection: no credential or SSH prompts, and stalled transfers give up, so a
    /// caller holding task or repository locks sees an ordinary fetch failure instead of a hang.
    private static func fetchTrackingRef(repository: String, remote: String, branch: String) throws -> GitResult {
        var environment = ["GIT_TERMINAL_PROMPT": "0"]
        let configuredSSH = try git(repository, ["config", "--get", "core.sshCommand"], allowFailure: true).output
        let environmentSSH = ["GIT_SSH_COMMAND", "GIT_SSH"].contains { PlayhouseProcessEnvironment.current[$0] != nil }
        if !environmentSSH,
           configuredSSH.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            environment["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes -o ConnectTimeout=15"
        }
        return try git(
            repository,
            [
                "-c", "http.lowSpeedLimit=1000", "-c", "http.lowSpeedTime=20",
                "fetch", "--quiet", "--no-tags", remote, "+refs/heads/\(branch):refs/remotes/\(remote)/\(branch)",
            ],
            allowFailure: true,
            environment: environment
        )
    }

    private static func isCommit(repository: String, _ ref: String) throws -> Bool {
        try git(repository, ["rev-parse", "--verify", "--quiet", "\(ref)^{commit}"], allowFailure: true).status == 0
    }

    /// Resolves a branch that isn't local to its remote-tracking ref, fetching it
    /// when the remote has it but it was never fetched. Origin is tried first.
    /// A name already qualified with a remote ("origin/feature") fetches that branch.
    private static func remoteBase(repository: String, branch: String) throws -> String? {
        let remotes = try git(repository, ["remote"]).output.split(whereSeparator: \.isNewline).map(String.init)
            .sorted { lhs, rhs in lhs == "origin" && rhs != "origin" }
        var candidates = remotes.map { (remote: $0, branch: branch) }
        if let qualified = remotes.first(where: { branch.hasPrefix("\($0)/") && branch.count > $0.count + 1 }) {
            candidates.insert((qualified, String(branch.dropFirst(qualified.count + 1))), at: 0)
        }
        var fetchFailure: String?
        for candidate in candidates {
            guard try git(repository, ["check-ref-format", "--branch", candidate.branch], allowFailure: true).status == 0 else { continue }
            let trackingRef = "refs/remotes/\(candidate.remote)/\(candidate.branch)"
            if try isCommit(repository: repository, trackingRef) { return "\(candidate.remote)/\(candidate.branch)" }
            let fetch = try fetchTrackingRef(repository: repository, remote: candidate.remote, branch: candidate.branch)
            if fetch.status == 0, try isCommit(repository: repository, trackingRef) {
                return "\(candidate.remote)/\(candidate.branch)"
            }
            // A remote that answered without the branch just lacks it; any other
            // failure (offline, auth) must not be reported as a missing branch.
            if fetch.status != 0, !fetch.error.localizedCaseInsensitiveContains("couldn't find remote ref") {
                fetchFailure = fetchFailure ?? "Git couldn't fetch '\(candidate.branch)' from \(candidate.remote): \(fetch.error.isEmpty ? "unknown error" : fetch.error)"
            }
        }
        if let fetchFailure {
            throw BridgeCommandError(code: "operation_failed", message: fetchFailure)
        }
        return nil
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

    private struct GitResult { let status: Int32; let output: String; var error: String = "" }

    private static func git(
        _ path: String,
        _ arguments: [String],
        allowFailure: Bool = false,
        environment: [String: String]? = nil
    ) throws -> GitResult {
        let candidates = (PlayhouseProcessEnvironment.current["PATH"] ?? "").split(separator: ":").map {
            URL(fileURLWithPath: String($0)).appendingPathComponent("git").path
        } + ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"]
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw BridgeCommandError(code: "operation_failed", message: "Git couldn't be found. Install Git and try again.")
        }
        let result = try PlayhouseProcessRunner.run(
            executable: executable,
            arguments: ["-C", path] + arguments,
            environment: environment
        )
        let text = String(data: result.stdout, encoding: .utf8) ?? ""
        let detail = String(data: result.stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard result.status == 0 || allowFailure else {
            throw BridgeCommandError(code: "operation_failed", message: detail.isEmpty ? "Git command failed." : detail)
        }
        return GitResult(status: result.status, output: text, error: detail)
    }
}

struct PlayhouseProcessResult {
    let status: Int32
    let stdout: Data
    let stderr: Data
}

enum PlayhouseProcessRunner {
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
        directory: String? = nil,
        environment overrides: [String: String]? = nil
    ) throws -> PlayhouseProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = PlayhouseProcessEnvironment.current.merging(overrides ?? [:]) { _, override in override }
        if overrides != nil {
            // A caller asking for a non-interactive environment also gets no terminal to read from.
            process.standardInput = FileHandle.nullDevice
        }
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
        return PlayhouseProcessResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }
}

enum PlayhouseBackgroundOperation {
    /// Runs synchronous, possibly slow work (git, `gh`) off the main actor.
    /// `Task.detached` drops task-local values, so without restoring the
    /// calling request's environment and diagnostics scope here, this work
    /// would see the daemon's own bare process environment instead of its
    /// caller's (for example a worktree-relative `PATH` override, or a test
    /// harness's `PLAYHOUSE_E2E_*` fixture overrides).
    static func run<Value: Sendable>(
        priority: TaskPriority = .utility,
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        let requestContext = await PlayhouseRequestContext.capture()
        return try await Task.detached(priority: priority) {
            try await requestContext.run {
                try operation()
            }
        }.value
    }
}

@MainActor
struct PlayhouseWorktreeService {

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
            fields["createdByPlayhouse"] = String(record.createdByPlayhouse)
        }
        fields["operationID"] = UUID().uuidString
        let startedAt = DispatchTime.now().uptimeNanoseconds
        PlayhouseDiagnostics.record("git.operation.started", fields: fields)
        do {
            let result = try await body()
            var resultFields = fields
            resultFields["durationMilliseconds"] = String((DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000)
            if let changed = result as? Bool { resultFields["hasChanges"] = String(changed) }
            PlayhouseDiagnostics.record("git.operation.succeeded", fields: resultFields)
            return result
        } catch {
            var failureFields = fields
            failureFields.merge(PlayhouseDiagnostics.errorFields(error)) { _, new in new }
            failureFields["durationMilliseconds"] = String((DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000)
            PlayhouseDiagnostics.record("git.operation.failed", fields: failureFields)
            throw error
        }
    }

    func pendingRecord(spec: RepositoryWorktreeSpec) async throws -> RepositoryWorktreeRecord {
        try await perform("worktree.prepare", fields: ["repositoryPath": spec.repositoryPath]) {
            try await PlayhouseBackgroundOperation.run {
                try PlayhouseWorktreeManager.pendingRecord(spec: spec)
            }
        }
    }

    func resolve(
        spec: RepositoryWorktreeSpec,
        title: String,
        root: URL,
        reservedBranches: Set<String> = []
    ) async throws -> RepositoryWorktreeRecord {
        try await perform("worktree.create", fields: [
            "repositoryPath": spec.repositoryPath,
            "branch": spec.branch ?? "auto",
            "branchFrom": spec.branchFrom ?? "",
            "mergeTarget": spec.mergeTarget ?? "",
            "managedRoot": root.path
        ]) {
            try await PlayhouseBackgroundOperation.run {
                try PlayhouseWorktreeManager.resolve(spec: spec, title: title, root: root, reservedBranches: reservedBranches)
            }
        }
    }

    func hasChanges(_ record: RepositoryWorktreeRecord) async throws -> Bool {
        try await perform("worktree.check_changes", record: record) {
            try await PlayhouseBackgroundOperation.run {
                try PlayhouseWorktreeManager.hasChanges(record)
            }
        }
    }

    func hasMergeConflicts(_ record: RepositoryWorktreeRecord) async throws -> Bool {
        try await perform("git.check_merge_conflicts", record: record, fields: ["mergeTarget": record.mergeTarget ?? ""]) {
            try await PlayhouseBackgroundOperation.run {
                try PlayhouseWorktreeManager.hasMergeConflicts(record)
            }
        }
    }

    func mergeTarget(_ record: RepositoryWorktreeRecord, target: String) async throws {
        try await perform("git.merge_target", record: record, fields: ["mergeTarget": target]) {
            try await PlayhouseBackgroundOperation.run { try PlayhouseWorktreeManager.mergeTarget(record, target: target) }
        }
    }

    func hasUnmergedFiles(_ record: RepositoryWorktreeRecord) async throws -> Bool {
        try await perform("git.check_unmerged_files", record: record) {
            try await PlayhouseBackgroundOperation.run { try PlayhouseWorktreeManager.hasUnmergedFiles(record) }
        }
    }

    func hasMergeInProgress(_ record: RepositoryWorktreeRecord) async throws -> Bool {
        try await perform("git.check_merge_in_progress", record: record) {
            try await PlayhouseBackgroundOperation.run { try PlayhouseWorktreeManager.hasMergeInProgress(record) }
        }
    }

    func freshMergeTargetBase(repositoryPath: String, mergeTarget: String?) async throws -> String {
        try await perform("worktree.fresh_base", fields: ["repositoryPath": repositoryPath, "mergeTarget": mergeTarget ?? ""]) {
            try await PlayhouseBackgroundOperation.run {
                try PlayhouseWorktreeManager.freshMergeTargetBase(repositoryPath: repositoryPath, mergeTarget: mergeTarget)
            }
        }
    }

    func remove(_ record: RepositoryWorktreeRecord) async throws {
        try await perform("worktree.remove", record: record) {
            try await PlayhouseBackgroundOperation.run {
                try PlayhouseWorktreeManager.remove(record)
            }
        }
    }

    func removeAfterConfirmation(_ record: RepositoryWorktreeRecord) async throws {
        try await perform("worktree.remove_after_confirmation", record: record) {
            try await PlayhouseBackgroundOperation.run {
                try PlayhouseWorktreeManager.removeAfterConfirmation(record)
            }
        }
    }

    func commitChanges(_ record: RepositoryWorktreeRecord, message: String) async throws {
        try await perform("git.commit", record: record, fields: ["commitMessageBytes": String(message.utf8.count)]) {
            try await PlayhouseBackgroundOperation.run {
                try PlayhouseWorktreeManager.commitChanges(record, message: message)
            }
        }
    }

    func hasCommitsAheadOfMergeTarget(_ record: RepositoryWorktreeRecord) async throws -> Bool {
        try await perform("git.has_commits_ahead", record: record) {
            try await PlayhouseBackgroundOperation.run {
                try PlayhouseWorktreeManager.hasCommitsAheadOfMergeTarget(record)
            }
        }
    }

    func headOid(_ record: RepositoryWorktreeRecord) async throws -> String {
        try await perform("git.head_oid", record: record) {
            try await PlayhouseBackgroundOperation.run {
                try PlayhouseWorktreeManager.headOid(record)
            }
        }
    }

    func publishBranch(_ record: RepositoryWorktreeRecord) async throws {
        try await perform("git.publish_branch", record: record) {
            try await PlayhouseBackgroundOperation.run {
                try PlayhouseWorktreeManager.publishBranch(record)
            }
        }
    }

    func fetchRemoteBranchState(_ record: RepositoryWorktreeRecord) async throws -> RemoteBranchSyncState {
        try await perform("git.fetch_branch_state", record: record) {
            try await PlayhouseBackgroundOperation.run {
                try PlayhouseWorktreeManager.fetchRemoteBranchState(record)
            }
        }
    }

    func requireTaskBranchCheckedOut(_ record: RepositoryWorktreeRecord) async throws {
        try await perform("git.require_task_branch", record: record) {
            try await PlayhouseBackgroundOperation.run {
                try PlayhouseWorktreeManager.requireTaskBranchCheckedOut(record)
            }
        }
    }

    func mergeFetchedRemoteBranch(_ record: RepositoryWorktreeRecord) async throws {
        try await perform("git.merge_remote_branch", record: record) {
            try await PlayhouseBackgroundOperation.run {
                try PlayhouseWorktreeManager.mergeFetchedRemoteBranch(record)
            }
        }
    }
}

/// How a task branch relates to the same branch on its publishing remote.
struct RemoteBranchSyncState: Sendable {
    let remote: String?
    let remoteBranchExists: Bool
    let aheadCount: Int
    let behindCount: Int
}
