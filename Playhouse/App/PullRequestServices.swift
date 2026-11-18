import Foundation
import AppKit
import SwiftData
import Darwin
import SQLite3

enum GitHubPullRequestManager {
    struct PullRequest: Decodable, Sendable {
        let number: Int
        let url: String
        let baseRefName: String?
    }

    private struct PullRequestState: Decodable {
        let mergedAt: String?
    }

    /// A pull request as `gh pr list --state all` or `gh pr view <url>` reports it.
    struct PullRequestDetails: Decodable, Sendable {
        let number: Int
        let url: String
        /// OPEN, MERGED or CLOSED.
        let state: String
        let headRefName: String?

        var isMerged: Bool { state.uppercased() == "MERGED" }
        var isClosed: Bool { state.uppercased() == "CLOSED" }
    }

    private struct PullRequestReviewResponse: Decodable {
        let mergedAt: String?
        let mergeable: String?
        let headRefOid: String?
        let statusCheckRollup: [CheckRollupItem]?
        let state: String?
    }

    /// One entry of `statusCheckRollup`: a check run (`status`/`conclusion`) or a
    /// commit status context (`state`).
    private struct CheckRollupItem: Decodable {
        let name: String?
        let context: String?
        let status: String?
        let conclusion: String?
        let state: String?
        let workflowName: String?
        let startedAt: String?
        let completedAt: String?
        let createdAt: String?
        let typename: String?

        enum CodingKeys: String, CodingKey {
            case name, context, status, conclusion, state, workflowName, startedAt, completedAt, createdAt
            case typename = "__typename"
        }

        /// The key GitHub's badge groups reruns by: a check run's name within its
        /// workflow, or a status context's name.
        var identity: String {
            if typename == "StatusContext" || (name == nil && context != nil) {
                return "context\u{0}\(context ?? "")"
            }
            return "run\u{0}\(workflowName ?? "")\u{0}\(name ?? "")"
        }

        /// When this run started or was reported; nil when the rollup gave no usable time.
        var timestamp: Date? {
            for value in [startedAt, createdAt, completedAt] {
                if let value, !value.isEmpty, let date = ISO8601DateFormatter().date(from: value),
                   date.timeIntervalSince1970 > 946_684_800 { return date }  // queued runs report 0001-01-01
            }
            return nil
        }
    }

    private struct ReviewThreadsResponse: Decodable {
        struct DataPayload: Decodable { let repository: Repository? }
        struct Repository: Decodable { let pullRequest: PullRequest? }
        struct PullRequest: Decodable { let reviewThreads: Threads }
        struct Threads: Decodable { let nodes: [Thread] }
        struct Thread: Decodable { let isResolved: Bool }
        let data: DataPayload?
    }

    /// How long a pushed head may show no checks at all before that counts as a
    /// repository without CI rather than checks GitHub hasn't registered yet.
    static let checksRegistrationGrace: TimeInterval = 180

    static func reviewState(_ record: RepositoryWorktreeRecord, executable: String, includeReviewThreads: Bool = false) throws -> PullRequestReviewState {
        guard let number = record.pullRequestNumber else {
            throw BridgeCommandError(code: "invalid_transition", message: "This repository has no linked pull request.")
        }
        let result = try run(executable, ["pr", "view", String(number), "--json", "mergedAt,mergeable,headRefOid,statusCheckRollup,state"], directory: record.worktreePath)
        let response = try JSONDecoder().decode(PullRequestReviewResponse.self, from: Data(result.utf8))
        let localHead: String?
        var localHeadCommittedAt: Date?
        if response.headRefOid != nil {
            let git = try PlayhouseProcessRunner.run(executable: "/usr/bin/git", arguments: ["log", "-1", "--format=%H%n%ct", "HEAD"], directory: record.worktreePath)
            guard git.status == 0 else {
                throw BridgeCommandError(code: "operation_failed", message: "Couldn't inspect the local head for pull request #\(number).")
            }
            let lines = (String(data: git.stdout, encoding: .utf8) ?? "").split(whereSeparator: \.isNewline).map(String.init)
            localHead = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines)
            localHeadCommittedAt = lines.dropFirst().first.flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
        } else {
            localHead = nil
        }
        let checks = summarizeChecks(
            response.statusCheckRollup ?? [],
            headRecentlyCommitted: localHeadCommittedAt.map { Date().timeIntervalSince($0) < checksRegistrationGrace } ?? false
        )
        let unresolvedThreads = includeReviewThreads && response.mergedAt == nil
            ? try unresolvedReviewThreadCount(record, number: number, executable: executable)
            : nil
        return PullRequestReviewState(
            repositoryPath: record.repositoryPath, worktreePath: record.worktreePath, branch: record.branch,
            url: record.pullRequestURL, number: number,
            merged: response.mergedAt != nil, mergeable: response.mergeable ?? "UNKNOWN",
            headRefOid: response.headRefOid, localHeadOid: localHead,
            checks: checks.state, failingChecks: checks.failing,
            unresolvedReviewThreads: unresolvedThreads,
            closed: response.state == "CLOSED"
        )
    }

    /// A rerun adds a rollup entry beside the old one; GitHub's badge counts only the
    /// latest per check. Without timestamps the later rollup entry wins.
    private static func latestChecks(_ items: [CheckRollupItem]) -> [CheckRollupItem] {
        var latest: [String: (index: Int, item: CheckRollupItem)] = [:]
        for (index, item) in items.enumerated() {
            if let current = latest[item.identity] {
                if let new = item.timestamp, let old = current.item.timestamp, new < old { continue }
            }
            latest[item.identity] = (index, item)
        }
        return latest.values.sorted { $0.index < $1.index }.map(\.item)
    }

    /// Failure outranks pending, which outranks success, as on GitHub's own badge.
    /// A head with no checks yet is pending while GitHub may still register them.
    private static func summarizeChecks(_ items: [CheckRollupItem], headRecentlyCommitted: Bool) -> (state: PullRequestChecksState, failing: [String]) {
        guard !items.isEmpty else { return (headRecentlyCommitted ? .pending : .none, []) }
        let items = latestChecks(items)
        let failingConclusions: Set<String> = ["FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE", "ERROR"]
        var failing: [String] = []
        var pending = false
        for item in items {
            let label = item.name ?? item.context ?? "check"
            if let state = item.state?.uppercased() {
                if ["FAILURE", "ERROR"].contains(state) { failing.append(label) }
                else if ["PENDING", "EXPECTED"].contains(state) { pending = true }
            } else if item.status?.uppercased() != "COMPLETED" {
                pending = true
            } else if failingConclusions.contains(item.conclusion?.uppercased() ?? "") {
                failing.append(label)
            }
        }
        if !failing.isEmpty { return (.failure, Array(Set(failing)).sorted()) }
        return (pending ? .pending : .success, [])
    }

    /// Unresolved review threads are the PR comments that can be replied to and
    /// resolved; GitHub exposes them only through GraphQL.
    private static func unresolvedReviewThreadCount(_ record: RepositoryWorktreeRecord, number: Int, executable: String) throws -> Int {
        guard let url = record.pullRequestURL.flatMap(URL.init(string:)) else {
            throw BridgeCommandError(code: "operation_failed", message: "Pull request #\(number) has no URL to read its review threads from.")
        }
        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count >= 2 else {
            throw BridgeCommandError(code: "operation_failed", message: "Couldn't read the repository of pull request #\(number) from \(url.absoluteString).")
        }
        let query = "query($owner: String!, $name: String!, $number: Int!) { repository(owner: $owner, name: $name) { pullRequest(number: $number) { reviewThreads(first: 100) { nodes { isResolved } } } } }"
        let result = try run(executable, [
            "api", "graphql", "-f", "query=\(query)",
            "-f", "owner=\(components[0])", "-f", "name=\(components[1])", "-F", "number=\(number)"
        ], directory: record.worktreePath)
        let response = try JSONDecoder().decode(ReviewThreadsResponse.self, from: Data(result.utf8))
        guard let threads = response.data?.repository?.pullRequest?.reviewThreads.nodes else {
            throw BridgeCommandError(code: "operation_failed", message: "GitHub didn't return the review threads of pull request #\(number).")
        }
        return threads.filter { !$0.isResolved }.count
    }

    static func resolveExecutable() throws -> String {
        let paths = (PlayhouseProcessEnvironment.current["PATH"] ?? "").split(separator: ":").map {
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

    /// The pull request GitHub has for `branch` in any state: an open one first, then a
    /// merged one, then the most recent closed one. Nil when the branch has none.
    static func find(branch: String, record: RepositoryWorktreeRecord, executable: String) throws -> PullRequestDetails? {
        let result = try run(executable, ["pr", "list", "--head", branch, "--state", "all", "--json", "number,url,state,headRefName", "--limit", "20"], directory: record.worktreePath)
        let pullRequests = try JSONDecoder().decode([PullRequestDetails].self, from: Data(result.utf8))
        return pullRequests.first { $0.state.uppercased() == "OPEN" }
            ?? pullRequests.first(where: \.isMerged)
            ?? pullRequests.first
    }

    /// The pull request at `url`, read in the worktree's repository.
    static func view(url: String, record: RepositoryWorktreeRecord, executable: String) throws -> PullRequestDetails {
        let result = try run(executable, ["pr", "view", url, "--json", "number,url,state,headRefName"], directory: record.worktreePath)
        return try JSONDecoder().decode(PullRequestDetails.self, from: Data(result.utf8))
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

    private struct RepositoryMergeMethods: Decodable {
        let squashMergeAllowed: Bool?
        let mergeCommitAllowed: Bool?
        let rebaseMergeAllowed: Bool?
    }

    /// Merges the PR with the first method the repository allows (squash, then a
    /// merge commit, then rebase). The task branch and worktree are kept.
    /// `headOid` pins the merge to the commit autopilot saw green: GitHub refuses it
    /// if anything was pushed since.
    static func merge(_ record: RepositoryWorktreeRecord, headOid: String, executable: String) throws -> String {
        guard let number = record.pullRequestNumber else {
            throw BridgeCommandError(code: "invalid_transition", message: "This repository has no linked pull request.")
        }
        let allowed = try JSONDecoder().decode(
            RepositoryMergeMethods.self,
            from: Data(run(executable, ["repo", "view", "--json", "squashMergeAllowed,mergeCommitAllowed,rebaseMergeAllowed"], directory: record.worktreePath).utf8)
        )
        let method: String
        if allowed.squashMergeAllowed != false { method = "squash" }
        else if allowed.mergeCommitAllowed != false { method = "merge" }
        else if allowed.rebaseMergeAllowed != false { method = "rebase" }
        else {
            throw BridgeCommandError(code: "operation_failed", message: "The repository of pull request #\(number) allows no merge method.")
        }
        _ = try run(executable, ["pr", "merge", String(number), "--\(method)", "--match-head-commit", headOid], directory: record.worktreePath)
        return method
    }

    static func isMerged(_ record: RepositoryWorktreeRecord, executable: String) throws -> Bool {
        guard let number = record.pullRequestNumber else { return true }
        let result = try run(executable, ["pr", "view", String(number), "--json", "mergedAt"], directory: record.worktreePath)
        return try JSONDecoder().decode(PullRequestState.self, from: Data(result.utf8)).mergedAt != nil
    }

    private static func run(_ executable: String, _ arguments: [String], directory: String) throws -> String {
        let result: PlayhouseProcessResult
        // A quarantined test fixture script runs through its interpreter.
        let command = ConversationProviderFixture.launchCommand(executable: executable, arguments: arguments)
        do {
            result = try PlayhouseProcessRunner.run(
                executable: command.executable,
                arguments: command.arguments,
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

/// The combined CI state of a pull request's head commit. `none` is a head with
/// no checks at all (past the registration grace), which reads as green and, in
/// merge mode, merges.
enum PullRequestChecksState: String, Codable, Sendable {
    case success, failure, pending, none
}

/// The colour a linked PR number shows on its task card.
enum PullRequestHealth: String, Codable, Sendable {
    case green, red, pending, merged, closed
}

struct PullRequestReviewState: Codable, Sendable {
    let repositoryPath: String
    /// The worktree whose pull request this is; a task may hold several worktrees
    /// of one repository, each with its own pull request.
    let worktreePath: String
    let branch: String
    let url: String?
    let number: Int
    let merged: Bool
    /// Closed without merging on GitHub; nothing is left to review or merge.
    let closed: Bool
    let mergeable: String
    let headRefOid: String?
    let localHeadOid: String?
    let hasConflicts: Bool
    let isConfirmedResolved: Bool
    let checks: PullRequestChecksState
    let failingChecks: [String]
    /// Nil unless the probe asked for review threads (autopilot tasks only).
    let unresolvedReviewThreads: Int?
    let health: PullRequestHealth
    /// Set on a status read's full listing (`task pr status`) for a pull request of a
    /// worktree the task retired (renew); such entries are read from the task's
    /// records, not probed, and nothing acts on them.
    var past: Bool? = nil

    var requiresConflictResolution: Bool {
        hasConflicts || (!merged && mergeable == "MERGEABLE" && headRefOid != nil && headRefOid != localHeadOid)
    }

    init(
        repositoryPath: String, worktreePath: String, branch: String, url: String?, number: Int, merged: Bool, mergeable: String, headRefOid: String?, localHeadOid: String?,
        checks: PullRequestChecksState = .none, failingChecks: [String] = [], unresolvedReviewThreads: Int? = nil, closed: Bool = false
    ) {
        self.repositoryPath = repositoryPath
        self.worktreePath = worktreePath
        self.branch = branch
        self.url = url
        self.number = number
        self.merged = merged
        self.closed = closed && !merged
        self.mergeable = mergeable
        self.headRefOid = headRefOid
        self.localHeadOid = localHeadOid
        self.checks = checks
        self.failingChecks = failingChecks
        self.unresolvedReviewThreads = unresolvedReviewThreads
        if merged { health = .merged }
        else if self.closed { health = .closed }
        else if checks == .failure || mergeable == "CONFLICTING" { health = .red }
        else if checks == .pending { health = .pending }
        else { health = .green }
        hasConflicts = !merged && mergeable == "CONFLICTING"
        isConfirmedResolved = merged || (mergeable == "MERGEABLE" && headRefOid != nil && headRefOid == localHeadOid)
    }
}

enum PullRequestResolutionCheck: String, Codable, Sendable {
    case resolved
    case stillConflicted
    case inconclusive
}

extension PullRequestMode {
    static func parse(_ value: String) throws -> PullRequestMode {
        guard let mode = PullRequestMode(rawValue: value.lowercased()) else {
            throw BridgeCommandError(code: "invalid_argument", message: "Unknown pull request mode '\(value)'. Valid modes: manual, pr, autopilot, merge.")
        }
        return mode
    }
}

/// The `task.pr.autopilot` command's result. `action` is inactive, merged (every
/// PR is merged, by merge mode or before), green, pending, stalled (moved to
/// Waiting Response), or fixed (a fix turn ran).
struct PullRequestAutopilotOutcome: Codable, Sendable {
    let action: String
    let states: [PullRequestReviewState]
    let taskStatus: String
    let reason: String?
    /// The PRs this pass merged (merge mode); nil when it merged none.
    var mergedPullRequests: [Int]? = nil
}

/// What the review sync did to one PR-linked repository: pr-merged, no-remote,
/// no-remote-branch, up-to-date, pushed, merged-and-pushed, or resolved-and-pushed.
struct TaskBranchSyncResult: Codable, Sendable {
    let repositoryPath: String
    let action: String
}

/// The `task.pr.sync` command's result: per-repository actions, or
/// `skipped == "turn-active"` when an active turn owns the worktree.
struct PullRequestSyncOutcome: Codable, Sendable {
    let records: [TaskBranchSyncResult]
    let skipped: String?
}

struct PlayhousePullRequestService {

    /// Records which `gh` binary each operation runs, for diagnosing PATH and sign-in
    /// problems. Arguments are left out: they can carry pull request titles and bodies.
    private func recordStarted(_ operation: String, executable: String) async {
        await PlayhouseDiagnostics.record("github.cli.started", fields: ["operation": operation, "executable": executable])
    }

    func resolveExecutable() throws -> String {
        try GitHubPullRequestManager.resolveExecutable()
    }

    func findOpen(_ record: RepositoryWorktreeRecord, executable: String) async throws -> GitHubPullRequestManager.PullRequest? {
        await recordStarted("findOpen", executable: executable)
        return try await PlayhouseBackgroundOperation.run {
            try GitHubPullRequestManager.findOpen(record, executable: executable)
        }
    }

    func create(
        _ record: RepositoryWorktreeRecord,
        title: String,
        body: String,
        executable: String
    ) async throws -> GitHubPullRequestManager.PullRequest {
        await recordStarted("create", executable: executable)
        return try await PlayhouseBackgroundOperation.run {
            try GitHubPullRequestManager.create(record, title: title, body: body, executable: executable)
        }
    }

    func find(branch: String, record: RepositoryWorktreeRecord, executable: String) async throws -> GitHubPullRequestManager.PullRequestDetails? {
        await recordStarted("find", executable: executable)
        return try await PlayhouseBackgroundOperation.run {
            try GitHubPullRequestManager.find(branch: branch, record: record, executable: executable)
        }
    }

    func view(url: String, record: RepositoryWorktreeRecord, executable: String) async throws -> GitHubPullRequestManager.PullRequestDetails {
        await recordStarted("view", executable: executable)
        return try await PlayhouseBackgroundOperation.run {
            try GitHubPullRequestManager.view(url: url, record: record, executable: executable)
        }
    }

    func merge(_ record: RepositoryWorktreeRecord, headOid: String, executable: String) async throws -> String {
        await recordStarted("merge", executable: executable)
        return try await PlayhouseBackgroundOperation.run {
            try GitHubPullRequestManager.merge(record, headOid: headOid, executable: executable)
        }
    }

    func isMerged(_ record: RepositoryWorktreeRecord, executable: String) async throws -> Bool {
        await recordStarted("isMerged", executable: executable)
        return try await PlayhouseBackgroundOperation.run {
            try GitHubPullRequestManager.isMerged(record, executable: executable)
        }
    }

    func reviewState(_ record: RepositoryWorktreeRecord, executable: String, includeReviewThreads: Bool = false) async throws -> PullRequestReviewState {
        await recordStarted("reviewState", executable: executable)
        return try await PlayhouseBackgroundOperation.run {
            try GitHubPullRequestManager.reviewState(record, executable: executable, includeReviewThreads: includeReviewThreads)
        }
    }
}

enum PlayhouseManagerError: LocalizedError {
    case invalidTitle
    case taskNotFound(UUID)
    case invalidStatus(String)
    case noWorkspaceRoots
    case unavailableWorkspaceRoot(String)
    case invalidParentFolder(String)
    case invalidMessage
    case repositoryAssigned(String)
    case branchAssigned(branch: String, taskTitle: String)
    case invalidTransition(String)
    case unmergedPullRequests([Int])
    case uncommittedChanges([String])

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
        case .branchAssigned(let branch, let taskTitle):
            "Branch `\(branch)` is already used by task \"\(taskTitle)\". Choose another branch or finish that task first."
        case .invalidTransition(let message):
            message
        case .unmergedPullRequests(let numbers):
            "Pull request(s) \(numbers.map { "#\($0)" }.joined(separator: ", ")) haven't been merged. Confirm that you want to mark this task Done."
        case .uncommittedChanges(let paths):
            "Marking this task Done removes its worktree and discards the uncommitted changes in \(paths.joined(separator: ", ")). Confirm that you want to discard them."
        }
    }
}
