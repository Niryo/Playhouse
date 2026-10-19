import AppKit
import SwiftData
import SwiftUI

struct KanbanBoardView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var codexClient: CodexAppServerClient
    @Query(sort: \BoardTask.createdAt, order: .reverse) private var tasks: [BoardTask]
    @State private var isShowingNewTask = false
    @State private var pendingConversationTaskID: UUID?
    @State private var isChoosingDefaultParent = false
    @State private var saveError: String?
    @State private var lifecycleResetNotice: String?
    @State private var draggedTaskID: UUID?
    @State private var selectedTask: BoardTask?
    @State private var isSelectedTaskNew = false
    @State private var taskBeingRenamed: BoardTask?
    @State private var taskBeingDeleted: BoardTask?
    @State private var isShowingDeleteConfirmation = false
    @State private var isDoneTargetActive = false
    @State private var isShowingDoneArchive = false
    @State private var archiveSearchText = ""
    @State private var archivedConversationText: [UUID: String] = [:]
    @State private var isIndexingArchive = false
    @State private var taskCreatingPullRequests = Set<UUID>()
    @State private var taskAwaitingUnmergedConfirmation: UUID?
    @State private var pullRequestError: String?
    @State private var doneMoveError: String?

    var body: some View {
        Group {
            if let selectedTask {
                TaskConversationView(task: selectedTask, isNewTask: isSelectedTaskNew, isReadOnly: selectedTask.status == .done) {
                    self.selectedTask = nil
                    self.isSelectedTaskNew = false
                }
                .id(selectedTask.id)
            } else {
                boardContent
            }
        }
        .background(WorkspaceTheme.windowBackground)
        .frame(minWidth: 980, minHeight: 640)
        .onAppear {
            let retained = StationAIStore.takeLifecycleResetNotice(
                dataDirectory: ProcessInfo.processInfo.environment["STATIONAI_DATA_DIRECTORY"]
            )
            if !retained.isEmpty {
                lifecycleResetNotice = "Existing tasks were cleared. These dirty managed worktrees were kept:\n\n" + retained.joined(separator: "\n")
            }
        }
        .sheet(isPresented: $isShowingNewTask, onDismiss: openPendingCreatedTask) {
            NewTaskSheet(onCreate: createTask)
        }
        .sheet(isPresented: Binding(
            get: { taskBeingRenamed != nil },
            set: { if !$0 { taskBeingRenamed = nil } }
        )) {
            if let taskBeingRenamed {
                RenameTaskSheet(title: taskBeingRenamed.title) { title in
                    do {
                        _ = try BoardTaskManager(modelContext: modelContext).rename(taskBeingRenamed.id, title: title)
                    } catch {
                        saveError = error.localizedDescription
                    }
                    self.taskBeingRenamed = nil
                }
            }
        }
        .confirmationDialog(
            "Delete this task?",
            isPresented: $isShowingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Task", role: .destructive) {
                guard let taskBeingDeleted else { return }
                do {
                    try BoardTaskManager(modelContext: modelContext).delete(
                        taskBeingDeleted.id,
                        diagnostics: codexClient.diagnosticFields()
                    )
                } catch {
                    saveError = "\(error.localizedDescription)\n\nDiagnostic log: \(StationAIDiagnostics.logURL.path)"
                }
                self.taskBeingDeleted = nil
            }
            .accessibilityIdentifier("confirm-delete-task-button")
            Button("Cancel", role: .cancel) {
                taskBeingDeleted = nil
            }
            .accessibilityIdentifier("cancel-delete-task-button")
        } message: {
            Text("The task conversation and saved working folders will also be deleted.")
        }
        .alert("Couldn't save changes", isPresented: isShowingSaveError) {
            Button("OK", role: .cancel) {
                saveError = nil
            }
        } message: {
            Text(saveError ?? "Please try again.")
        }
        .alert("Couldn't create pull request", isPresented: Binding(
            get: { pullRequestError != nil },
            set: { if !$0 { pullRequestError = nil } }
        )) {
            Button("OK", role: .cancel) { pullRequestError = nil }
        } message: {
            Text(pullRequestError ?? "Please try again.")
        }
        .alert("Couldn't check pull request status", isPresented: Binding(
            get: { doneMoveError != nil },
            set: { if !$0 { doneMoveError = nil } }
        )) {
            Button("OK", role: .cancel) { doneMoveError = nil }
        } message: {
            Text(doneMoveError ?? "Please try again.")
        }
        .confirmationDialog(
            "This task has an unmerged pull request",
            isPresented: Binding(
                get: { taskAwaitingUnmergedConfirmation != nil },
                set: { if !$0 { taskAwaitingUnmergedConfirmation = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Mark Done Anyway", role: .destructive) {
                guard let id = taskAwaitingUnmergedConfirmation else { return }
                taskAwaitingUnmergedConfirmation = nil
                moveTask(id: id, to: .done, allowUnmergedPullRequests: true)
            }
            Button("Cancel", role: .cancel) { taskAwaitingUnmergedConfirmation = nil }
        } message: {
            Text("The pull request hasn't been merged. Marking this task Done will keep its worktree and branch as they are.")
        }
        .alert("Some task worktrees were kept", isPresented: Binding(
            get: { lifecycleResetNotice != nil },
            set: { if !$0 { lifecycleResetNotice = nil } }
        )) {
            Button("OK", role: .cancel) { lifecycleResetNotice = nil }
        } message: {
            Text(lifecycleResetNotice ?? "")
        }
    }

    private var boardContent: some View {
        VStack(spacing: 0) {
            boardHeader

            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 1)

            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(TaskStatus.allCases.filter { $0 != .blocked && $0 != .waitingResponse && $0 != .done }) { status in
                        if status == .backlog {
                            let hasBlockedTasks = tasks.contains(where: { $0.status == .blocked })
                            VStack(spacing: 12) {
                                if hasBlockedTasks {
                                    kanbanColumn(.blocked, minHeight: 220)
                                        .transition(.opacity.combined(with: .move(edge: .top)))
                                }
                                kanbanColumn(.backlog, minHeight: hasBlockedTasks ? 220 : 480)
                            }
                            .frame(width: 264)
                            .animation(.easeInOut(duration: 0.2), value: hasBlockedTasks)
                        } else if status == .inProgress {
                            let hasWaitingResponseTasks = tasks.contains(where: { $0.status == .waitingResponse })
                            VStack(spacing: 12) {
                                if hasWaitingResponseTasks {
                                    kanbanColumn(.waitingResponse, minHeight: 220)
                                        .transition(.opacity.combined(with: .move(edge: .top)))
                                }
                                kanbanColumn(.inProgress, minHeight: hasWaitingResponseTasks ? 220 : 480)
                            }
                            .frame(width: 264)
                            .animation(.easeInOut(duration: 0.2), value: hasWaitingResponseTasks)
                        } else {
                            kanbanColumn(status)
                                .frame(width: 264)
                        }
                    }
                }
                .padding(.horizontal, 30)
                .padding(.top, 22)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.visible)
            .accessibilityIdentifier("board-columns-scroll-view")
            .overlay(alignment: .trailing) {
                if draggedTaskID != nil {
                    HStack(spacing: 10) {
                        DoneDropTarget(isActive: $isDoneTargetActive, onDrop: { moveTask(id: $0, to: .done) })
                            .frame(width: 104, height: 480)
                            .accessibilityIdentifier("task-done-drop-target")
                            .transition(.opacity.combined(with: .move(edge: .trailing)))
                    }
                    .padding(.trailing, 12)
                    .background(LinearGradient(colors: [WorkspaceTheme.windowBackground.opacity(0), WorkspaceTheme.windowBackground.opacity(0.96)], startPoint: .leading, endPoint: .trailing))
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }
        }
        .background(DragEndEventMonitor(draggedTaskID: $draggedTaskID))
        .overlay(alignment: .trailing) {
            if isShowingDoneArchive {
                doneArchivePanel
                    .frame(width: 340)
                    .frame(maxHeight: .infinity)
                    .background(WorkspaceTheme.windowBackground)
                    .overlay(alignment: .leading) { Rectangle().fill(Color.primary.opacity(0.10)).frame(width: 1) }
                    .shadow(color: .black.opacity(0.16), radius: 18, x: -6, y: 0)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .accessibilityIdentifier("done-archive-panel")
            }
        }
        .animation(.easeInOut(duration: 0.24), value: isShowingDoneArchive)
        .task(id: "\(isShowingDoneArchive)-\(tasks.filter { $0.status == .done }.count)") { await indexDoneConversationsIfNeeded() }
    }

    @ViewBuilder
    private func kanbanColumn(_ status: TaskStatus, minHeight: CGFloat = 480) -> some View {
        KanbanColumnView(
            status: status,
            tasks: tasks.filter { $0.status == status },
            onMoveTask: { id, status in moveTask(id: id, to: status) },
            onCreatePullRequests: createPullRequests,
            creatingPullRequestTaskIDs: taskCreatingPullRequests,
            onAddTask: openNewTask,
            onOpenTask: { selectedTask = $0 },
            onRenameTask: { taskBeingRenamed = $0 },
            onDeleteTask: {
                taskBeingDeleted = $0
                isShowingDeleteConfirmation = true
            },
            draggedTaskID: $draggedTaskID,
            minHeight: minHeight
        )
        .frame(width: 264)
        .frame(minHeight: minHeight)
    }

    private var boardHeader: some View {
        HStack(alignment: .center, spacing: 24) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [WorkspaceTheme.accent, Color(red: 0.22, green: 0.58, blue: 0.94)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 3) {
                    Text("StationAI")
                        .font(.system(size: 21, weight: .semibold, design: .rounded))
                        .accessibilityIdentifier("board-title")
                    Text("A clear view of every task in flight.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 20)

            HStack(spacing: 14) {
                let activeTaskCount = tasks.filter { $0.status != .done }.count
                Text("\(activeTaskCount) \(activeTaskCount == 1 ? "task" : "tasks")")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Task count")
                    .accessibilityValue("\(activeTaskCount)")
                    .accessibilityIdentifier("task-count")

                Button {
                    withAnimation(.easeInOut(duration: 0.24)) { isShowingDoneArchive.toggle() }
                } label: {
                    Image(systemName: "archivebox")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.bordered)
                .help("Browse completed tasks")
                .accessibilityLabel("Done tasks")
                .accessibilityIdentifier("done-archive-button")

                Button {
                    openNewTask()
                } label: {
                    Label("New Task", systemImage: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                }
                .buttonStyle(.borderedProminent)
                .tint(WorkspaceTheme.accent)
                .accessibilityIdentifier("new-task-button")
            }
        }
        .padding(.horizontal, 30)
        .padding(.top, 24)
        .padding(.bottom, 21)
    }

    private var doneArchivePanel: some View {
        let query = archiveSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let completed = tasks.filter { $0.status == .done }
        let titleMatches = completed.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
        let conversationMatches = completed.filter { task in
            !query.isEmpty && !titleMatches.contains(where: { $0.id == task.id }) &&
                (archivedConversationText[task.id]?.localizedCaseInsensitiveContains(query) ?? false)
        }
        let results = (titleMatches + conversationMatches).sorted { lhs, rhs in
            let lhsTitle = query.isEmpty || lhs.title.localizedCaseInsensitiveContains(query)
            let rhsTitle = query.isEmpty || rhs.title.localizedCaseInsensitiveContains(query)
            if lhsTitle != rhsTitle { return lhsTitle }
            return lhs.createdAt > rhs.createdAt
        }
        return VStack(spacing: 0) {
            HStack {
                Text("Done tasks").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button { withAnimation { isShowingDoneArchive = false } } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel("Close done tasks")
                    .accessibilityIdentifier("close-done-archive-button")
            }
            .padding(16)
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search tasks and conversations", text: $archiveSearchText)
                    .textFieldStyle(.plain).accessibilityIdentifier("done-archive-search")
                if !archiveSearchText.isEmpty {
                    Button { archiveSearchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).accessibilityLabel("Clear archive search")
                        .accessibilityIdentifier("clear-archive-search-button")
                }
            }
            .padding(10).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9)).padding(12)
            if isIndexingArchive {
                ProgressView("Searching conversations…").controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("done-archive-indexing")
            } else if results.isEmpty {
                Text(query.isEmpty ? "No completed tasks" : "No matching tasks")
                    .font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("done-archive-empty-state")
            } else {
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(results) { task in
                            Button {
                                isShowingDoneArchive = false
                                selectedTask = task
                                isSelectedTaskNew = false
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(TaskStatus.done.accent)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(task.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                        Text(task.createdAt, style: .date).font(.system(size: 10)).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(10).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("done-archive-task-\(task.id.uuidString)")
                        }
                    }
                    .padding(.horizontal, 10)
                }
                .scrollIndicators(.visible)
                .accessibilityIdentifier("done-archive-list")
            }
        }
    }

    @MainActor
    private func indexDoneConversationsIfNeeded() async {
        guard isShowingDoneArchive,
              tasks.contains(where: { $0.status == .done && archivedConversationText[$0.id] == nil }) else { return }
        isIndexingArchive = true
        defer { isIndexingArchive = false }
        let manager = CodexConversationManager(tasks: BoardTaskManager(modelContext: modelContext), client: codexClient)
        for task in tasks where task.status == .done && archivedConversationText[task.id] == nil {
            guard !Task.isCancelled else { return }
            do {
                let history = try await manager.history(taskID: task.id)
                archivedConversationText[task.id] = history.messages.map(\.text).joined(separator: "\n")
            } catch {
                archivedConversationText[task.id] = ""
            }
        }
    }

    private var isShowingSaveError: Binding<Bool> {
        Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )
    }

    private func openNewTask() {
        guard !isChoosingDefaultParent else { return }
        do {
            let created = try BoardTaskManager(modelContext: modelContext).create(
                title: "Untitled task",
                repositories: [],
                contextFolders: []
            )
            selectedTask = try BoardTaskManager(modelContext: modelContext).taskModel(created.id)
            isSelectedTaskNew = true
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func createTask(repositories: [RepositoryWorktreeSpec], contextFolders: [URL]) throws {
        let branchName = "task-\(UUID().uuidString.prefix(8).lowercased())"
        let branchSpecs = repositories.map { spec -> RepositoryWorktreeSpec in
            var spec = spec
            if spec.branch == nil { spec.branch = branchName }
            return spec
        }
        let created = try BoardTaskManager(modelContext: modelContext).create(
            title: "Untitled task",
            repositories: branchSpecs,
            contextFolders: contextFolders.map { $0.standardizedFileURL.path }
        )
        pendingConversationTaskID = created.id
    }

    private func openPendingCreatedTask() {
        guard let taskID = pendingConversationTaskID else { return }
        pendingConversationTaskID = nil
        selectedTask = tasks.first(where: { $0.id == taskID })
        if selectedTask == nil {
            selectedTask = try? BoardTaskManager(modelContext: modelContext).taskModel(taskID)
        }
        isSelectedTaskNew = selectedTask != nil
    }

    private func moveTask(id: UUID, to status: TaskStatus, allowUnmergedPullRequests: Bool = false) {
        guard let task = tasks.first(where: { $0.id == id }), task.status != status else { return }
        guard status == .done else { return }
        Task { @MainActor in
            do {
                _ = try await BoardTaskManager(modelContext: modelContext).move(
                    id,
                    to: status.rawValue,
                    client: codexClient,
                    onConflictResolutionStart: { selectedTask = task },
                    allowUnmergedPullRequests: allowUnmergedPullRequests
                )
            } catch StationAIManagerError.unmergedPullRequests {
                taskAwaitingUnmergedConfirmation = id
            } catch {
                doneMoveError = error.localizedDescription
            }
        }
    }

    private func createPullRequests(for task: BoardTask) {
        guard taskCreatingPullRequests.insert(task.id).inserted else { return }
        Task { @MainActor in
            defer { taskCreatingPullRequests.remove(task.id) }
            do {
                _ = try await BoardTaskManager(modelContext: modelContext).createPullRequests(task.id, client: codexClient)
            } catch {
                pullRequestError = error.localizedDescription
            }
        }
    }

}

private struct DragEndEventMonitor: NSViewRepresentable {
    @Binding var draggedTaskID: UUID?

    func makeCoordinator() -> Coordinator {
        Coordinator(draggedTaskID: $draggedTaskID)
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.install()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.draggedTaskID = $draggedTaskID
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    final class Coordinator {
        var draggedTaskID: Binding<UUID?>
        private var mouseUpMonitor: Any?

        init(draggedTaskID: Binding<UUID?>) {
            self.draggedTaskID = draggedTaskID
        }

        func install() {
            guard mouseUpMonitor == nil else { return }
            mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
                guard let self, self.draggedTaskID.wrappedValue != nil else { return event }
                self.draggedTaskID.wrappedValue = nil
                return event
            }
        }

        func uninstall() {
            guard let mouseUpMonitor else { return }
            NSEvent.removeMonitor(mouseUpMonitor)
            self.mouseUpMonitor = nil
        }
    }
}

private struct DoneDropTarget: View {
    @Binding var isActive: Bool
    let onDrop: (UUID) -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 24, weight: .medium))
            Text("Done")
                .font(.system(size: 12, weight: .semibold))
            Text("Merge and archive")
                .font(.system(size: 10))
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(isActive ? Color.white : TaskStatus.done.accent)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isActive ? TaskStatus.done.accent : TaskStatus.done.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(TaskStatus.done.accent.opacity(0.35), lineWidth: 1))
        .onDrop(of: [.plainText], isTargeted: $isActive) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: NSString.self) { value, _ in
                guard let value = value as? String, let id = UUID(uuidString: value) else { return }
                DispatchQueue.main.async { onDrop(id) }
            }
            return true
        }
    }
}

private struct KanbanColumnView: View {
    let status: TaskStatus
    let tasks: [BoardTask]
    let onMoveTask: (UUID, TaskStatus) -> Void
    let onCreatePullRequests: (BoardTask) -> Void
    let creatingPullRequestTaskIDs: Set<UUID>
    let onAddTask: () -> Void
    let onOpenTask: (BoardTask) -> Void
    let onRenameTask: (BoardTask) -> Void
    let onDeleteTask: (BoardTask) -> Void
    @Binding var draggedTaskID: UUID?
    let minHeight: CGFloat

    var body: some View {
        dropTarget
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("column-\(status.accessibilityKey)")
    }

    private var columnContent: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 9) {
                Circle()
                    .fill(status.accent)
                    .frame(width: 8, height: 8)
                Text(status.rawValue.uppercased())
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(0.65)
                    .foregroundStyle(.primary.opacity(0.82))
                    .accessibilityIdentifier("column-heading-\(status.accessibilityKey)")
                Spacer(minLength: 4)
                Text("\(tasks.count)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.055)))
                if status == .backlog {
                    Button(action: onAddTask) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("Add task to Backlog")
                    .accessibilityIdentifier("add-backlog-task-button")
                    .help("Add task to Backlog")
                }
            }
            .padding(.horizontal, 3)

            if status == .blocked {
                Label("Waiting for user intervention", systemImage: "hand.raised.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.red)
                    .padding(.horizontal, 3)
                    .accessibilityIdentifier("blocked-waiting-indicator")
            }

            if tasks.isEmpty {
                emptyState
            } else {
                ForEach(tasks) { task in
                    draggableTaskCard(task)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(WorkspaceTheme.panelBackground.opacity(0.78))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.075), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var dropTarget: some View {
        if status != .done {
            columnContent
        } else if #available(macOS 26.0, *) {
            NativeMoveDropDestination { taskID in
                onMoveTask(taskID, status)
            } content: {
                columnContent
            }
        } else {
            columnContent
                .onDrop(of: [.plainText], delegate: KanbanTaskDropDelegate(
                    status: status,
                    draggedTaskID: $draggedTaskID,
                    onMoveTask: onMoveTask
                ))
        }
    }

    @ViewBuilder
    private func draggableTaskCard(_ task: BoardTask) -> some View {
        let card = TaskCardView(
            task: task,
            onOpen: { onOpenTask(task) },
            onRename: { onRenameTask(task) },
            onDelete: { onDeleteTask(task) },
            onCreatePullRequests: { onCreatePullRequests(task) },
            isCreatingPullRequests: creatingPullRequestTaskIDs.contains(task.id),
            onMoveToDone: task.status == .review ? { onMoveTask(task.id, .done) } : nil
        )

        if task.status == .review {
            card.onDrag {
                draggedTaskID = task.id
                return NSItemProvider(object: task.id.uuidString as NSString)
            }
        } else {
            card
        }
    }

    private var emptyState: some View {
        VStack(spacing: 9) {
            Image(systemName: status == .done ? "checkmark.circle" : "tray")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(status.accent.opacity(0.75))
            Text("No tasks yet")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text(status == .backlog ? "Create a task to get started" : "Drop a task here")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 124)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("empty-state-\(status.accessibilityKey)")
    }
}

private struct NativeMoveDropDestination<Content: View>: NSViewRepresentable {
    let onMoveTask: (UUID) -> Void
    @ViewBuilder let content: Content

    func makeNSView(context: Context) -> NativeMoveDropContainer<Content> {
        NativeMoveDropContainer(rootView: content, onMoveTask: onMoveTask)
    }

    func updateNSView(_ nsView: NativeMoveDropContainer<Content>, context: Context) {
        nsView.rootView = content
        nsView.onMoveTask = onMoveTask
    }
}

@MainActor
private final class NativeMoveDropContainer<Content: View>: NSView {
    private let hostingView: NSHostingView<Content>
    var onMoveTask: (UUID) -> Void

    var rootView: Content {
        get { hostingView.rootView }
        set { hostingView.rootView = newValue }
    }

    private let textPasteboardTypes: [NSPasteboard.PasteboardType] = [
        .string,
        NSPasteboard.PasteboardType("public.plain-text"),
        NSPasteboard.PasteboardType("public.utf8-plain-text")
    ]

    init(rootView: Content, onMoveTask: @escaping (UUID) -> Void) {
        hostingView = NSHostingView(rootView: rootView)
        self.onMoveTask = onMoveTask
        super.init(frame: .zero)

        registerForDraggedTypes(textPasteboardTypes)
        addSubview(hostingView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        offeredMoveOperation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        offeredMoveOperation(for: sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard offeredMoveOperation(for: sender) != [],
              taskID(from: sender) != nil else {
            return false
        }

        // AppKit otherwise animates the drag image to its destination after the drop.
        sender.animatesToDestination = false
        return true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard offeredMoveOperation(for: sender) != [],
              let taskID = taskID(from: sender) else {
            return false
        }

        onMoveTask(taskID)
        return true
    }

    private func offeredMoveOperation(for sender: NSDraggingInfo) -> NSDragOperation {
        guard taskID(from: sender) != nil else {
            return []
        }

        return sender.draggingSourceOperationMask.contains(.move) ? .move : .copy
    }

    private func taskID(from sender: NSDraggingInfo) -> UUID? {
        guard let type = sender.draggingPasteboard.availableType(from: textPasteboardTypes),
              let identifier = sender.draggingPasteboard.string(forType: type) else {
            return nil
        }

        return UUID(uuidString: identifier)
    }
}

private struct KanbanTaskDropDelegate: DropDelegate {
    let status: TaskStatus
    @Binding var draggedTaskID: UUID?
    let onMoveTask: (UUID, TaskStatus) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let id = draggedTaskID else { return false }
        onMoveTask(id, status)
        draggedTaskID = nil
        return true
    }
}

private struct TaskCardView: View {
    let task: BoardTask
    let onOpen: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    let onCreatePullRequests: () -> Void
    let isCreatingPullRequests: Bool
    let onMoveToDone: (() -> Void)?

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 6) {
                    Image(systemName: "circle.inset.filled")
                        .font(.system(size: 9))
                        .foregroundStyle(task.status.accent)
                    Text(task.status.rawValue)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Spacer(minLength: 0)
                }

                if let progressLabel = task.progressLabel, !progressLabel.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        let progressType = TaskProgressType(rawValue: task.progressTypeRawValue ?? "")
                        Image(systemName: progressType?.symbol ?? "sparkle")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .accessibilityLabel(progressType?.symbol ?? "sparkle")
                            .accessibilityIdentifier("task-progress-icon-\(task.id.uuidString)")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(progressLabel)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.primary)
                                .accessibilityIdentifier("task-progress-label-\(task.id.uuidString)")
                            if let progressDetail = task.progressDetail, !progressDetail.isEmpty {
                                Text(progressDetail)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .accessibilityIdentifier("task-progress-detail-\(task.id.uuidString)")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("task-progress-report-\(task.id.uuidString)")
                    .accessibilityValue("Progress icon: \(TaskProgressType(rawValue: task.progressTypeRawValue ?? "")?.symbol ?? "sparkle")")
                }

                if let statusMessage = task.statusMessage, !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(.system(size: 10))
                        .foregroundStyle(task.status == .blocked ? Color.red : Color.secondary)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("task-status-message-\(task.id.uuidString)")
                }

        HStack(spacing: 6) {
            if task.title == "Generating title…" { ProgressView().controlSize(.small) }
            Text(task.title)
        }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("task-title-\(task.id.uuidString)")

                HStack(spacing: 6) {
                    Image(systemName: "clock")
                        .font(.system(size: 10))
                    Text(task.createdAt.formatted(date: .abbreviated, time: .omitted))
                        .font(.system(size: 10))
                }
                .foregroundStyle(.tertiary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(WorkspaceTheme.windowBackground)
                    .shadow(color: .black.opacity(0.035), radius: 5, x: 0, y: 2)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            if !task.repositoryWorktrees.isEmpty {
                HStack(spacing: 5) {
                    let linked = task.repositoryWorktrees.filter { $0.pullRequestNumber != nil && $0.pullRequestURL != nil }
                    if linked.isEmpty {
                        Button(action: onCreatePullRequests) {
                            if isCreatingPullRequests {
                                ProgressView().controlSize(.mini)
                            } else {
                                Text("PR").font(.system(size: 10, weight: .semibold))
                            }
                        }
                        .disabled(isCreatingPullRequests)
                        .accessibilityIdentifier("task-create-pr-\(task.id.uuidString)")
                    } else {
                        ForEach(linked, id: \.repositoryPath) { record in
                            if let number = record.pullRequestNumber, let url = URL(string: record.pullRequestURL ?? "") {
                                Link("#\(number)", destination: url)
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .accessibilityIdentifier("task-pr-link-\(task.id.uuidString)-\(number)")
                            }
                        }
                    }
                }
                .buttonStyle(.borderless)
                .padding(.trailing, 14)
                .padding(.top, 12)
            }
        }
        .accessibilityLabel(task.title)
        .accessibilityHint("Open task")
        .accessibilityIdentifier("task-card-\(task.id.uuidString)")
        .contextMenu {
            if let onMoveToDone {
                Button("Move to Done", systemImage: "checkmark.circle", action: onMoveToDone)
                    .accessibilityIdentifier("move-task-to-done-menu-item")
            }
            Button("Rename…", systemImage: "pencil", action: onRename)
                .accessibilityIdentifier("rename-task-menu-item")
            Button("Delete Task", systemImage: "trash", role: .destructive, action: onDelete)
                .accessibilityIdentifier("delete-task-menu-item")
        }
    }
}

private struct RenameTaskSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title: String

    let onSave: (String) -> Void

    init(title: String, onSave: @escaping (String) -> Void) {
        _title = State(initialValue: title)
        self.onSave = onSave
    }

    private var normalizedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename task")
                .font(.system(size: 19, weight: .semibold, design: .rounded))
            TextField("Task title", text: $title)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("rename-task-title-field")
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(normalizedTitle)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(normalizedTitle.isEmpty)
                .accessibilityIdentifier("save-task-rename-button")
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}
