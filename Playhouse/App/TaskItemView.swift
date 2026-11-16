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
    /// Whether the card keeps a bottom row for its task card plugins (the
    /// built-in pull request controls and mode pill among them): once the task
    /// has started and has a repository.
    var hasPluginRow: Bool
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
}

extension TaskItemModel {
    init(
        task: BoardTask,
        cpuPercent: Double?,
        cpuUsageColorMax: Int,
        tokenUsageColorMax: Int,
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

        hasPluginRow = task.status != .backlog && !task.repositoryWorktrees.isEmpty
    }
}

/// What a card's controls do. Menu ids: done, review, rename, stats, delete.
struct TaskItemActions {
    var open: () -> Void = {}
    var menu: (String) -> Void = { _ in }
    var showTokenStats: () -> Void = {}
}

/// The board's task item, composed only of plugin atoms (Plugins/Atoms), so a
/// plugin building the same item from the same atoms looks identical.
/// Rows, top to bottom: the title, the live progress report, the schedule,
/// the status message, the time with the token counter, then the row of
/// task card plugins (`PluginPlacement.taskItem`) on the right, among them
/// the built-in pull request controls and mode pill.
struct TaskItemView: View {
    let model: TaskItemModel
    var actions = TaskItemActions()
    /// The bottom row's plugins; the board passes its `TaskItemPluginRow`.
    var pluginRow: AnyView?

    private var id: String { model.id }

    var body: some View {
        AtomCard(props: cardProps, common: AtomCommon(testID: "task-card-\(id)", label: model.title, hint: "Open task", fillWidth: true, padding: 14), onPress: actions.open, onMenu: actions.menu) {
            AtomStack(props: StackProps(axis: "v", spacing: 10, align: "leading")) {
                // Every row but the token counter and the plugin row
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

                if let pluginRow {
                    pluginRow
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
}
