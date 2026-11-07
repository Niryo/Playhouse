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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("scheduled-tasks-error")
            }
            if SchedulerAgent.requiresApproval {
                HStack(spacing: 6) {
                    Text("Allow Playhouse in Login Items so scheduled tasks run while it's closed.")
                    Button("Open Settings") { SMAppService.openSystemSettingsLoginItems() }
                        .buttonStyle(.link)
                        .buttonHoverPointer()
                        .nativeHelp("Open Login Items in System Settings")
                        .accessibilityIdentifier("scheduled-tasks-login-items-button")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.top, 10)
            }
            if scheduledTasks.isEmpty {
                VStack(spacing: 6) {
                    Text("No scheduled tasks")
                        .font(.headline)
                    Text("Write a task, then use the clock beside Send to schedule it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("scheduled-tasks-empty")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        section("Recurring", tasks: recurring, identifier: "scheduled-tasks-recurring")
                        section("One-time", tasks: oneTime, identifier: "scheduled-tasks-one-time")
                    }
                    .padding(20)
                }
                .accessibilityIdentifier("scheduled-tasks-list")
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
        HStack(spacing: 12) {
            Button(action: onClose) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(Color.primary.opacity(0.07), in: Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(pendingDelete == nil ? .cancelAction : nil)
            .buttonHoverPointer()
            .nativeHelp("Back to the board")
            .accessibilityLabel("Back to the board")
            .accessibilityIdentifier("scheduled-tasks-back-button")

            Text("Scheduled Tasks")
                .font(.title2.weight(.semibold))
                .accessibilityIdentifier("scheduled-tasks-title")

            Spacer()

            Button(action: onNewTask) { Label("New Task", systemImage: "plus") }
                .buttonHoverPointer()
                .nativeHelp("Write a task and choose when it runs")
                .accessibilityIdentifier("scheduled-new-task-button")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func section(_ title: String, tasks: [BoardTask], identifier: String) -> some View {
        if !tasks.isEmpty {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.top, 6)
                .accessibilityIdentifier(identifier)
            ForEach(tasks) { row($0) }
        }
    }

    private func row(_ task: BoardTask) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.displayTitle(task))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(task.schedulePaused ? Color.secondary : Color.primary)
                    .lineLimit(1)
                    .accessibilityIdentifier("scheduled-task-title-\(task.id.uuidString)")
                Text(Self.summary(task))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityIdentifier("scheduled-task-summary-\(task.id.uuidString)")
                let repositories = task.repositoryWorktrees.map { URL(fileURLWithPath: $0.repositoryPath).lastPathComponent }
                if !repositories.isEmpty {
                    Text(repositories.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            // A tap target rather than a Button: a Button folds its label into one element,
            // which would hide the title and summary from accessibility.
            .onTapGesture { onOpenTask(task) }
            .buttonHoverPointer()
            .nativeHelp("Edit this scheduled task")
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onOpenTask(task) }
            .accessibilityIdentifier("scheduled-task-open-\(task.id.uuidString)")

            if task.scheduleKind == .recurring {
                Toggle("Active", isOn: Binding(get: { !task.schedulePaused }, set: { setPaused(task, !$0) }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .buttonHoverPointer()
                    .nativeHelp(task.schedulePaused ? "Resume this schedule" : "Pause this schedule")
                    .accessibilityLabel("\(task.title) active")
                    .accessibilityIdentifier("scheduled-task-active-\(task.id.uuidString)")
            }

            Menu {
                Button("Run Now") { runNow(task) }
                    .disabled(runningTaskIDs.contains(task.id))
                    .buttonHoverPointer()
                    .help("Start a run now")
                    .accessibilityIdentifier("scheduled-task-run-now-\(task.id.uuidString)")
                if let lastRun = task.lastScheduledRunTaskID {
                    Button("Open Last Run") { onOpenRunTask(lastRun) }
                        .buttonHoverPointer()
                        .help("Open the task the last run created")
                        .accessibilityIdentifier("scheduled-task-last-run-\(task.id.uuidString)")
                }
                Divider()
                Button("Delete…", role: .destructive) { pendingDelete = task }
                    .buttonHoverPointer()
                    .help("Delete this scheduled task")
                    .accessibilityIdentifier("scheduled-task-delete-\(task.id.uuidString)")
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 22, height: 22)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .buttonHoverPointer()
            .nativeHelp("More actions")
            .accessibilityLabel("More actions")
            .accessibilityIdentifier("scheduled-task-actions-\(task.id.uuidString)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(WorkspaceTheme.panelBackground, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("scheduled-task-row-\(task.id.uuidString)")
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
