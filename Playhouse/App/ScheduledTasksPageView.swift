import ServiceManagement
import SwiftData
import SwiftUI

/// Lists every scheduled task. A schedule is created and edited in the ordinary task
/// conversation, so this page only lists, pauses, runs and deletes them; opening a row
/// returns to that conversation.
struct ScheduledTasksPageView: View {
    let scheduledTasks: [BoardTask]
    let remoteConversations: RemoteConversationManager
    let onNewTask: () -> Void
    let onOpenTask: (BoardTask) -> Void
    let onOpenRunTask: (UUID) -> Void
    let onClose: () -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var errorMessage: String?
    @State private var pendingDelete: BoardTask?
    @State private var runningTaskIDs = Set<UUID>()

    private var recurring: [BoardTask] {
        scheduledTasks.filter { $0.scheduleKind == .recurring }.sorted(by: Self.soonestFirst)
    }

    private var oneTime: [BoardTask] {
        scheduledTasks.filter { $0.scheduleKind == .once }.sorted(by: Self.soonestFirst)
    }

    private static func soonestFirst(_ lhs: BoardTask, _ rhs: BoardTask) -> Bool {
        (lhs.scheduledAt ?? .distantFuture) < (rhs.scheduledAt ?? .distantFuture)
    }

    /// Composed of plugin atoms (Plugins/Atoms); only the delete alert is native.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            AtomDivider()
            if let errorMessage {
                AtomText(
                    props: TextProps(text: errorMessage, size: 12, color: "red"),
                    common: AtomCommon(testID: "scheduled-tasks-error", fillWidth: true, paddingX: 20, paddingY: 8)
                )
            }
            if SchedulerAgent.requiresApproval {
                AtomStack(props: StackProps(axis: "h", spacing: 6), common: AtomCommon(paddingX: 20)) {
                    AtomText(props: TextProps(text: "Allow Playhouse in Login Items so scheduled tasks run while it's closed.", size: 10, color: "secondary"))
                    AtomButton(
                        props: ButtonProps(style: "link"),
                        common: AtomCommon(testID: "scheduled-tasks-login-items-button", help: "Open Login Items in System Settings"),
                        action: { SMAppService.openSystemSettingsLoginItems() }
                    ) {
                        AtomText(props: TextProps(text: "Open Settings", size: 10))
                    }
                }
                .padding(.top, 10)
            }
            if scheduledTasks.isEmpty {
                AtomStack(props: StackProps(spacing: 6, group: true), common: AtomCommon(testID: "scheduled-tasks-empty")) {
                    AtomStack(props: StackProps(spacing: 6, combine: true)) {
                        AtomText(props: TextProps(text: "No scheduled tasks", size: 13, weight: "semibold"))
                        AtomText(props: TextProps(text: "Write a task, then use the clock beside Send to schedule it.", size: 12, color: "secondary"))
                    }
                    AtomButton(
                        props: ButtonProps(style: "automatic", controlSize: "large"),
                        common: AtomCommon(testID: "scheduled-tasks-empty-new-task-button", help: "Write a task and choose when it runs"),
                        action: onNewTask
                    ) {
                        AtomLabel(props: LabelProps(text: "New Task", icon: "plus"))
                    }
                    .padding(.top, 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                AtomScroll(props: ScrollProps(spacing: 10, inset: 20, lazy: true), common: AtomCommon(testID: "scheduled-tasks-list")) {
                    section("Recurring", tasks: recurring, identifier: "scheduled-tasks-recurring")
                    section("One-time", tasks: oneTime, identifier: "scheduled-tasks-one-time")
                }
            }
        }
        .background(WorkspaceTheme.windowBackground)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("scheduled-tasks-page")
        .alert(
            "Delete \(pendingDelete?.title ?? "")?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { task in
            Button("Delete", role: .destructive) { delete(task) }
                .buttonHoverPointer()
                .nativeHelp("Delete this scheduled task")
                .accessibilityIdentifier("confirm-delete-scheduled-task-button")
            Button("Cancel", role: .cancel) {}
                .buttonHoverPointer()
                .nativeHelp("Keep this scheduled task")
        } message: { task in
            Text(task.scheduleKind == .recurring
                 ? "Runs that already started stay on the board."
                 : "The task is removed from the board.")
        }
    }

    private var header: some View {
        AtomStack(props: StackProps(axis: "h", spacing: 12), common: AtomCommon(paddingX: 20, paddingY: 12)) {
            AtomButton(
                props: ButtonProps(shortcut: pendingDelete == nil ? "cancel" : nil),
                common: AtomCommon(testID: "scheduled-tasks-back-button", label: "Back to the board", help: "Back to the board"),
                action: onClose
            ) {
                AtomPanel(props: PanelProps(fillOpacity: 0.07, capsule: true, align: "center"), common: AtomCommon(width: 26, height: 26)) {
                    AtomIcon(props: IconProps(name: "chevron.left", size: 13, weight: "semibold"))
                }
            }

            AtomText(props: TextProps(text: "Scheduled Tasks", size: 17, weight: "semibold"), common: AtomCommon(testID: "scheduled-tasks-title"))

            AtomSpacer()

            AtomButton(
                props: ButtonProps(style: "automatic"),
                common: AtomCommon(testID: "scheduled-new-task-button", help: "Write a task and choose when it runs"),
                action: onNewTask
            ) {
                AtomLabel(props: LabelProps(text: "New Task", icon: "plus"))
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, tasks: [BoardTask], identifier: String) -> some View {
        if !tasks.isEmpty {
            AtomText(props: TextProps(text: title.uppercased(), size: 10, weight: "semibold", color: "secondary"), common: AtomCommon(testID: identifier))
                .padding(.top, 6)
            ForEach(tasks) { row($0) }
        }
    }

    private func row(_ task: BoardTask) -> some View {
        let id = task.id.uuidString
        let repositories = task.repositoryWorktrees.map { URL(fileURLWithPath: $0.repositoryPath).lastPathComponent }
        return AtomPanel(
            props: PanelProps(fill: "panel", fillOpacity: 1, cornerRadius: 10),
            common: AtomCommon(testID: "scheduled-task-row-\(id)", paddingX: 14, paddingY: 10)
        ) {
            AtomStack(props: StackProps(axis: "h", spacing: 12)) {
                // A press area rather than a Button: a Button folds its label into one element,
                // which would hide the title and summary from accessibility. The press area
                // covers its column, so the full-width title makes the whole row clickable.
                AtomPressArea(
                    props: PressAreaProps(spacing: 4, pointer: true),
                    common: AtomCommon(testID: "scheduled-task-open-\(id)", help: "Edit this scheduled task", fillWidth: true),
                    onPress: { onOpenTask(task) },
                    onLongPress: { onOpenTask(task) }
                ) {
                    AtomText(
                        props: TextProps(text: Self.displayTitle(task), size: 13, weight: "semibold", color: task.schedulePaused ? "secondary" : "primary", lineLimit: 1),
                        common: AtomCommon(testID: "scheduled-task-title-\(id)", fillWidth: true)
                    )
                    AtomText(props: TextProps(text: Self.summary(task), size: 12, color: "secondary", lineLimit: 1), common: AtomCommon(testID: "scheduled-task-summary-\(id)"))
                    if !repositories.isEmpty {
                        AtomText(props: TextProps(text: repositories.joined(separator: " · "), size: 10, color: "tertiary", lineLimit: 1))
                    }
                }
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { onOpenTask(task) }

                if task.scheduleKind == .recurring {
                    AtomToggle(
                        props: ToggleProps(isOn: !task.schedulePaused, size: "mini"),
                        common: AtomCommon(
                            testID: "scheduled-task-active-\(id)", label: "\(task.title) active",
                            help: task.schedulePaused ? "Resume this schedule" : "Pause this schedule"
                        ),
                        onToggle: { setPaused(task, !task.schedulePaused) }
                    )
                }

                AtomMenu(
                    props: MenuProps(icon: "ellipsis", items: [
                        [
                            MenuProps.Item(
                                id: "run-now", title: "Run Now", help: "Start a run now",
                                testID: "scheduled-task-run-now-\(id)", disabled: runningTaskIDs.contains(task.id)
                            ),
                        ] + (task.lastScheduledRunTaskID == nil ? [] : [
                            MenuProps.Item(id: "last-run", title: "Open Last Run", help: "Open the task the last run created", testID: "scheduled-task-last-run-\(id)"),
                        ]),
                        [MenuProps.Item(id: "delete", title: "Delete…", destructive: true, help: "Delete this scheduled task", testID: "scheduled-task-delete-\(id)")],
                    ]),
                    common: AtomCommon(testID: "scheduled-task-actions-\(id)", label: "More actions", help: "More actions", width: 22, height: 22),
                    onMenu: { choice in
                        switch choice {
                        case "run-now": runNow(task)
                        case "last-run": if let lastRun = task.lastScheduledRunTaskID { onOpenRunTask(lastRun) }
                        default: pendingDelete = task
                        }
                    }
                )
            }
        }
    }

    static func displayTitle(_ task: BoardTask) -> String {
        guard ["Untitled task", "Generating title…"].contains(task.title),
              let prompt = task.scheduledPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty else {
            return task.title
        }
        return prompt.split(separator: "\n").first.map(String.init) ?? task.title
    }

    static func summary(_ task: BoardTask) -> String {
        if task.scheduleKind == .recurring {
            let rule = task.scheduleRecurrence?.summary() ?? ""
            if task.schedulePaused { return "\(rule) · Paused" }
            guard let next = task.scheduledAt else { return rule }
            return "\(rule) · Next \(ScheduleFormatting.relativeTime(next))"
        }
        return task.scheduledAt.map { ScheduleFormatting.relativeTime($0) } ?? ""
    }

    private func setPaused(_ task: BoardTask, _ paused: Bool) {
        perform { _ = try await BoardTaskManager(modelContext: modelContext).setSchedulePaused(task.id, paused: paused) }
    }

    private func runNow(_ task: BoardTask) {
        runningTaskIDs.insert(task.id)
        perform {
            defer { runningTaskIDs.remove(task.id) }
            _ = try await remoteConversations.runScheduleNow(taskID: task.id)
        }
    }

    private func delete(_ task: BoardTask) {
        let id = task.id
        perform { try await remoteConversations.deleteTask(taskID: id) }
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        errorMessage = nil
        Task { @MainActor in
            do { try await operation() } catch { errorMessage = error.localizedDescription }
        }
    }
}

enum ScheduleFormatting {
    /// "Today 15:00", "Tomorrow 09:00", or "Mon 9 Nov, 09:00".
    static func relativeTime(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let time = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        if calendar.isDate(date, inSameDayAs: now) { return "Today \(time)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "Tomorrow \(time)"
        }
        return "\(date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))), \(time)"
    }
}

/// The LaunchAgent that runs `playhouse-cli schedule tick` each minute, so schedules fire
/// while the app is closed. It's registered only while a schedule is active, so Playhouse
/// leaves nothing running in the background otherwise.
@MainActor
enum SchedulerAgent {
    private static var service: SMAppService? {
        guard let identifier = Bundle.main.bundleIdentifier,
              !BridgeContract.isTestBundle(PlayhouseAppIdentity.applicationIdentifier) else { return nil }
        let plistName = "\(identifier).scheduler.plist"
        let path = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchAgents/\(plistName)").path
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return SMAppService.agent(plistName: plistName)
    }

    static var requiresApproval: Bool {
        service?.status == .requiresApproval
    }

    static func sync(hasActiveSchedules: Bool) {
        guard let service else { return }
        do {
            if hasActiveSchedules {
                guard service.status != .enabled else { return }
                try service.register()
                PlayhouseDiagnostics.record("scheduler.agent.registered", fields: ["status": String(describing: service.status.rawValue)])
            } else {
                guard service.status == .enabled || service.status == .requiresApproval else { return }
                try service.unregister()
                PlayhouseDiagnostics.record("scheduler.agent.unregistered", fields: [:])
            }
        } catch {
            PlayhouseDiagnostics.record("scheduler.agent.failed", fields: PlayhouseDiagnostics.errorFields(error))
        }
    }
}
