import AppKit
import SwiftUI

/// The task card's pull request controls, the built-in plugin
/// `BuiltInPlugins.pullRequestsID`. It is written in Swift but composed only
/// of atoms, and it does only what a JavaScript plugin can:
/// - the create button runs `task.pr.create`;
/// - each linked pull request (and those of worktrees the task removed) is a
///   link coloured by what `task.pr.status` last reported;
/// - in Review, a task whose pull requests have all merged gets a check that
///   moves it to Done (`Playhouse.ui.moveTask`, trusting the merge it just
///   saw), one with conflicts gets a
///   button that opens it to resolve them (`Playhouse.ui.resolveConflicts`),
///   and one whose local branch and pull request have diverged is synced with
///   `task.pr.sync`;
/// - failures show as an alert (`Playhouse.ui.alert`).
/// It probes when it appears, when the task moves (`task.statusChanged`) and
/// when the app comes to the front (`app.focus`), through the shared
/// `PluginThrottle` (`Playhouse.throttle`), and again a few minutes later
/// while checks are still running.
struct PullRequestsPlugin: View {
    let host: PluginHost
    let props: [String: PluginValue]

    @State private var probedStates: [PullRequestReviewState]?
    /// Each task's last probe, so a card rebuilt (on the way back to the
    /// board) keeps its colours and conflict action while it probes again;
    /// a JavaScript plugin keeps the same in its saved state.
    private static var lastProbed: [String: [PullRequestReviewState]] = [:]
    @State private var isCreating = false
    @State private var isSyncing = false
    /// Each local/remote head pairing is synced once, so a repository the sync
    /// can't act on keeps its conflict action without a retry loop.
    @State private var attemptedSyncSignature: String?
    @State private var isPollScheduled = false

    private var task: [String: PluginValue] { props["task"]?.object ?? [:] }
    private var taskID: String { task["id"]?.string ?? "" }
    private var status: String { task["status"]?.string ?? "" }
    private var isInReview: Bool { status == TaskStatus.review.rawValue }
    private var repositories: [[String: PluginValue]] { props["repositories"]?.array?.compactMap(\.object) ?? [] }

    private struct PullRequestLink: Equatable {
        var repositoryPath: String
        var number: Int
        var url: String
        var merged: Bool
    }

    private static func link(_ repositoryPath: String?, _ pullRequest: [String: PluginValue]?) -> PullRequestLink? {
        guard let pullRequest, let number = pullRequest["number"]?.int, let url = pullRequest["url"]?.string, URL(string: url) != nil else { return nil }
        return PullRequestLink(repositoryPath: repositoryPath ?? "", number: number, url: url, merged: pullRequest["merged"] == .bool(true))
    }

    private var states: [PullRequestReviewState]? { probedStates ?? Self.lastProbed[taskID] }

    private func remember(_ states: [PullRequestReviewState]?) {
        probedStates = states
        Self.lastProbed[taskID] = states
    }

    private var linked: [PullRequestLink] { repositories.compactMap { Self.link($0["repositoryPath"]?.string, $0["pullRequest"]?.object) } }
    private var pastLinks: [PullRequestLink] {
        (props["pastPullRequests"]?.array ?? []).compactMap { $0.object.flatMap { Self.link($0["repositoryPath"]?.string, $0) } }
    }

    /// What decides when to probe: the task, its column, and its linked pull requests.
    private var probeKey: String { "\(taskID):\(status):\(linked.map { "\($0.number)\($0.merged)" }.joined(separator: ","))" }
    private var throttleKey: String { "pr-status:\(taskID)" }

    var body: some View {
        AtomStack(props: StackProps(axis: "h", spacing: 5)) {
            controls
        }
        .task(id: probeKey) { requestProbe() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in requestProbe() }
    }

    // MARK: Controls

    @ViewBuilder
    private var controls: some View {
        // Absent until the task has started and has a repository.
        if status != TaskStatus.backlog.rawValue, !repositories.isEmpty {
            if let create = createButton {
                AtomButton(
                    props: ButtonProps(style: "borderless", emphasis: 10, disabled: isCreating),
                    common: AtomCommon(testID: "task-create-pr-\(taskID)", label: create.label, help: create.help, width: 30, height: 30),
                    action: createPullRequests
                ) {
                    if isCreating {
                        AtomSpinner(props: SpinnerProps(size: "mini"))
                    } else {
                        AtomText(props: TextProps(text: create.title, size: 10, weight: "semibold"))
                    }
                }
            }
            if allMerged {
                // The capsule hugs the small check and the 30 pt slot centers it.
                AtomStack(props: StackProps(axis: "h"), common: AtomCommon(width: 30, height: 30)) {
                    AtomButton(
                        props: ButtonProps(style: "borderless", emphasis: 10, overhang: true),
                        common: AtomCommon(testID: "task-complete-merged-pr-\(taskID)", label: "Green checkmark. Complete task, all linked pull requests merged", help: "Complete task: all linked pull requests have merged"),
                        action: { ui("moveTask", ["taskID": .string(taskID), "status": .string(TaskStatus.done.rawValue), "pullRequestsMerged": .bool(true)]) }
                    ) {
                        AtomIcon(props: IconProps(name: "checkmark", size: 11, weight: "bold", color: "green"))
                    }
                }
            } else {
                if hasConflicts {
                    AtomButton(
                        props: ButtonProps(style: "borderless", emphasis: 10),
                        common: AtomCommon(testID: "task-resolve-pr-conflicts-\(taskID)", label: "Resolve pull request conflicts", help: "Resolve pull request conflicts with \(providerName)"),
                        action: { ui("resolveConflicts", ["taskID": .string(taskID)]) }
                    ) {
                        AtomIcon(props: IconProps(asset: "ConflictIndicator", color: "orange"), common: AtomCommon(testID: "task-resolve-pr-conflicts-icon-\(taskID)", width: 16, height: 16))
                    }
                }
                links
            }
        } else {
            links
        }
    }

    /// Pull requests from before the task renewed its worktree stay on the
    /// card (merged ones in purple), ahead of the current ones.
    @ViewBuilder
    private var links: some View {
        let current = status != TaskStatus.backlog.rawValue && !repositories.isEmpty ? linked : []
        ForEach(Array((pastLinks + current).enumerated()), id: \.offset) { index, link in
            let health = index < pastLinks.count ? (link.merged ? PullRequestHealth.merged : nil) : health(of: link)
            AtomLink(
                props: LinkProps(url: link.url, emphasis: 5),
                common: AtomCommon(
                    testID: "task-pr-link-\(taskID)-\(link.number)", value: health?.rawValue ?? "unknown",
                    help: URL(fileURLWithPath: link.repositoryPath).lastPathComponent + (health.map { " · \(Self.healthDescription($0))" } ?? ""),
                    minWidth: 30, minHeight: 30
                )
            ) {
                AtomText(props: TextProps(text: "#\(link.number)", size: 10, weight: "semibold", design: "monospaced", color: Self.healthColor(health)))
            }
        }
    }

    private struct CreateButton {
        var title: String
        var label: String
        var help: String
    }

    /// Repositories PR creation found unchanged drop out of the count, so a
    /// two-repository task that changed one offers a single "PR". While the
    /// task is worked on with no pull request yet, the mode pill stands in for
    /// the button: the mode opens the pull request when the task reaches Review.
    private var createButton: CreateButton? {
        let awaiting = repositories.filter { $0["awaitsPullRequest"] == .bool(true) }
        let started = repositories.filter { $0["isPending"] != .bool(true) }
        let plural = (awaiting.isEmpty ? started : awaiting).count > 1
        if linked.isEmpty {
            guard ![TaskStatus.inProgress, .blocked, .waitingResponse].map(\.rawValue).contains(status) else { return nil }
            return CreateButton(
                title: plural ? "PRs" : "PR",
                label: plural ? "PRs. Create pull requests for each repository linked to this task" : "PR. Create a pull request for each repository linked to this task",
                help: "Create a pull request for each repository linked to this task"
            )
        }
        guard !awaiting.isEmpty else { return nil }
        return CreateButton(
            title: plural ? "PRs" : "PR",
            label: plural ? "PRs. Create pull requests for repositories without a linked pull request" : "PR. Create a pull request for the repository without a linked pull request",
            help: "Create pull requests for repositories without a linked pull request"
        )
    }

    /// Every linked pull request merged, as last probed, or as the task
    /// recorded them before its first probe. A merge the task records (the
    /// pull request mode's) changes `probeKey`, which probes again.
    private var allMerged: Bool {
        guard isInReview, !linked.isEmpty else { return false }
        guard let states, !states.isEmpty else { return linked.allSatisfy(\.merged) }
        return states.allSatisfy(\.merged)
    }

    private var hasConflicts: Bool {
        isInReview && !linked.isEmpty && (states?.contains(where: \.requiresConflictResolution) ?? false)
    }

    private var providerName: String {
        ConversationProvider(rawValue: task["provider"]?.string ?? "")?.displayName ?? "the agent"
    }

    /// A link keeps its last probed colour while the task is worked on, and
    /// before any probe shows merged if the task recorded it so.
    private func health(of link: PullRequestLink) -> PullRequestHealth? {
        states?.first { $0.number == link.number && $0.repositoryPath == link.repositoryPath }?.health
            ?? states?.first { $0.number == link.number }?.health
            ?? (link.merged ? .merged : nil)
    }

    static func healthColor(_ health: PullRequestHealth?) -> String {
        switch health {
        case .green: "green"
        case .red: "red"
        case .pending: "blue"
        case .merged: "purple"
        case nil: "accent"
        }
    }

    static func healthDescription(_ health: PullRequestHealth) -> String {
        switch health {
        case .green: "checks passing"
        case .red: "checks failing or conflicted"
        case .pending: "checks running"
        case .merged: "merged"
        }
    }

    // MARK: Actions

    private func ui(_ name: String, _ arguments: [String: PluginValue]) {
        Task { try? await host.call("ui", name, arguments) }
    }

    private func alert(_ error: Error) async {
        try? await host.call("ui", "alert", ["title": .string("Pull request operation failed"), "message": .string(PullRequestModePlugin.message(error))])
    }

    private func createPullRequests() {
        guard !isCreating else { return }
        isCreating = true
        let taskID = taskID
        Task {
            defer { isCreating = false }
            do {
                try await host.call("bridge", "task.pr.create", ["taskID": .string(taskID)])
            } catch {
                await alert(error)
            }
        }
    }

    // MARK: Probing

    /// Open pull requests are worth asking GitHub about; in Review, so are
    /// merged ones, since the merged check follows the latest probe.
    private var shouldProbe: Bool {
        status != TaskStatus.backlog.rawValue && status != TaskStatus.done.rawValue
            && (isInReview ? !linked.isEmpty : linked.contains { !$0.merged })
    }

    private func requestProbe(resetCooldown: Bool = false) {
        guard shouldProbe else {
            if linked.isEmpty { remember(nil) }
            return
        }
        if resetCooldown { PluginThrottle.shared.reset(throttleKey) }
        PluginThrottle.shared.run(throttleKey) { await probe() }
    }

    private func probe() async {
        let taskID = taskID
        guard shouldProbe else { return }
        do {
            let probed = try await host.bridge("task.pr.status", ["taskID": .string(taskID), "shared": .bool(true)], as: [PullRequestReviewState].self)
            guard taskID == self.taskID else { return }
            // An empty answer is a store that hasn't caught up yet; keep the colours.
            if !probed.isEmpty { remember(probed) }
            if isInReview { syncIfNeeded(probed) }
            if probed.contains(where: { $0.health == .pending }) { schedulePoll() }
        } catch {
            // A card that already knows its task left Review stays quiet. One still holding
            // Review when the task moved to Done is answered by the daemon, whose status read
            // reports no state for a Done task whose worktrees are gone.
            guard taskID == self.taskID, isInReview else { return }
            await alert(error)
        }
    }

    /// While checks run, look again in a few minutes.
    private func schedulePoll() {
        guard !isPollScheduled else { return }
        isPollScheduled = true
        Task {
            try? await Task.sleep(for: .seconds(PullRequestModeService.pollInterval))
            isPollScheduled = false
            requestProbe()
        }
    }

    /// A reviewed task must not hold local-only pull request changes: when the
    /// local and remote heads of a mergeable PR differ, `task.pr.sync` commits,
    /// merges the remote PR commits and pushes. The daemon moves the task to
    /// Blocked when a sync fails.
    private func syncIfNeeded(_ states: [PullRequestReviewState]) {
        let needsSync = states.contains { !$0.merged && !$0.hasConflicts && $0.headRefOid != nil && $0.headRefOid != $0.localHeadOid }
        guard needsSync, !isSyncing else { return }
        let signature = states.map { "\($0.number):\($0.headRefOid ?? "-"):\($0.localHeadOid ?? "-")" }.sorted().joined(separator: "|")
        guard attemptedSyncSignature != signature else { return }
        attemptedSyncSignature = signature
        isSyncing = true
        let taskID = taskID
        Task {
            defer { isSyncing = false }
            do {
                let outcome = try await host.bridge("task.pr.sync", ["taskID": .string(taskID)], as: PullRequestSyncOutcome.self)
                if outcome.skipped != nil {
                    // An active turn owns the worktree; a later probe retries.
                    attemptedSyncSignature = nil
                    return
                }
                guard outcome.records.contains(where: { $0.action.hasSuffix("pushed") }) else { return }
                requestProbe(resetCooldown: true)
            } catch {
                attemptedSyncSignature = nil
                await alert(error)
            }
        }
    }
}
