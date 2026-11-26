import Foundation

/// The board's task item described as an atom tree (the atom-tree spike; see
/// docs/atom-tree-performance.md): the same atoms, props and identifiers as
/// the native `TaskItemView`, as data. `TaskItemTreeView` renders it through
/// `AtomRegistry` when `PLAYHOUSE_TASK_ITEM_RENDERER` asks for it; the native
/// view stays the default.
///
/// Every node has a fixed id, so a reconciler updates a card in place: a new
/// token count changes one Text node, a progress report appearing adds one
/// subtree. The working time, which the native card redraws from a
/// `TimelineView`, is a plain Text here that the host re-renders once a
/// second from `spec(model:now:)`: atoms have no clock.
enum TaskItemTree {
    /// The slot the board's plugin row (`TaskItemPluginRow`) fills.
    static let pluginRowSlot = "pluginRow"

    enum ID {
        static let card = 1, column = 2, titleRow = 3, spinner = 4, title = 5
        static let progress = 6, progressIcon = 7, progressColumn = 8, progressLabel = 9, progressDetail = 10
        static let schedule = 11, status = 12
        static let timeRow = 13, clock = 14, time = 15, tokenButton = 16, tokenText = 17
        static let pluginRow = 18
    }

    static func spec(model: TaskItemModel, now: Date) -> AtomNodeSpec {
        let id = model.id
        var rows: [AtomNodeSpec] = []

        var title: [AtomNodeSpec] = []
        if model.titleSpinner { title.append(AtomNodeSpec(ID.spinner, SpinnerProps())) }
        title.append(AtomNodeSpec(ID.title, TextProps(text: model.title, size: 13, weight: "semibold", color: "text", tracking: 0.35, lineSpacing: 2, wrap: true)))
        rows.append(AtomNodeSpec(ID.titleRow, StackProps(axis: "h", spacing: 6), AtomCommon(testID: "task-title-\(id)", passThrough: true), children: title))

        if let progress = model.progress {
            var lines = [AtomNodeSpec(ID.progressLabel, TextProps(text: progress.label, size: 10, weight: "semibold", color: "text"), AtomCommon(testID: "task-progress-label-\(id)"))]
            if let detail = progress.detail {
                lines.append(AtomNodeSpec(ID.progressDetail, TextProps(text: detail, size: 10, color: "secondary", lineLimit: 2), AtomCommon(testID: "task-progress-detail-\(id)")))
            }
            rows.append(AtomNodeSpec(
                ID.progress,
                StackProps(axis: "h", spacing: 6, align: "top", group: true),
                AtomCommon(
                    testID: "task-progress-report-\(id)",
                    label: [progress.label, progress.detail].compactMap { $0 }.joined(separator: ", "),
                    value: "Progress icon: \(progress.symbol)",
                    fillWidth: true,
                    passThrough: true
                ),
                children: [
                    AtomNodeSpec(ID.progressIcon, IconProps(name: progress.symbol, size: 10, weight: "semibold", color: "accent"), AtomCommon(testID: "task-progress-icon-\(id)", label: progress.symbol)),
                    AtomNodeSpec(ID.progressColumn, StackProps(axis: "v", spacing: 2, align: "leading"), children: lines),
                ]
            ))
        }

        if let schedule = model.schedule {
            rows.append(AtomNodeSpec(ID.schedule, LabelProps(text: schedule, icon: "clock", size: 10, weight: "medium", color: "accent"), AtomCommon(testID: "task-schedule-badge-\(id)", passThrough: true)))
        }

        if let statusMessage = model.statusMessage {
            rows.append(AtomNodeSpec(
                ID.status,
                TextProps(text: statusMessage, size: 10, color: model.statusIsBlocked ? "red" : "secondary", lineLimit: 3),
                AtomCommon(testID: "task-status-message-\(id)", fillWidth: true, passThrough: true)
            ))
        }

        var time = [AtomNodeSpec(ID.clock, IconProps(name: "clock", size: 10, color: "tertiary"), AtomCommon(passThrough: true))]
        if model.isWorking {
            time.append(AtomNodeSpec(ID.time, TextProps(text: model.workingDuration(at: now), size: 10, color: "tertiary"), AtomCommon(testID: "task-working-duration-\(id)", passThrough: true)))
        } else {
            time.append(AtomNodeSpec(ID.time, TextProps(text: model.createdText, size: 10, color: "tertiary"), AtomCommon(testID: "task-created-time-\(id)", passThrough: true)))
        }
        if let tokens = model.tokens {
            // As `TokenCounterButton` composes it.
            time.append(AtomNodeSpec(
                ID.tokenButton,
                ButtonProps(emphasis: 6, overhang: true),
                AtomCommon(testID: "task-token-usage-counter-\(id)", label: tokens.description, hint: "Open Token Stats", help: "\(tokens.description). Click for Token Stats", paddingX: 4),
                events: ["onPress"],
                children: [AtomNodeSpec(ID.tokenText, TextProps(text: tokens.compact, size: 10, weight: "medium", design: "monospaced", color: tokens.color, numeric: true))]
            ))
        }
        rows.append(AtomNodeSpec(ID.timeRow, StackProps(axis: "h", spacing: 6), children: time))
        rows.append(.slot(ID.pluginRow, pluginRowSlot))

        return AtomNodeSpec(
            ID.card,
            cardProps(model),
            AtomCommon(testID: "task-card-\(id)", label: model.title, hint: "Open task", fillWidth: true, padding: 14),
            events: ["onPress", "onMenu"],
            children: [AtomNodeSpec(ID.column, StackProps(axis: "v", spacing: 10, align: "leading"), children: rows)]
        )
    }

    static func cardProps(_ model: TaskItemModel) -> CardProps {
        var menu: [CardProps.MenuItem] = []
        if model.canMoveToDone { menu.append(.init(id: "done", title: "Move to Done", icon: "checkmark.circle", testID: "move-task-to-done-menu-item")) }
        if model.canMoveToReview { menu.append(.init(id: "review", title: "Move to Review", icon: "eye", testID: "move-task-to-review-menu-item")) }
        menu.append(.init(id: "rename", title: "Rename…", icon: "pencil", testID: "rename-task-menu-item"))
        menu.append(.init(id: "stats", title: "Token Stats…", icon: "chart.bar", testID: "token-stats-task-menu-item"))
        menu.append(.init(id: "delete", title: "Delete Task", icon: "trash", destructive: true, testID: "delete-task-menu-item"))
        return CardProps(menu: menu, meter: model.cpu?.fraction, meterLabel: model.cpu?.label, meterTestID: "task-cpu-usage-bar-\(model.id)")
    }
}
