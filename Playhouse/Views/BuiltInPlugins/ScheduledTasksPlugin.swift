import Foundation
import PlayhouseAtoms
import PlayhouseCore
import PlayhouseUI

/// The board sidebar's Scheduled Tasks popover (`BuiltInPlugins.scheduledTasksID`):
/// every scheduled task from `props.schedules`. A schedule is created and
/// edited in the ordinary task conversation, so the popover only lists, pauses,
/// runs and deletes them, through `schedule.pause`, `schedule.resume`,
/// `schedule.run-now` and `task.delete`; opening a row returns to that
/// conversation with `ui.openTask`, which closes the popover, as clicking
/// outside it or Escape does.
/// Composed only of atoms; the delete question is `ui.confirm`, asked inside the popover.
package struct ScheduledTasksPlugin: PHView {
    package let host: PluginHost
    package let props: [String: PluginValue]
    @PHState private var errorMessage: String?
    @PHState private var runningTaskIDs = Set<UUID>()

    private var schedules: [String: PluginValue] { props["schedules"]?.object ?? [:] }

    /// `schedule.list`'s tasks, decoded through the JSON the bridge encoded them with.
    private var scheduledTasks: Result<[BoardTaskRecord], Error> {
        guard let tasks = schedules["tasks"] else { return .success([]) }
        return Result { try BridgeValue(plugin: tasks).decoded([BoardTaskRecord].self) }
    }

    package var body: some PHView {
        let decoded = scheduledTasks
        let tasks = (try? decoded.get()) ?? []
        let decodeError = { if case .failure(let error) = decoded { return "Couldn't read the scheduled tasks: \(error.localizedDescription)" } else { return nil } }() as String?
        PHVStack(alignment: .leading, spacing: 0) {
            header
            AtomDivider()
            if let errorMessage = errorMessage ?? decodeError {
                AtomText(
                    props: TextProps(text: errorMessage, size: 12, color: "red"),
                    common: AtomCommon(testID: "scheduled-tasks-error", fillWidth: true, paddingX: 16, paddingY: 8)
                )
            }
            if schedules["needsLoginItemsApproval"]?.bool == true {
                AtomStack(props: StackProps(axis: "h", spacing: 6), common: AtomCommon(paddingX: 16)) {
                    AtomText(props: TextProps(text: "Allow Playhouse in Login Items so scheduled tasks run while it's closed.", size: 10, color: "secondary"))
                    AtomButton(
                        props: ButtonProps(style: "link"),
                        common: AtomCommon(testID: "scheduled-tasks-login-items-button", help: "Open Login Items in System Settings"),
                        action: { perform { try await host.call("ui", "openLoginItems") } }
                    ) {
                        AtomText(props: TextProps(text: "Open Settings", size: 10))
                    }
                }
                .padding(.top, 10)
            }
            if tasks.isEmpty {
                AtomStack(props: StackProps(spacing: 6, group: true), common: AtomCommon(testID: "scheduled-tasks-empty")) {
                    AtomStack(props: StackProps(spacing: 6, combine: true)) {
                        AtomText(props: TextProps(text: "No scheduled tasks", size: 13, weight: "semibold"))
                        AtomText(props: TextProps(text: "Write a task, then use the clock beside Send to schedule it.", size: 12, color: "secondary"))
                    }
                    AtomButton(
                        props: ButtonProps(style: "automatic", controlSize: "large"),
                        common: AtomCommon(testID: "scheduled-tasks-empty-new-task-button", help: "Write a task and choose when it runs"),
                        action: newTask
                    ) {
                        AtomLabel(props: LabelProps(text: "New Task", icon: PHIcon.plus.name))
                    }
                    .padding(.top, 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                AtomScroll(props: ScrollProps(spacing: 8, inset: 16, lazy: true), common: AtomCommon(testID: "scheduled-tasks-list")) {
                    // `schedule.list` is already soonest first.
                    section("Recurring", tasks: tasks.filter { $0.schedule?.kind == TaskScheduleKind.recurring.rawValue }, identifier: "scheduled-tasks-recurring")
                    section("One-time", tasks: tasks.filter { $0.schedule?.kind == TaskScheduleKind.once.rawValue }, identifier: "scheduled-tasks-one-time")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some PHView {
        AtomStack(props: StackProps(axis: "h", spacing: 8), common: AtomCommon(paddingX: 16, paddingY: 12)) {
            AtomLabel(props: LabelProps(text: "Scheduled Tasks", icon: PHIcon.clock.name, size: 15, weight: "semibold"), common: AtomCommon(testID: "scheduled-tasks-title"))

            AtomSpacer()

            AtomButton(
                props: ButtonProps(style: "automatic", controlSize: "small"),
                common: AtomCommon(testID: "scheduled-new-task-button", help: "Write a task and choose when it runs"),
                action: newTask
            ) {
                AtomLabel(props: LabelProps(text: "New Task", icon: PHIcon.plus.name))
            }
        }
    }

    @PHViewBuilder
    private func section(_ title: String, tasks: [BoardTaskRecord], identifier: String) -> some PHView {
        if !tasks.isEmpty {
            AtomText(props: TextProps(text: title.uppercased(), size: 10, weight: "semibold", color: "secondary"), common: AtomCommon(testID: identifier))
                .padding(.top, 6)
            PHForEach(tasks) { row($0) }
        }
    }

    private func row(_ task: BoardTaskRecord) -> some PHView {
        let id = task.id.uuidString
        let paused = task.schedule?.paused == true
        let repositories = task.repositoryWorktrees.map { URL(fileURLWithPath: $0.repositoryPath).lastPathComponent }
        return AtomPanel(
            props: PanelProps(fill: "panel", fillOpacity: 1, cornerRadius: 10),
            common: AtomCommon(testID: "scheduled-task-row-\(id)", padding: 0, paddingX: 12, paddingY: 9)
        ) {
            AtomStack(props: StackProps(axis: "h", spacing: 10)) {
                // A press area rather than a Button: a Button folds its label into one element,
                // which would hide the title and summary from accessibility. The press area
                // covers its column, so the full-width title makes the whole row clickable.
                AtomPressArea(
                    props: PressAreaProps(spacing: 4, pointer: true),
                    common: AtomCommon(testID: "scheduled-task-open-\(id)", help: "Edit this scheduled task", fillWidth: true),
                    onPress: { open(task.id) },
                    onLongPress: { open(task.id) }
                ) {
                    AtomText(
                        props: TextProps(text: Self.displayTitle(task), size: 13, weight: "semibold", color: paused ? "secondary" : "primary", lineLimit: 1),
                        common: AtomCommon(testID: "scheduled-task-title-\(id)", fillWidth: true)
                    )
                    AtomText(props: TextProps(text: Self.summary(task), size: 12, color: "secondary", lineLimit: 1), common: AtomCommon(testID: "scheduled-task-summary-\(id)"))
                    if !repositories.isEmpty {
                        AtomText(props: TextProps(text: repositories.joined(separator: " · "), size: 10, color: "tertiary", lineLimit: 1))
                    }
                }
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { open(task.id) }

                if task.schedule?.kind == TaskScheduleKind.recurring.rawValue {
                    AtomToggle(
                        props: ToggleProps(isOn: !paused, size: "mini"),
                        common: AtomCommon(
                            testID: "scheduled-task-active-\(id)", label: "\(task.title) active",
                            help: paused ? "Resume this schedule" : "Pause this schedule"
                        ),
                        onToggle: { setPaused(task, !paused) }
                    )
                }

                AtomMenu(
                    props: MenuProps(icon: PHIcon.ellipsis.name, items: [
                        [
                            MenuProps.Item(
                                id: "run-now", title: "Run Now", help: "Start a run now",
                                testID: "scheduled-task-run-now-\(id)", disabled: runningTaskIDs.contains(task.id)
                            ),
                        ] + (task.schedule?.lastRunTaskID == nil ? [] : [
                            MenuProps.Item(id: "last-run", title: "Open Last Run", help: "Open the task the last run created", testID: "scheduled-task-last-run-\(id)"),
                        ]),
                        [MenuProps.Item(id: "delete", title: "Delete…", destructive: true, help: "Delete this scheduled task", testID: "scheduled-task-delete-\(id)")],
                    ]),
                    common: AtomCommon(testID: "scheduled-task-actions-\(id)", label: "More actions", help: "More actions", width: 22, height: 22),
                    onMenu: { choice in
                        switch choice {
                        case "run-now": runNow(task)
                        case "last-run": if let lastRun = task.schedule?.lastRunTaskID { openLastRun(lastRun) }
                        default: delete(task)
                        }
                    }
                )
            }
        }
    }

    /// The task's title, or its prompt's first line while the title is still a placeholder.
    package static func displayTitle(_ task: BoardTaskRecord) -> String {
        guard ["Untitled task", "Generating title…"].contains(task.title),
              let prompt = task.schedule?.prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty else {
            return task.title
        }
        return prompt.split(separator: "\n").first.map(String.init) ?? task.title
    }

    package static func summary(_ task: BoardTaskRecord) -> String {
        guard let schedule = task.schedule else { return "" }
        if schedule.kind == TaskScheduleKind.recurring.rawValue {
            if schedule.paused { return "\(schedule.summary) · Paused" }
            guard let next = schedule.scheduledAt else { return schedule.summary }
            return "\(schedule.summary) · Next \(ScheduleFormatting.relativeTime(next))"
        }
        return schedule.scheduledAt.map { ScheduleFormatting.relativeTime($0) } ?? ""
    }

    private func newTask() {
        perform { try await host.call("ui", "newTask", ["schedule": .string(TaskScheduleKind.recurring.rawValue)]) }
    }

    /// The popover closes for the task.
    private func open(_ taskID: UUID) {
        perform { try await host.call("ui", "openTask", ["taskID": .string(taskID.uuidString)]) }
    }

    /// The run is an ordinary task, and the popover closes for it too.
    private func openLastRun(_ taskID: UUID) {
        perform { try await host.call("ui", "openTask", ["taskID": .string(taskID.uuidString)]) }
    }

    private func setPaused(_ task: BoardTaskRecord, _ paused: Bool) {
        perform { try await host.call("bridge", paused ? "schedule.pause" : "schedule.resume", ["taskID": .string(task.id.uuidString)]) }
    }

    private func runNow(_ task: BoardTaskRecord) {
        runningTaskIDs.insert(task.id)
        perform {
            defer { runningTaskIDs.remove(task.id) }
            try await host.call("bridge", "schedule.run-now", ["taskID": .string(task.id.uuidString)])
        }
    }

    private func delete(_ task: BoardTaskRecord) {
        perform {
            let answer = await host.answer(kind: "ui", name: "confirm", arguments: .object([
                "title": .string("Delete \(task.title)?"),
                "message": .string(task.schedule?.kind == TaskScheduleKind.recurring.rawValue
                    ? "Runs that already started stay on the board."
                    : "The task is removed from the board."),
                "confirm": .string("Delete"),
                "destructive": .bool(true)
            ]))
            guard case .success(.bool(true)) = answer else { return }
            try await host.call("bridge", "task.delete", ["taskID": .string(task.id.uuidString)])
        }
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        errorMessage = nil
        Task { @MainActor in
            do { try await operation() } catch { errorMessage = (error as? PluginHostError)?.message ?? error.localizedDescription }
        }
    }

    package init(host: PluginHost, props: [String: PluginValue]) {
        self.host = host
        self.props = props
    }
}
