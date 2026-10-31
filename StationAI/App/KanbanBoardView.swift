import AppKit
import SwiftData
import SwiftUI

struct KanbanBoardView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var conversationRuntime: ConversationRuntimeModel
    @Query(filter: #Predicate<BoardTask> { $0.statusRawValue != "Done" }, sort: \BoardTask.createdAt, order: .reverse) private var tasks: [BoardTask]
    @State private var isCreatingNewTask = false
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
    @State private var isIndexingArchive = false
    @State private var archiveSearchResults: [BoardTask]?
    @State private var archiveTasks: [BoardTask] = []
    @State private var archiveOffset = 0
    @State private var archiveHasMore = true
    @State private var isLoadingArchivePage = false
    @State private var taskCreatingPullRequests = Set<UUID>()
    @State private var mergedReviewTaskIDs = Set<UUID>()
    @State private var conflictedReviewTaskIDs = Set<UUID>()
    @State private var conflictResolutionTaskID: UUID?
    @State private var checkingMergedPullRequests = false
    @State private var mergedPullRequestCheckPending = false
    @State private var mergedPullRequestCheckTimerScheduled = false
    @State private var lastMergedPullRequestCheckAt: Date?
    @State private var taskAwaitingUnmergedConfirmation: UUID?
    @State private var pullRequestError: String?
    @State private var doneMoveError: String?
    @State private var isShowingBoardSearch = false
    @State private var boardSearchText = ""
    @FocusState private var isBoardSearchFocused: Bool

    /// Provider-owning operations run in the bridge daemon.
    private var remoteConversations: RemoteConversationManager {
        RemoteConversationManager(daemon: conversationRuntime.client, runtime: conversationRuntime, modelContext: modelContext)
    }

    var body: some View {
        Group {
            if let selectedTask {
                TaskConversationView(
                    task: selectedTask, isNewTask: isSelectedTaskNew, isReadOnly: selectedTask.status == .done,
                    conflictResolutionRequested: conflictResolutionTaskID == selectedTask.id,
                    onConflictResolutionChecked: { resolved in
                        if resolved { conflictedReviewTaskIDs.remove(selectedTask.id) }
                        else { conflictedReviewTaskIDs.insert(selectedTask.id) }
                    }
                ) {
                    self.selectedTask = nil
                    self.isSelectedTaskNew = false
                    self.conflictResolutionTaskID = nil
                }
                .id(selectedTask.id)
            } else {
                boardContent
            }
        }
        .background(WorkspaceTheme.windowBackground)
        .frame(minWidth: 980, minHeight: 640)
        .onAppear {
            checkReviewPullRequests()
            let retained = StationAIStore.takeLifecycleResetNotice(
                dataDirectory: ProcessInfo.processInfo.environment["STATIONAI_DATA_DIRECTORY"]
            )
            if !retained.isEmpty {
                lifecycleResetNotice = "Existing tasks were cleared. These dirty managed worktrees were kept:\n\n" + retained.joined(separator: "\n")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .stationAIShowBoardSearch)) { _ in
            withAnimation(.easeInOut(duration: 0.18)) { isShowingBoardSearch = true }
            isBoardSearchFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            checkReviewPullRequests()
        }
        .task(id: reviewPullRequestSignature) {
            checkReviewPullRequests()
        }
        .sheet(isPresented: Binding(
            get: { taskBeingRenamed != nil },
            set: { if !$0 { taskBeingRenamed = nil } }
        )) {
            if let taskBeingRenamed {
                RenameTaskSheet(title: taskBeingRenamed.title) { title in
                    Task { @MainActor in
                        do {
                            _ = try await BoardTaskManager(modelContext: modelContext).rename(taskBeingRenamed.id, title: title)
                        } catch {
                            presentSaveError(error.localizedDescription)
                        }
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
                Task { @MainActor in
                    do {
                        try await remoteConversations.deleteTask(taskID: taskBeingDeleted.id)
                    } catch {
                        presentSaveError("\(error.localizedDescription)\n\nDiagnostic log: \(StationAIDiagnostics.logURL.path)")
                    }
                    self.taskBeingDeleted = nil
                }
            }
            .buttonHoverPointer()
            .help("Delete Task")
            .accessibilityIdentifier("confirm-delete-task-button")
            Button("Cancel", role: .cancel) {
                taskBeingDeleted = nil
            }
            .buttonHoverPointer()
            .help("Cancel task deletion")
            .accessibilityIdentifier("cancel-delete-task-button")
        } message: {
            Text("The task conversation and saved working folders will also be deleted.")
        }
        .alert("Pull request operation failed", isPresented: Binding(
            get: { pullRequestError != nil },
            set: { if !$0 { pullRequestError = nil } }
        )) {
            Button("OK", role: .cancel) { pullRequestError = nil }
            .buttonHoverPointer()
            .help("Dismiss pull request error")
        } message: {
            Text(pullRequestError ?? "Please try again.")
        }
        .alert("Couldn't check pull request status", isPresented: Binding(
            get: { doneMoveError != nil },
            set: { if !$0 { doneMoveError = nil } }
        )) {
            Button("OK", role: .cancel) { doneMoveError = nil }
            .buttonHoverPointer()
            .help("Dismiss pull request status error")
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
            .buttonHoverPointer()
            .help("Mark Done Anyway")
            Button("Cancel", role: .cancel) { taskAwaitingUnmergedConfirmation = nil }
            .buttonHoverPointer()
            .help("Cancel marking this task Done")
        } message: {
            Text("The pull request hasn't been merged. Marking this task Done will keep its worktree and branch as they are.")
        }
        .alert("Some task worktrees were kept", isPresented: Binding(
            get: { lifecycleResetNotice != nil },
            set: { if !$0 { lifecycleResetNotice = nil } }
        )) {
            Button("OK", role: .cancel) { lifecycleResetNotice = nil }
                .buttonHoverPointer()
                .help("Dismiss worktree notice")
        } message: {
            Text(lifecycleResetNotice ?? "")
        }
        .alert("Couldn't save changes", isPresented: isShowingSaveError) {
            Button("OK", role: .cancel) {
                saveError = nil
            }
            .buttonHoverPointer()
            .help("Dismiss save error")
        } message: {
            Text(saveError ?? "Please try again.")
        }
    }

    private var boardContent: some View {
        VStack(spacing: 0) {
            boardHeader

            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 1)

            if let lifecycleResetNotice {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Some task worktrees were kept")
                            .font(.system(size: 12, weight: .semibold))
                            .accessibilityIdentifier("task-lifecycle-reset-title")
                        Text(lifecycleResetNotice)
                            .font(.system(size: 11))
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("task-lifecycle-reset-details")
                    }
                    Spacer(minLength: 8)
                    Button("OK") { self.lifecycleResetNotice = nil }
                        .buttonHoverPointer()
                        .help("Dismiss worktree notice")
                        .accessibilityIdentifier("dismiss-task-lifecycle-reset-notice")
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(WorkspaceTheme.panelBackground)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("task-lifecycle-reset-notice")
            }

            ScrollView([.horizontal, .vertical]) {
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
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 30)
                .padding(.top, 22)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.visible)
            .background(WorkspaceTheme.windowBackground)
            .scrollContentBackground(.hidden)
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
        .overlay(alignment: .topTrailing) {
            if isShowingBoardSearch {
                boardSearchBar
                    .frame(width: 360)
                    .padding(.top, 16)
                    .padding(.trailing, 20)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .zIndex(2)
            }
        }
        .overlay(alignment: .trailing) {
            if isShowingDoneArchive {
                doneArchivePanel
                    .frame(width: 340)
                    .frame(maxHeight: .infinity)
                    .background(WorkspaceTheme.windowBackground)
                    .overlay(alignment: .leading) { Rectangle().fill(Color.primary.opacity(0.10)).frame(width: 1) }
                    .shadow(color: .black.opacity(0.16), radius: 18, x: -6, y: 0)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .accessibilityElement(children: .contain)
            }
        }
        .animation(.easeInOut(duration: 0.24), value: isShowingDoneArchive)
        .task(id: "\(isShowingDoneArchive)-\(archiveSearchText)") {
            guard isShowingDoneArchive else { return }
            if archiveTasks.isEmpty && archiveHasMore { loadNextArchivePage() }
            let query = archiveSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { archiveSearchResults = nil; return }
            archiveSearchResults = nil
            isIndexingArchive = true
            defer { isIndexingArchive = false }
            do {
                try await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                let records = try await remoteConversations.searchArchive(query: query)
                guard !Task.isCancelled else { return }
                archiveSearchResults = records.compactMap { try? BoardTaskManager(modelContext: modelContext).taskModel($0.id) }
            } catch is CancellationError {
                return
            } catch {
                presentSaveError(error.localizedDescription)
                archiveSearchResults = []
            }
        }
    }

    @ViewBuilder
    private func kanbanColumn(_ status: TaskStatus, minHeight: CGFloat = 480) -> some View {
        KanbanColumnView(
            status: status,
            tasks: tasks.filter { task in
                task.status == status && (boardSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || task.title.localizedCaseInsensitiveContains(boardSearchText.trimmingCharacters(in: .whitespacesAndNewlines)))
            },
            onMoveTask: { id, status in moveTask(id: id, to: status) },
            onCreatePullRequests: { createPullRequests(for: $0) },
            onResolveConflicts: {
                conflictResolutionTaskID = $0.id
                selectedTask = $0
            },
            creatingPullRequestTaskIDs: taskCreatingPullRequests,
            mergedReviewTaskIDs: mergedReviewTaskIDs,
            conflictedReviewTaskIDs: conflictedReviewTaskIDs,
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

    private var boardSearchBar: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(WorkspaceTheme.accent)
            TextField("Search tasks", text: $boardSearchText)
                .font(.system(size: 14))
                .textFieldStyle(.plain)
                .focused($isBoardSearchFocused)
                .accessibilityIdentifier("board-search-field")
                .onKeyPress(.escape) {
                    boardSearchText = ""
                    withAnimation(.easeInOut(duration: 0.18)) { isShowingBoardSearch = false }
                    isBoardSearchFocused = false
                    return .handled
                }
            if !boardSearchText.isEmpty {
                Text("\(tasks.filter { $0.status != .done && $0.title.localizedCaseInsensitiveContains(boardSearchText.trimmingCharacters(in: .whitespacesAndNewlines)) }.count) matches")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("board-search-match-count")
                Button { boardSearchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                    .buttonStyle(.plain)
                    .buttonHoverPointer()
                    .help("Clear search")
                    .accessibilityIdentifier("clear-board-search-button")
            }
            Button {
                boardSearchText = ""
                withAnimation(.easeInOut(duration: 0.18)) { isShowingBoardSearch = false }
                isBoardSearchFocused = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .buttonHoverPointer()
            .help("Close search")
            .accessibilityLabel("Close search")
            .accessibilityIdentifier("close-board-search-button")
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.10), radius: 10, y: 3)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("board-search-bar")
    }

    private var boardHeader: some View {
        HStack(alignment: .center, spacing: 24) {
            HStack(spacing: 14) {
                Image("StationAILogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 50, height: 50)
                    .accessibilityLabel("StationAI logo")

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
                    withAnimation(.easeInOut(duration: 0.18)) { isShowingBoardSearch = true }
                    isBoardSearchFocused = true
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 30, height: 30)
                }
                .buttonHoverPointer()
                .buttonStyle(.bordered)
                .help("Search tasks")
                .accessibilityLabel("Search tasks")
                .accessibilityIdentifier("board-search-button")

                Button {
                    withAnimation(.easeInOut(duration: 0.24)) { isShowingDoneArchive.toggle() }
                } label: {
                    Image(systemName: "archivebox")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 30, height: 30)
                }
                .buttonHoverPointer()
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
                .buttonHoverPointer()
                .help("Create a new task")
                .buttonStyle(.borderedProminent)
                .tint(WorkspaceTheme.accent)
                .disabled(isCreatingNewTask)
                .accessibilityIdentifier("new-task-button")
            }
        }
        .padding(.horizontal, 30)
        .padding(.top, 24)
        .padding(.bottom, 21)
    }

    private var doneArchivePanel: some View {
        let query = archiveSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let completed = query.isEmpty ? archiveTasks : (archiveSearchResults ?? [])
        let results = completed
        return VStack(spacing: 0) {
            HStack {
                Text("Done tasks").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button { closeDoneArchive() } label: { Image(systemName: "xmark") }
                .buttonHoverPointer()
                .help("Close done tasks")
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
                    .buttonHoverPointer()
                    .help("Clear archive search")
                        .buttonStyle(.plain).accessibilityLabel("Clear archive search")
                        .accessibilityIdentifier("clear-archive-search-button")
                }
            }
            .padding(10).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9)).padding(12)
            if results.isEmpty && (query.isEmpty ? !archiveHasMore && !isLoadingArchivePage : archiveSearchResults != nil) && !isIndexingArchive {
                Text(query.isEmpty ? "No completed tasks" : "No matching tasks")
                    .font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("done-archive-empty-state")
            } else {
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(results) { task in
                            Button {
                                selectedTask = task
                                isSelectedTaskNew = false
                                closeDoneArchive()
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
                            .buttonHoverPointer()
                            .help("Open task: \(task.title)")
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("done-archive-task-\(task.id.uuidString)")
                            .onAppear {
                                if query.isEmpty && task.id == archiveTasks.last?.id { loadNextArchivePage() }
                            }
                            .overlay(alignment: .trailing) {
                                if !task.repositoryWorktrees.isEmpty {
                                    archivedTaskPullRequestControl(task)
                                        .buttonStyle(.borderless)
                                        .padding(.trailing, 10)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    if isLoadingArchivePage || isIndexingArchive {
                        ProgressView().controlSize(.small).padding(12)
                    }
                }
                .scrollIndicators(.visible)
                .accessibilityIdentifier("done-archive-list")
                .accessibilityValue("\(archiveTasks.count) tasks loaded")
            }
        }
    }

    @ViewBuilder
    private func archivedTaskPullRequestControl(_ task: BoardTask) -> some View {
        let linked = task.repositoryWorktrees.filter { $0.pullRequestNumber != nil && $0.pullRequestURL != nil }
        if linked.isEmpty {
            Button {
                createPullRequests(for: task)
            } label: {
                if taskCreatingPullRequests.contains(task.id) {
                    ProgressView().controlSize(.mini)
                } else {
                    Text("PR").font(.system(size: 10, weight: .semibold))
                            .frame(minWidth: 30, minHeight: 30)
                }
            }
            .actionButtonHoverEmphasis()
            .buttonHoverPointer()
            .help("Create a pull request for each repository linked to this completed task")
            .disabled(taskCreatingPullRequests.contains(task.id))
            .frame(width: 30, height: 30)
            .contentShape(Rectangle())
            .accessibilityLabel("Create a pull request for each repository linked to this completed task")
            .accessibilityIdentifier("done-archive-create-pr-\(task.id.uuidString)")
        } else {
            HStack(spacing: 5) {
                ForEach(linked, id: \.repositoryPath) { record in
                    if let number = record.pullRequestNumber, let url = URL(string: record.pullRequestURL ?? "") {
                        Link("#\(number)", destination: url)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .frame(minWidth: 30, minHeight: 30)
                            .actionButtonHoverEmphasis()
                            .buttonHoverPointer()
                            .help("Open pull request #\(number) in your browser")
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                            .accessibilityIdentifier("done-archive-pr-link-\(task.id.uuidString)-\(number)")
                    }
                }
            }
        }
    }

    @MainActor
    private func loadNextArchivePage() {
        guard isShowingDoneArchive, archiveHasMore, !isLoadingArchivePage else { return }
        isLoadingArchivePage = true
        var descriptor = FetchDescriptor<BoardTask>(
            predicate: #Predicate { $0.statusRawValue == "Done" },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchOffset = archiveOffset
        descriptor.fetchLimit = 40
        do {
            let page = try modelContext.fetch(descriptor)
            archiveTasks.append(contentsOf: page)
            archiveOffset += page.count
            archiveHasMore = page.count == 40
        } catch {
            presentSaveError(error.localizedDescription)
            archiveHasMore = false
        }
        isLoadingArchivePage = false
    }

    @MainActor
    private func closeDoneArchive() {
        isShowingDoneArchive = false
        archiveTasks = []
        archiveSearchResults = nil
        archiveOffset = 0
        archiveHasMore = true
    }

    private func presentSaveError(_ message: String) {
        saveError = message
    }

    private var isShowingSaveError: Binding<Bool> {
        Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )
    }

    private func openNewTask() {
        guard !isCreatingNewTask else { return }
        isCreatingNewTask = true
        let attemptID = UUID().uuidString
        let startedAt = DispatchTime.now().uptimeNanoseconds
        StationAIDiagnostics.record("ui.new_task.started", fields: [
            "attemptID": attemptID
        ])
        Task { @MainActor in
            defer { isCreatingNewTask = false }
            do {
                let manager = BoardTaskManager(modelContext: modelContext)
                let created = try await manager.create(
                    title: "Untitled task",
                    repositories: [],
                    contextFolders: [],
                    provider: WorkspaceSettingsManager().defaultConversationProvider
                )
                let newTask = try manager.taskModel(created.id)
                selectedTask = newTask
                isSelectedTaskNew = true
                StationAIDiagnostics.record("ui.new_task.succeeded", fields: [
                    "attemptID": attemptID,
                    "taskID": created.id.uuidString,
                    "durationMilliseconds": String((DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000)
                ])
            } catch {
                let nsError = error as NSError
                StationAIDiagnostics.record("ui.new_task.failed", fields: [
                    "attemptID": attemptID,
                    "durationMilliseconds": String((DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000),
                    "errorDomain": nsError.domain,
                    "errorCode": String(nsError.code),
                    "errorDescription": error.localizedDescription
                ])
                presentSaveError(error.localizedDescription)
            }
        }
    }

    private func moveTask(id: UUID, to status: TaskStatus, allowUnmergedPullRequests: Bool = false) {
        guard let task = tasks.first(where: { $0.id == id }), task.status != status else { return }
        guard status == .done else { return }
        let skipMergeVerification = mergedReviewTaskIDs.contains(id)
        Task { @MainActor in
            do {
                _ = try await BoardTaskManager(modelContext: modelContext).move(
                    id,
                    to: status.rawValue,
                    allowUnmergedPullRequests: allowUnmergedPullRequests,
                    skipMergeVerification: skipMergeVerification
                )
            } catch StationAIManagerError.unmergedPullRequests {
                taskAwaitingUnmergedConfirmation = id
            } catch {
                doneMoveError = error.localizedDescription
            }
        }
    }

    private func checkReviewPullRequests() {
        let now = Date()
        // Tests shorten the cooldown; what they check (checks suppressed while it runs,
        // then exactly one trailing check) does not depend on its length.
        let minimumInterval = ProcessInfo.processInfo.environment["STATIONAI_E2E_PR_CHECK_COOLDOWN_SECONDS"]
            .flatMap(TimeInterval.init) ?? 20
        if checkingMergedPullRequests {
            mergedPullRequestCheckPending = true
            return
        }
        if let lastMergedPullRequestCheckAt {
            let remaining = minimumInterval - now.timeIntervalSince(lastMergedPullRequestCheckAt)
            if remaining > 0 {
                mergedPullRequestCheckPending = true
                guard !mergedPullRequestCheckTimerScheduled else { return }
                mergedPullRequestCheckTimerScheduled = true
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(remaining))
                    mergedPullRequestCheckTimerScheduled = false
                    guard mergedPullRequestCheckPending else { return }
                    mergedPullRequestCheckPending = false
                    checkReviewPullRequests()
                }
                return
            }
        }
        let reviewTasks = tasks.filter { task in
            task.status == .review && task.repositoryWorktrees.contains {
                !$0.isPending && $0.pullRequestNumber != nil
            }
        }
        let reviewIDs = reviewTasks.map(\.id)
        guard !reviewIDs.isEmpty else {
            mergedReviewTaskIDs = []
            conflictedReviewTaskIDs = []
            return
        }
        lastMergedPullRequestCheckAt = now
        checkingMergedPullRequests = true
        Task { @MainActor in
            defer {
                checkingMergedPullRequests = false
                if mergedPullRequestCheckPending {
                    mergedPullRequestCheckPending = false
                    checkReviewPullRequests()
                }
            }
            let manager = BoardTaskManager(modelContext: modelContext)
            await withTaskGroup(of: (UUID, [PullRequestReviewState]?, String?).self) { group in
                for task in reviewTasks {
                    group.addTask {
                        do { return (task.id, try await manager.reviewPullRequests(task), nil) }
                        catch { return (task.id, nil, error.localizedDescription) }
                    }
                }
                for await (id, states, error) in group {
                    if let states {
                        if states.isEmpty {
                            // The persisted query can briefly lag the visible
                            // SwiftData task after an external store update.
                            // Allow the already-coalesced appearance/focus check
                            // to retry immediately with the refreshed records.
                            lastMergedPullRequestCheckAt = nil
                        }
                        if !states.isEmpty && states.allSatisfy(\.merged) { mergedReviewTaskIDs.insert(id) }
                        else { mergedReviewTaskIDs.remove(id) }
                        if states.contains(where: \.requiresConflictResolution) { conflictedReviewTaskIDs.insert(id) }
                        else { conflictedReviewTaskIDs.remove(id) }
                    } else if let error {
                        mergedReviewTaskIDs.remove(id)
                        conflictedReviewTaskIDs.remove(id)
                        pullRequestError = error
                    }
                }
            }
            mergedReviewTaskIDs.formIntersection(reviewIDs)
            conflictedReviewTaskIDs.formIntersection(reviewIDs)
        }
    }

    private var reviewPullRequestSignature: [String] {
        tasks.flatMap { task in
            task.repositoryWorktrees.compactMap { record in
                guard task.status == .review, let number = record.pullRequestNumber else {
                    return nil
                }
                return "\(task.id.uuidString):\(record.repositoryPath):\(number)"
            }
        }.sorted()
    }

    private func createPullRequests(for task: BoardTask) {
        guard taskCreatingPullRequests.insert(task.id).inserted else { return }
        Task { @MainActor in
            defer { taskCreatingPullRequests.remove(task.id) }
            do {
                let manager = BoardTaskManager(modelContext: modelContext)
                let conflictRepositories = try await manager.pullRequestConflictRepositories(task.id)
                if !conflictRepositories.isEmpty {
                    throw BridgeCommandError(code: "conflicts_require_confirmation", message: "Resolve conflicts in the task worktree before creating pull requests.")
                }
                _ = try await remoteConversations.createPullRequests(taskID: task.id)
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
            if let mouseUpMonitor {
                NSEvent.removeMonitor(mouseUpMonitor)
                self.mouseUpMonitor = nil
            }
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Move task to Done")
        .accessibilityHint("Drop a reviewed task here to move it to Done.")
    }
}

private struct KanbanColumnView: View {
    let status: TaskStatus
    let tasks: [BoardTask]
    let onMoveTask: (UUID, TaskStatus) -> Void
    let onCreatePullRequests: (BoardTask) -> Void
    let onResolveConflicts: (BoardTask) -> Void
    let creatingPullRequestTaskIDs: Set<UUID>
    let mergedReviewTaskIDs: Set<UUID>
    let conflictedReviewTaskIDs: Set<UUID>
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
                    .buttonHoverPointer()
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
            onResolveConflicts: { onResolveConflicts(task) },
            isCreatingPullRequests: creatingPullRequestTaskIDs.contains(task.id),
            isPullRequestMerged: mergedReviewTaskIDs.contains(task.id),
            hasPullRequestConflicts: conflictedReviewTaskIDs.contains(task.id),
            onMoveToDone: task.status == .review ? { onMoveTask(task.id, .done) } : nil
        )
        if task.status == .waitingResponse {
            card
        } else if task.status == .review {
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
    let onResolveConflicts: () -> Void
    let isCreatingPullRequests: Bool
    let isPullRequestMerged: Bool
    let hasPullRequestConflicts: Bool
    let onMoveToDone: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            if showPullRequestControls || hasLiveStatus {
                HStack(alignment: .center, spacing: 6) {
                    if showPullRequestControls {
                        pullRequestControls
                        Spacer(minLength: 8)
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
                                    .foregroundStyle(WorkspaceTheme.conversationText)
                                    .accessibilityIdentifier("task-progress-label-\(task.id.uuidString)")
                                if let progressDetail = task.progressDetail, !progressDetail.isEmpty {
                                    Text(progressDetail)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .accessibilityIdentifier("task-progress-detail-\(task.id.uuidString)")
                                }
                            }
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("task-progress-report-\(task.id.uuidString)")
                        .accessibilityLabel([progressLabel, task.progressDetail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "))
                        .accessibilityValue("Progress icon: \(TaskProgressType(rawValue: task.progressTypeRawValue ?? "")?.symbol ?? "sparkle")")
                    }
                }
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
                    .lineSpacing(2)
            }
                .font(.system(size: 13, weight: .semibold))
                .tracking(0.35)
                .foregroundStyle(WorkspaceTheme.conversationText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("task-title-\(task.id.uuidString)")

            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .font(.system(size: 10))
                if task.status == .inProgress {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(workingDuration(at: context.date))
                            .font(.system(size: 10))
                            .accessibilityIdentifier("task-working-duration-\(task.id.uuidString)")
                    }
                } else {
                    Text(task.createdAt.formatted(date: .abbreviated, time: .omitted))
                        .font(.system(size: 10))
                }
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
        .background {
            Button(action: {
                DispatchQueue.main.async(execute: onOpen)
            }) {
                Color.clear
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .buttonHoverPointer()
            .buttonStyle(.plain)
            .help("Open task: \(task.title)")
            .accessibilityLabel(task.title)
            .accessibilityHint("Open task")
            .accessibilityIdentifier("task-card-\(task.id.uuidString)")
        }
        .accessibilityElement(children: .contain)
        .contextMenu {
            if let onMoveToDone {
                Button("Move to Done", systemImage: "checkmark.circle", action: onMoveToDone)
                .buttonHoverPointer()
                .help("Move to Done")
                    .accessibilityIdentifier("move-task-to-done-menu-item")
            }
            Button("Rename…", systemImage: "pencil", action: onRename)
            .buttonHoverPointer()
            .help("Rename")
                .accessibilityIdentifier("rename-task-menu-item")
            Button("Delete Task", systemImage: "trash", role: .destructive, action: onDelete)
            .buttonHoverPointer()
            .help("Delete Task")
                .accessibilityIdentifier("delete-task-menu-item")
        }
    }

    private var linkedPullRequests: [RepositoryWorktreeRecord] {
        task.repositoryWorktrees.filter { $0.pullRequestNumber != nil && $0.pullRequestURL != nil }
    }

    private var showPullRequestControls: Bool {
        task.status != .backlog && !task.repositoryWorktrees.isEmpty
    }

    private var hasLiveStatus: Bool {
        guard let progressLabel = task.progressLabel else { return false }
        return !progressLabel.isEmpty
    }

    @ViewBuilder
    private var pullRequestControls: some View {
        HStack(spacing: 5) {
            let linked = linkedPullRequests
            if linked.isEmpty {
                Button(action: onCreatePullRequests) {
                    if isCreatingPullRequests {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text("PR").font(.system(size: 10, weight: .semibold))
                            .frame(minWidth: 30, minHeight: 30)
                    }
                }
                .actionButtonHoverEmphasis(padding: 10)
                .buttonHoverPointer()
                .help("Create a pull request for each repository linked to this task")
                .disabled(isCreatingPullRequests)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
                .accessibilityLabel("Create a pull request for each repository linked to this task")
                .accessibilityIdentifier("task-create-pr-\(task.id.uuidString)")
            } else {
                if isPullRequestMerged, let onMoveToDone {
                    Button(action: onMoveToDone) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.green)
                    }
                    .actionButtonHoverEmphasis(padding: 10)
                    .buttonHoverPointer()
                    .help("Complete task: all linked pull requests have merged")
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
                    .accessibilityLabel("Green checkmark. Complete task, all linked pull requests merged")
                    .accessibilityIdentifier("task-complete-merged-pr-\(task.id.uuidString)")
                } else {
                    if hasPullRequestConflicts {
                        Button(action: onResolveConflicts) {
                            Image("ConflictIndicator")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 30, height: 12)
                                .accessibilityIdentifier("task-resolve-pr-conflicts-icon-\(task.id.uuidString)")
                        }
                        .actionButtonHoverEmphasis(padding: 10)
                        .buttonHoverPointer()
                        .help("Resolve pull request conflicts with \(task.conversationProvider.displayName)")
                        .accessibilityLabel("Resolve pull request conflicts")
                        .accessibilityIdentifier("task-resolve-pr-conflicts-\(task.id.uuidString)")
                        .frame(minWidth: 30, minHeight: 30)
                        .contentShape(Rectangle())
                    }
                    ForEach(linked, id: \.repositoryPath) { record in
                        if let number = record.pullRequestNumber, let url = URL(string: record.pullRequestURL ?? "") {
                            Link("#\(number)", destination: url)
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .frame(minWidth: 30, minHeight: 30)
                                .actionButtonHoverEmphasis(padding: 10)
                                .buttonHoverPointer()
                                .help("Open pull request #\(number) in your browser")
                                .frame(width: 30, height: 30)
                                .contentShape(Rectangle())
                                .accessibilityIdentifier("task-pr-link-\(task.id.uuidString)-\(number)")
                        }
                    }
                }
            }
        }
        .buttonStyle(.borderless)
    }

    private func workingDuration(at date: Date) -> String {
        let activeInterval = task.inProgressStartedAt.map { max(0, date.timeIntervalSince($0)) } ?? 0
        let activeText = Self.shortDuration(activeInterval)
        guard task.totalInProgressSeconds > 0 else { return "Working for \(activeText)" }
        return "Working for \(activeText) (\(Self.shortDuration(task.totalInProgressSeconds + activeInterval)) total)"
    }

    private static func shortDuration(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(Int(seconds))s" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h\(minutes % 60 == 0 ? "" : " \(minutes % 60)m")" }
        let days = hours / 24
        return "\(days)d\(hours % 24 == 0 ? "" : " \(hours % 24)h")"
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
                .buttonHoverPointer()
                .help("Cancel")
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(normalizedTitle)
                    dismiss()
                }
                .buttonHoverPointer()
                .help("Save")
                .buttonStyle(.borderedProminent)
                .disabled(normalizedTitle.isEmpty)
                .accessibilityIdentifier("save-task-rename-button")
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}
