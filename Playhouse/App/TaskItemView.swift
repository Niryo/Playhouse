import SwiftUI

/// What a board card shows, already derived from its task: plain values a
/// native card and a plugin (as `Playhouse.props.task`) compose the same way.
struct TaskItemModel: Codable, Equatable {
    struct Progress: Codable, Equatable {
        var label: String
        var detail: String?
        var symbol: String
    }

    struct Tokens: Codable, Equatable {
        var compact: String
        /// #RRGGBB on the token heatmap.
        var color: String
        var description: String
    }

    struct CPU: Codable, Equatable {
        var fraction: Double
        var label: String
    }

    struct CreateButton: Codable, Equatable {
        var title: String
        var label: String
        var help: String
        var busy: Bool
    }

    struct PullRequestLink: Codable, Equatable {
        var number: Int
        var url: String
        var color: String
        var help: String
        var health: String
    }

    /// The bottom row, left to right: create, the merged check (which
    /// replaces the rest), conflicts, the mode pill, the linked pull requests.
    struct PullRequests: Codable, Equatable {
        var create: CreateButton?
        var mergedCheck: Bool
        var conflictsHelp: String?
        var showModePill: Bool
        var mode: String
        var modes: [PillPickerProps.Option]
        var links: [PullRequestLink]
    }

    var id: String
    var title: String
    var titleSpinner: Bool
    var progress: Progress?
    var schedule: String?
    var statusMessage: String?
    var statusIsBlocked: Bool
    /// In progress: the time row counts up from `workingSince` (seconds since
    /// 1970) plus `workedSeconds`; otherwise it shows `createdText`.
    var isWorking: Bool
    var workingSince: Double?
    var workedSeconds: Double
    var createdText: String
    var tokens: Tokens?
    var cpu: CPU?
    var pullRequests: PullRequests?
    var canMoveToDone: Bool
    var canMoveToReview: Bool

    func workingDuration(at date: Date) -> String {
        let active = workingSince.map { max(0, date.timeIntervalSince1970 - $0) } ?? 0
        let activeText = Self.shortDuration(active)
        guard workedSeconds > 0 else { return activeText }
        return "\(activeText) (\(Self.shortDuration(workedSeconds + active)) total)"
    }

    static func shortDuration(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(Int(seconds))s" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h\(minutes % 60 == 0 ? "" : " \(minutes % 60)m")" }
        let days = hours / 24
        return "\(days)d\(hours % 24 == 0 ? "" : " \(hours % 24)h")"
    }

    static func modeOptions(taskID: String) -> [PillPickerProps.Option] {
        PullRequestMode.allCases.map {
            PillPickerProps.Option(value: $0.rawValue, label: $0.label, help: $0.helpText, testID: "task-pr-mode-\($0.rawValue)-\(taskID)")
        }
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
}

extension TaskItemModel {
    init(
        task: BoardTask,
        cpuPercent: Double?,
        cpuUsageColorMax: Int,
        tokenUsageColorMax: Int,
        isCreatingPullRequests: Bool,
        isPullRequestMerged: Bool,
        hasPullRequestConflicts: Bool,
        pullRequestHealth: [Int: PullRequestHealth],
        canMoveToDone: Bool,
        canMoveToReview: Bool
    ) {
        let taskID = task.id.uuidString
        id = taskID
        title = task.title
        titleSpinner = task.title == "Generating title…"
        if let label = task.progressLabel, !label.isEmpty {
            progress = Progress(
                label: label,
                detail: task.progressDetail.flatMap { $0.isEmpty ? nil : $0 },
                symbol: TaskProgressType(rawValue: task.progressTypeRawValue ?? "")?.symbol ?? "sparkle"
            )
        }
        if task.scheduleKind == .once, let scheduledAt = task.scheduledAt {
            schedule = ScheduleFormatting.relativeTime(scheduledAt)
        }
        statusMessage = task.statusMessage.flatMap { $0.isEmpty ? nil : $0 }
        statusIsBlocked = task.status == .blocked
        isWorking = task.status == .inProgress
        workingSince = task.inProgressStartedAt?.timeIntervalSince1970
        workedSeconds = task.totalInProgressSeconds
        createdText = task.createdAt.formatted(date: .abbreviated, time: .omitted)
        // A zero counter says nothing yet, so it stays hidden until the task has sent tokens.
        if task.counterTokens > 0 {
            let description = task.hasCallUsage
                ? "\(TokenUsageHeatmap.compact(task.totalSentTokens)) tokens sent · \(task.totalCalls) \(task.totalCalls == 1 ? "call" : "calls") · \(TokenUsageHeatmap.compact(task.finalTranscriptTokens)) final transcript"
                : TokenUsageHeatmap.label(totalTokens: task.totalTokens)
            tokens = Tokens(
                compact: TokenUsageHeatmap.compact(task.counterTokens),
                color: AtomColor.hex(TokenUsageHeatmap.color(totalTokens: task.counterTokens, max: tokenUsageColorMax)),
                description: description
            )
        }
        cpu = cpuPercent.map { CPU(fraction: CPUUsageHeatmap.fraction(percent: $0, max: cpuUsageColorMax), label: CPUUsageHeatmap.label(percent: $0)) }
        self.canMoveToDone = canMoveToDone
        self.canMoveToReview = canMoveToReview

        // Absent until the task has started and has a repository.
        guard task.status != .backlog, !task.repositoryWorktrees.isEmpty else { return }
        let linked = task.repositoryWorktrees.filter { $0.pullRequestNumber != nil && $0.pullRequestURL != nil }
        let started = task.repositoryWorktrees.filter { !$0.isPending }
        let plural = started.count > 1
        // While the task is still being worked on, the mode pill replaces the
        // manual create button: once it reaches Review, PR and Auto modes
        // create the pull request themselves.
        let isAutoPRWorkingState = [.inProgress, .blocked, .waitingResponse].contains(task.status)
        var pullRequests = PullRequests(
            mergedCheck: false,
            showModePill: true,
            mode: task.pullRequestMode.rawValue,
            modes: Self.modeOptions(taskID: taskID),
            links: []
        )
        if linked.isEmpty && isAutoPRWorkingState {
            // Only the pill.
        } else if linked.isEmpty {
            pullRequests.showModePill = false
            pullRequests.create = CreateButton(
                title: plural ? "PRs" : "PR",
                label: plural ? "PRs. Create pull requests for each repository linked to this task" : "PR. Create a pull request for each repository linked to this task",
                help: "Create a pull request for each repository linked to this task",
                busy: isCreatingPullRequests
            )
        } else {
            if task.repositoryWorktrees.contains(where: { !$0.isPending && ($0.pullRequestNumber == nil || $0.pullRequestURL == nil) }) {
                pullRequests.create = CreateButton(
                    title: plural ? "PRs" : "PR",
                    label: plural ? "PRs. Create pull requests for repositories without a linked pull request" : "PR. Create a pull request for the repository without a linked pull request",
                    help: "Create pull requests for repositories without a linked pull request",
                    busy: isCreatingPullRequests
                )
            }
            pullRequests.mergedCheck = isPullRequestMerged && canMoveToDone
            if hasPullRequestConflicts {
                pullRequests.conflictsHelp = "Resolve pull request conflicts with \(task.conversationProvider.displayName)"
            }
            pullRequests.links = linked.compactMap { record in
                guard let number = record.pullRequestNumber, let url = record.pullRequestURL, URL(string: url) != nil else { return nil }
                let health = pullRequestHealth[number]
                return PullRequestLink(
                    number: number,
                    url: url,
                    color: Self.healthColor(health),
                    help: URL(fileURLWithPath: record.repositoryPath).lastPathComponent + (health.map { " · \(Self.healthDescription($0))" } ?? ""),
                    health: health?.rawValue ?? "unknown"
                )
            }
        }
        self.pullRequests = pullRequests
    }
}

/// What a card's controls do. Menu ids: done, review, rename, stats, delete.
struct TaskItemActions {
    var open: () -> Void = {}
    var menu: (String) -> Void = { _ in }
    var showTokenStats: () -> Void = {}
    var createPullRequests: () -> Void = {}
    var setPullRequestMode: (String) -> Void = { _ in }
    var moveToDone: () -> Void = {}
    var resolveConflicts: () -> Void = {}
}

/// The board's task item, composed only of plugin atoms (Plugins/Atoms), so a
/// plugin building the same item from the same atoms looks identical.
/// Rows, top to bottom: the title, the live progress report, the schedule,
/// the status message, the time with the token counter, then the
/// pull-request controls on the right.
struct TaskItemView: View {
    let model: TaskItemModel
    var actions = TaskItemActions()

    private var id: String { model.id }

    var body: some View {
        AtomCard(props: cardProps, common: AtomCommon(testID: "task-card-\(id)", label: model.title, hint: "Open task", fillWidth: true, padding: 14), onPress: actions.open, onMenu: actions.menu) {
            AtomStack(props: StackProps(axis: "v", spacing: 10, align: "leading")) {
                // Every row but the token counter and the pull-request controls
                // lets clicks through to the card.
                AtomStack(props: StackProps(axis: "h", spacing: 6), common: AtomCommon(testID: "task-title-\(id)", passThrough: true)) {
                    if model.titleSpinner { AtomSpinner() }
                    AtomText(props: TextProps(text: model.title, size: 13, weight: "semibold", color: "text", tracking: 0.35, lineSpacing: 2, wrap: true))
                }

                if let progress = model.progress {
                    AtomStack(
                        props: StackProps(axis: "h", spacing: 6, align: "top", group: true),
                        common: AtomCommon(
                            testID: "task-progress-report-\(id)",
                            label: [progress.label, progress.detail].compactMap { $0 }.joined(separator: ", "),
                            value: "Progress icon: \(progress.symbol)",
                            fillWidth: true,
                            passThrough: true
                        )
                    ) {
                        AtomIcon(props: IconProps(name: progress.symbol, size: 10, weight: "semibold", color: "accent"), common: AtomCommon(testID: "task-progress-icon-\(id)", label: progress.symbol))
                        AtomStack(props: StackProps(axis: "v", spacing: 2, align: "leading")) {
                            AtomText(props: TextProps(text: progress.label, size: 10, weight: "semibold", color: "text"), common: AtomCommon(testID: "task-progress-label-\(id)"))
                            if let detail = progress.detail {
                                AtomText(props: TextProps(text: detail, size: 10, color: "secondary", lineLimit: 2), common: AtomCommon(testID: "task-progress-detail-\(id)"))
                            }
                        }
                    }
                }

                if let schedule = model.schedule {
                    AtomLabel(props: LabelProps(text: schedule, icon: "clock", size: 10, weight: "medium", color: "accent"), common: AtomCommon(testID: "task-schedule-badge-\(id)", passThrough: true))
                }

                if let statusMessage = model.statusMessage {
                    AtomText(
                        props: TextProps(text: statusMessage, size: 10, color: model.statusIsBlocked ? "red" : "secondary", lineLimit: 3),
                        common: AtomCommon(testID: "task-status-message-\(id)", fillWidth: true, passThrough: true)
                    )
                }

                timeRow

                if let pullRequests = model.pullRequests {
                    AtomStack(props: StackProps(axis: "h", spacing: 8), common: AtomCommon(minHeight: 30)) {
                        AtomSpacer(props: SpacerProps(minLength: 8))
                        AtomStack(props: StackProps(axis: "h", spacing: 5)) {
                            pullRequestControls(pullRequests)
                        }
                    }
                }
            }
        }
    }

    private var cardProps: CardProps {
        var menu: [CardProps.MenuItem] = []
        if model.canMoveToDone { menu.append(.init(id: "done", title: "Move to Done", icon: "checkmark.circle", testID: "move-task-to-done-menu-item")) }
        if model.canMoveToReview { menu.append(.init(id: "review", title: "Move to Review", icon: "eye", testID: "move-task-to-review-menu-item")) }
        menu.append(.init(id: "rename", title: "Rename…", icon: "pencil", testID: "rename-task-menu-item"))
        menu.append(.init(id: "stats", title: "Token Stats…", icon: "chart.bar", testID: "token-stats-task-menu-item"))
        menu.append(.init(id: "delete", title: "Delete Task", icon: "trash", destructive: true, testID: "delete-task-menu-item"))
        return CardProps(menu: menu, meter: model.cpu?.fraction, meterLabel: model.cpu?.label, meterTestID: "task-cpu-usage-bar-\(id)")
    }

    private var timeRow: some View {
        // One row of clock, time and counter, as the card had before the atoms.
        AtomStack(props: StackProps(axis: "h", spacing: 6)) {
            AtomIcon(props: IconProps(name: "clock", size: 10, color: "tertiary"), common: AtomCommon(passThrough: true))
            if model.isWorking {
                // The clock only drives the string; the view is the Text atom.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    AtomText(props: TextProps(text: model.workingDuration(at: context.date), size: 10, color: "tertiary"), common: AtomCommon(testID: "task-working-duration-\(id)", passThrough: true))
                }
            } else {
                AtomText(props: TextProps(text: model.createdText, size: 10, color: "tertiary"), common: AtomCommon(testID: "task-created-time-\(id)", passThrough: true))
            }
            if let tokens = model.tokens {
                TokenCounterButton(tokens: tokens, testID: "task-token-usage-counter-\(id)", action: actions.showTokenStats)
            }
        }
    }

    @ViewBuilder
    private func pullRequestControls(_ pullRequests: TaskItemModel.PullRequests) -> some View {
        if let create = pullRequests.create {
            AtomButton(
                props: ButtonProps(style: "borderless", emphasis: 10, disabled: create.busy),
                common: AtomCommon(testID: "task-create-pr-\(id)", label: create.label, help: create.help, width: 30, height: 30),
                action: actions.createPullRequests
            ) {
                if create.busy {
                    AtomSpinner(props: SpinnerProps(size: "mini"))
                } else {
                    AtomText(props: TextProps(text: create.title, size: 10, weight: "semibold"))
                }
            }
        }
        if pullRequests.mergedCheck {
            // The capsule hugs the small check and the 30 pt slot centers it.
            AtomStack(props: StackProps(axis: "h"), common: AtomCommon(width: 30, height: 30)) {
                AtomButton(
                    props: ButtonProps(style: "borderless", emphasis: 10, overhang: true),
                    common: AtomCommon(testID: "task-complete-merged-pr-\(id)", label: "Green checkmark. Complete task, all linked pull requests merged", help: "Complete task: all linked pull requests have merged"),
                    action: actions.moveToDone
                ) {
                    AtomIcon(props: IconProps(name: "checkmark", size: 11, weight: "bold", color: "green"))
                }
            }
        } else {
            if let conflictsHelp = pullRequests.conflictsHelp {
                AtomButton(
                    props: ButtonProps(style: "borderless", emphasis: 10),
                    common: AtomCommon(testID: "task-resolve-pr-conflicts-\(id)", label: "Resolve pull request conflicts", help: conflictsHelp),
                    action: actions.resolveConflicts
                ) {
                    AtomIcon(props: IconProps(asset: "ConflictIndicator", color: "orange"), common: AtomCommon(testID: "task-resolve-pr-conflicts-icon-\(id)", width: 16, height: 16))
                }
            }
            if pullRequests.showModePill {
                AtomPillPicker(
                    props: PillPickerProps(options: pullRequests.modes, selected: pullRequests.mode),
                    common: AtomCommon(testID: "task-pr-mode-\(id)", label: "Pull request mode", help: "How Playhouse handles this task's pull request. {help}. Click to choose another mode."),
                    onChange: actions.setPullRequestMode
                )
            }
            ForEach(Array(pullRequests.links.enumerated()), id: \.offset) { _, link in
                AtomLink(props: LinkProps(url: link.url, emphasis: 5), common: AtomCommon(testID: "task-pr-link-\(id)-\(link.number)", value: link.health, help: link.help, minWidth: 30, minHeight: 30)) {
                    AtomText(props: TextProps(text: "#\(link.number)", size: 10, weight: "semibold", design: "monospaced", color: link.color))
                }
            }
        }
    }
}
