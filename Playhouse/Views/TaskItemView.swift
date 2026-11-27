import Foundation
import PlayhouseAtoms
import PlayhouseCore
import PlayhouseUI

/// What a board card shows, already derived from its task: plain values a
/// native card and a plugin (as `Playhouse.props.task`) compose the same way.
package struct TaskItemModel: Codable, Equatable {
    package struct Progress: Codable, Equatable {
        package var label: String
        package var detail: String?
        package var symbol: String

        package init(label: String, detail: String? = nil, symbol: String) {
            self.label = label
            self.detail = detail
            self.symbol = symbol
        }
    }

    package struct Tokens: Codable, Equatable {
        package var compact: String
        /// #RRGGBB on the token heatmap.
        package var color: String
        package var description: String

        package init(compact: String, color: String, description: String) {
            self.compact = compact
            self.color = color
            self.description = description
        }
    }

    package struct CPU: Codable, Equatable {
        package var fraction: Double
        package var label: String

        package init(fraction: Double, label: String) {
            self.fraction = fraction
            self.label = label
        }
    }

    package var id: String
    package var title: String
    package var titleSpinner: Bool
    package var progress: Progress?
    package var schedule: String?
    package var statusMessage: String?
    package var statusIsBlocked: Bool
    /// In progress: the time row counts up from `workingSince` (seconds since
    /// 1970) plus `workedSeconds`; otherwise it shows `createdText`.
    package var isWorking: Bool
    package var workingSince: Double?
    package var workedSeconds: Double
    package var createdText: String
    package var tokens: Tokens?
    package var cpu: CPU?
    /// Whether the card keeps a bottom row for its task card plugins (the
    /// built-in pull request controls and mode pill among them): once the task
    /// has started and has a repository.
    package var hasPluginRow: Bool
    package var canMoveToDone: Bool
    package var canMoveToReview: Bool

    package func workingDuration(at date: Date) -> String {
        let active = workingSince.map { max(0, date.timeIntervalSince1970 - $0) } ?? 0
        let activeText = Self.shortDuration(active)
        guard workedSeconds > 0 else { return activeText }
        return "\(activeText) (\(Self.shortDuration(workedSeconds + active)) total)"
    }

    package static func shortDuration(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(Int(seconds))s" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h\(minutes % 60 == 0 ? "" : " \(minutes % 60)m")" }
        let days = hours / 24
        return "\(days)d\(hours % 24 == 0 ? "" : " \(hours % 24)h")"
    }

    package init(id: String, title: String, titleSpinner: Bool, progress: Progress? = nil, schedule: String? = nil, statusMessage: String? = nil, statusIsBlocked: Bool, isWorking: Bool, workingSince: Double? = nil, workedSeconds: Double, createdText: String, tokens: Tokens? = nil, cpu: CPU? = nil, hasPluginRow: Bool, canMoveToDone: Bool, canMoveToReview: Bool) {
        self.id = id
        self.title = title
        self.titleSpinner = titleSpinner
        self.progress = progress
        self.schedule = schedule
        self.statusMessage = statusMessage
        self.statusIsBlocked = statusIsBlocked
        self.isWorking = isWorking
        self.workingSince = workingSince
        self.workedSeconds = workedSeconds
        self.createdText = createdText
        self.tokens = tokens
        self.cpu = cpu
        self.hasPluginRow = hasPluginRow
        self.canMoveToDone = canMoveToDone
        self.canMoveToReview = canMoveToReview
    }
}

extension TaskItemModel {
    package init(
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
                symbol: (TaskProgressType(rawValue: task.progressTypeRawValue ?? "")?.icon ?? .sparkle).name
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
package struct TaskItemActions {
    package var open: () -> Void = {}
    package var menu: (String) -> Void = { _ in }
    package var showTokenStats: () -> Void = {}

    package init(open: @escaping () -> Void = {}, menu: @escaping (String) -> Void = { _ in }, showTokenStats: @escaping () -> Void = {}) {
        self.open = open
        self.menu = menu
        self.showTokenStats = showTokenStats
    }
}

/// The board's task item, composed only of plugin atoms (Plugins/Atoms), so a
/// plugin building the same item from the same atoms looks identical.
/// Rows, top to bottom: the title, the live progress report, the schedule,
/// the status message, the time with the token counter, then the row of
/// task card plugins (`PluginPlacement.taskItem`) on the right, among them
/// the built-in pull request controls and mode pill.
package struct TaskItemView: PHView {
    package let model: TaskItemModel
    package var actions = TaskItemActions()
    /// The bottom row's plugins; the board passes its `TaskItemPluginRow`.
    package var pluginRow: PHAnyView?

    private var id: String { model.id }

    package var body: some PHView {
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
                    AtomLabel(props: LabelProps(text: schedule, icon: PHIcon.clock.name, size: 10, weight: "medium", color: "accent"), common: AtomCommon(testID: "task-schedule-badge-\(id)", passThrough: true))
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
        if model.canMoveToDone { menu.append(.init(id: "done", title: "Move to Done", icon: PHIcon.checkmarkCircle.name, testID: "move-task-to-done-menu-item")) }
        if model.canMoveToReview { menu.append(.init(id: "review", title: "Move to Review", icon: PHIcon.eye.name, testID: "move-task-to-review-menu-item")) }
        menu.append(.init(id: "rename", title: "Rename…", icon: PHIcon.pencil.name, testID: "rename-task-menu-item"))
        menu.append(.init(id: "stats", title: "Token Stats…", icon: PHIcon.chartBar.name, testID: "token-stats-task-menu-item"))
        menu.append(.init(id: "delete", title: "Delete Task", icon: PHIcon.trash.name, destructive: true, testID: "delete-task-menu-item"))
        return CardProps(menu: menu, meter: model.cpu?.fraction, meterLabel: model.cpu?.label, meterTestID: "task-cpu-usage-bar-\(id)")
    }

    private var timeRow: some PHView {
        // One row of clock, time and counter, as the card had before the atoms.
        AtomStack(props: StackProps(axis: "h", spacing: 6)) {
            AtomIcon(props: IconProps(name: PHIcon.clock.name, size: 10, color: "tertiary"), common: AtomCommon(passThrough: true))
            if model.isWorking {
                // The clock only drives the string; the view is the Text atom.
                PHTimelineView(.periodic(from: .now, by: 1)) { context in
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

    package init(model: TaskItemModel, actions: TaskItemActions = TaskItemActions(), pluginRow: PHAnyView? = nil) {
        self.model = model
        self.actions = actions
        self.pluginRow = pluginRow
    }
}
