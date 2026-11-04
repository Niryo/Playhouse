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
    @State private var taskShowingTokenStats: BoardTask?
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
    @State private var syncingReviewTaskIDs = Set<UUID>()
    @State private var attemptedReviewSyncSignatures: [UUID: String] = [:]
    /// Last probed check colour of each linked PR, keyed by task then PR number.
    @State private var pullRequestHealth: [UUID: [Int: PullRequestHealth]] = [:]
    /// Autopilot tasks the daemon is probing or fixing right now.
    @State private var autopilotRunningTaskIDs = Set<UUID>()
    /// Autopilot tasks whose PRs were last seen with checks still running.
    @State private var autopilotPendingTaskIDs = Set<UUID>()
    @State private var autopilotPollScheduled = false
    @State private var pullRequestError: String?
    @State private var doneMoveError: String?
    @State private var isShowingBoardSearch = false
    @State private var boardSearchText = ""
    @FocusState private var isBoardSearchFocused: Bool
    @State private var isShowingChatSidebar = false
    @State private var chatTask: StandaloneChat?
    @State private var isOpeningChatSidebar = false

    /// Provider-owning operations run in the bridge daemon.
    private var remoteConversations: RemoteConversationManager {
        RemoteConversationManager(daemon: conversationRuntime.client, runtime: conversationRuntime, modelContext: modelContext)
    }

    var body: some View {
        HStack(spacing: 0) {
            if isShowingChatSidebar, selectedTask == nil, let chatTask {
                TaskConversationView(
                    task: chatTask, isNewTask: false, isReadOnly: false,
                    conflictResolutionRequested: false,
                    onConflictResolutionChecked: { _ in }
                ) {
                    withAnimation(.easeInOut(duration: 0.22)) { isShowingChatSidebar = false }
                }
                .frame(width: 460)
                .transition(.move(edge: .leading).combined(with: .opacity))
                .id(chatTask.id)
                // Without a container, this identifier replaces the conversation controls' own.
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("chat-sidebar")
                Divider()
            }
            mainContent
        }
        .animation(.easeInOut(duration: 0.22), value: isShowingChatSidebar)
    }

    private var mainContent: some View {
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
            // The board renders from its own @Query, not the board.list path, so it has to
            // convert a chat still stored as a hidden task itself or that row shows as a card.
            try? BoardTaskManager(modelContext: modelContext).migrateLegacyStandaloneChatTasks()
            checkReviewPullRequests()
            let retained = PlayhouseStore.takeLifecycleResetNotice(
                dataDirectory: ProcessInfo.processInfo.environment["PLAYHOUSE_DATA_DIRECTORY"]
            )
            if !retained.isEmpty {
                lifecycleResetNotice = "Existing tasks were cleared. These dirty managed worktrees were kept:\n\n" + retained.joined(separator: "\n")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .playhouseShowBoardSearch)) { _ in
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
        .sheet(isPresented: Binding(
            get: { taskShowingTokenStats != nil },
            set: { if !$0 { taskShowingTokenStats = nil } }
        )) {
            if let taskShowingTokenStats {
                TokenStatsSheet(taskID: taskShowingTokenStats.id, taskTitle: taskShowingTokenStats.title, modelContext: modelContext)
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
                        presentSaveError("\(error.localizedDescription)\n\nDiagnostic log: \(PlayhouseDiagnostics.logURL.path)")
                    }
                    self.taskBeingDeleted = nil
                }
            }
            .buttonHoverPointer()
            .nativeHelp("Delete Task")
            .accessibilityIdentifier("confirm-delete-task-button")
            Button("Cancel", role: .cancel) {
                taskBeingDeleted = nil
            }
            .buttonHoverPointer()
            .nativeHelp("Cancel task deletion")
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
            .nativeHelp("Dismiss pull request error")
        } message: {
            Text(pullRequestError ?? "Please try again.")
        }
        .alert("Couldn't check pull request status", isPresented: Binding(
            get: { doneMoveError != nil },
            set: { if !$0 { doneMoveError = nil } }
        )) {
            Button("OK", role: .cancel) { doneMoveError = nil }
            .buttonHoverPointer()
            .nativeHelp("Dismiss pull request status error")
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
            .nativeHelp("Mark Done Anyway")
            Button("Cancel", role: .cancel) { taskAwaitingUnmergedConfirmation = nil }
            .buttonHoverPointer()
            .nativeHelp("Cancel marking this task Done")
        } message: {
            Text("The pull request hasn't been merged. Marking this task Done will keep its worktree and branch as they are.")
        }
        .alert("Some task worktrees were kept", isPresented: Binding(
            get: { lifecycleResetNotice != nil },
            set: { if !$0 { lifecycleResetNotice = nil } }
        )) {
            Button("OK", role: .cancel) { lifecycleResetNotice = nil }
                .buttonHoverPointer()
                .nativeHelp("Dismiss worktree notice")
        } message: {
            Text(lifecycleResetNotice ?? "")
        }
        .alert("Couldn't save changes", isPresented: isShowingSaveError) {
            Button("OK", role: .cancel) {
                saveError = nil
            }
            .buttonHoverPointer()
            .nativeHelp("Dismiss save error")
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
                        .nativeHelp("Dismiss worktree notice")
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
            onSetPullRequestMode: { task, mode in setPullRequestMode(for: task, mode: mode) },
            onResolveConflicts: {
                conflictResolutionTaskID = $0.id
                selectedTask = $0
            },
            creatingPullRequestTaskIDs: taskCreatingPullRequests,
            mergedReviewTaskIDs: mergedReviewTaskIDs,
            conflictedReviewTaskIDs: conflictedReviewTaskIDs,
            pullRequestHealth: pullRequestHealth,
            onAddTask: openNewTask,
            onOpenTask: { selectedTask = $0 },
            onRenameTask: { taskBeingRenamed = $0 },
            onDeleteTask: {
                taskBeingDeleted = $0
                isShowingDeleteConfirmation = true
            },
            onShowTaskTokenStats: { taskShowingTokenStats = $0 },
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
                    .nativeHelp("Clear search")
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
            .nativeHelp("Close search")
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
                Image("PlayhouseLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 50, height: 50)
                    .accessibilityLabel("Playhouse logo")

                VStack(alignment: .leading, spacing: 3) {
                    Text("Playhouse")
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
                .nativeHelp("Search tasks")
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
                .nativeHelp("Browse completed tasks")
                .accessibilityLabel("Done tasks")
                .accessibilityIdentifier("done-archive-button")

                Button {
                    openChatSidebar()
                } label: {
                    Label("Chat", systemImage: "bubble.left.and.bubble.right")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                }
                .buttonHoverPointer()
                .nativeHelp("Open the standalone chat")
                .buttonStyle(.bordered)
                .disabled(isOpeningChatSidebar)
                .accessibilityIdentifier("chat-sidebar-button")

                Button {
                    openNewTask()
                } label: {
                    Label("New Task", systemImage: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                }
                .buttonHoverPointer()
                .nativeHelp("Create a new task")
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
                .nativeHelp("Close done tasks")
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
                    .nativeHelp("Clear archive search")
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
                            HStack(spacing: 0) {
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
                                .nativeHelp("Open task: \(task.title)")
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("done-archive-task-\(task.id.uuidString)")
                                if !task.repositoryWorktrees.isEmpty {
                                    archivedTaskPullRequestControl(task)
                                        .buttonStyle(.borderless)
                                        .padding(.trailing, 10)
                                }
                            }
                            .onAppear {
                                if query.isEmpty && task.id == archiveTasks.last?.id { loadNextArchivePage() }
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
        let missingPullRequests = task.repositoryWorktrees.contains { !$0.isPending && ($0.pullRequestNumber == nil || $0.pullRequestURL == nil) }
        if linked.isEmpty {
            let hasMultipleRepositories = task.repositoryWorktrees.filter { !$0.isPending }.count > 1
            Button {
                createPullRequests(for: task)
            } label: {
                if taskCreatingPullRequests.contains(task.id) {
                    ProgressView().controlSize(.mini)
                } else {
                    Text(hasMultipleRepositories ? "PRs" : "PR").font(.system(size: 10, weight: .semibold))
                            .frame(minWidth: 30, minHeight: 30)
                }
            }
            .actionButtonHoverEmphasis()
            .buttonHoverPointer()
            .nativeHelp("Create a pull request for each repository linked to this completed task")
            .disabled(taskCreatingPullRequests.contains(task.id))
            .frame(width: 30, height: 30)
            .contentShape(Rectangle())
            .accessibilityLabel(hasMultipleRepositories ? "PRs. Create pull requests for each repository linked to this completed task" : "PR. Create a pull request for each repository linked to this completed task")
            .accessibilityIdentifier("done-archive-create-pr-\(task.id.uuidString)")
        } else {
            HStack(spacing: 5) {
                if missingPullRequests {
                    Button {
                        createPullRequests(for: task)
                    } label: {
                        if taskCreatingPullRequests.contains(task.id) {
                            ProgressView().controlSize(.mini)
                        } else {
                            Text(task.repositoryWorktrees.filter { !$0.isPending }.count > 1 ? "PRs" : "PR")
                                .font(.system(size: 10, weight: .semibold))
                        }
                    }
                    .actionButtonHoverEmphasis()
                    .buttonHoverPointer()
                    .nativeHelp("Create pull requests for repositories without a linked pull request")
                    .disabled(taskCreatingPullRequests.contains(task.id))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
                    .accessibilityLabel(task.repositoryWorktrees.filter { !$0.isPending }.count > 1 ? "PRs. Create pull requests for repositories without a linked pull request" : "PR. Create a pull request for the repository without a linked pull request")
                    .accessibilityIdentifier("done-archive-create-pr-\(task.id.uuidString)")
                }
                ForEach(linked, id: \.repositoryPath) { record in
                    if let number = record.pullRequestNumber, let url = URL(string: record.pullRequestURL ?? "") {
                        Link(destination: url) {
                            Text(verbatim: "#\(number)")
                        }
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .actionButtonHoverEmphasis(padding: 5)
                            .buttonHoverPointer()
                            .nativeHelp(URL(fileURLWithPath: record.repositoryPath).lastPathComponent)
                            // The chip stays compact; the click target keeps the 30 pt minimum of its sibling actions.
                            .frame(minWidth: 30, minHeight: 30)
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

    private func openChatSidebar() {
        if isShowingChatSidebar {
            withAnimation(.easeInOut(duration: 0.22)) { isShowingChatSidebar = false }
            return
        }
        guard !isOpeningChatSidebar else { return }
        if let chatTask {
            withAnimation(.easeInOut(duration: 0.22)) {
                self.chatTask = chatTask
                isShowingChatSidebar = true
            }
            return
        }
        isOpeningChatSidebar = true
        Task { @MainActor in
            defer { isOpeningChatSidebar = false }
            do {
                let manager = BoardTaskManager(modelContext: modelContext)
                let record = try await manager.getOrCreateStandaloneChat(
                    provider: WorkspaceSettingsManager().defaultConversationProvider
                )
                guard let chat = try manager.standaloneChatModel(record.id) else {
                    throw BridgeCommandError(code: "operation_failed", message: "The standalone chat could not be opened.")
                }
                chatTask = chat
                withAnimation(.easeInOut(duration: 0.22)) { isShowingChatSidebar = true }
            } catch {
                saveError = error.localizedDescription
            }
        }
    }

    private func openNewTask() {
        guard !isCreatingNewTask else { return }
        isCreatingNewTask = true
        let attemptID = UUID().uuidString
        let startedAt = DispatchTime.now().uptimeNanoseconds
        PlayhouseDiagnostics.record("ui.new_task.started", fields: [
            "attemptID": attemptID
        ])
        Task { @MainActor in
            defer { isCreatingNewTask = false }
            do {
                let manager = BoardTaskManager(modelContext: modelContext)
                let settings = WorkspaceSettingsManager()
                let created = try await manager.create(
                    title: "Untitled task",
                    repositories: [],
                    contextFolders: [],
                    provider: settings.defaultConversationProvider,
                    pullRequestMode: settings.pullRequestModeDefault
                )
                let newTask = try manager.taskModel(created.id)
                selectedTask = newTask
                isSelectedTaskNew = true
                PlayhouseDiagnostics.record("ui.new_task.succeeded", fields: [
                    "attemptID": attemptID,
                    "taskID": created.id.uuidString,
                    "durationMilliseconds": String((DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000)
                ])
            } catch {
                let nsError = error as NSError
                PlayhouseDiagnostics.record("ui.new_task.failed", fields: [
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
            } catch PlayhouseManagerError.unmergedPullRequests {
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
        let minimumInterval = ProcessInfo.processInfo.environment["PLAYHOUSE_E2E_PR_CHECK_COOLDOWN_SECONDS"]
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
                        recordPullRequestHealth(id, states: states)
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
                        syncReviewChangesIfNeeded(for: id, states: states)
                        followPullRequestAutopilot(for: id, states: states)
                    } else if let error {
                        mergedReviewTaskIDs.remove(id)
                        conflictedReviewTaskIDs.remove(id)
                        pullRequestError = error
                    }
                }
            }
            mergedReviewTaskIDs.formIntersection(reviewIDs)
            conflictedReviewTaskIDs.formIntersection(reviewIDs)
            autopilotPendingTaskIDs.formIntersection(reviewIDs)
            scheduleAutopilotPollIfNeeded()
        }
    }

    /// A card keeps its last colours while a fix turn runs; they refresh on the
    /// next probe once the task is back in Review.
    private func recordPullRequestHealth(_ id: UUID, states: [PullRequestReviewState]) {
        guard !states.isEmpty else { return }
        pullRequestHealth[id] = Dictionary(states.map { ($0.number, $0.health) }, uniquingKeysWith: { _, new in new })
    }

    /// Autopilot tasks act on what the probe found: red asks the daemon to run a
    /// fix turn (it re-probes and decides through the same shared assessment),
    /// pending keeps the slow poll alive, and green or merged lets it stop.
    private func followPullRequestAutopilot(for id: UUID, states: [PullRequestReviewState]) {
        guard let task = tasks.first(where: { $0.id == id }), task.pullRequestAutopilot, task.status == .review else {
            autopilotPendingTaskIDs.remove(id)
            return
        }
        switch BoardTaskManager.assessPullRequestAutopilot(states) {
        case .pending:
            autopilotPendingTaskIDs.insert(id)
        case .merged:
            autopilotPendingTaskIDs.remove(id)
        case .green:
            autopilotPendingTaskIDs.remove(id)
            // The daemon owns the loop guard and the merge: let it confirm green,
            // reset the fix streak so a later red state gets a full set of
            // attempts, and in merge mode merge the PRs.
            if task.pullRequestAutoMerge || task.pullRequestAutopilotFixAttempts > 0 || task.pullRequestAutopilotLastFixSignature != nil {
                runPullRequestAutopilot(for: id)
            }
        case .needsFix:
            autopilotPendingTaskIDs.remove(id)
            runPullRequestAutopilot(for: id)
        }
    }

    private func runPullRequestAutopilot(for id: UUID) {
        guard autopilotRunningTaskIDs.insert(id).inserted else {
            // A probe that lands while the previous pass is still finishing must
            // not be lost: the poll looks again shortly.
            autopilotPendingTaskIDs.insert(id)
            scheduleAutopilotPollIfNeeded()
            return
        }
        Task { @MainActor in
            defer { autopilotRunningTaskIDs.remove(id) }
            do {
                let outcome = try await remoteConversations.runPullRequestAutopilot(taskID: id) { states in
                    recordPullRequestHealth(id, states: states)
                }
                switch outcome.action {
                case "fixed", "merged":
                    // Its states predate the fix or merge; probe the task's PRs
                    // afresh so the card shows where they stand now.
                    lastMergedPullRequestCheckAt = nil
                    checkReviewPullRequests()
                case "green", "stalled":
                    recordPullRequestHealth(id, states: outcome.states)
                default:
                    recordPullRequestHealth(id, states: outcome.states)
                    autopilotPendingTaskIDs.insert(id)
                }
                scheduleAutopilotPollIfNeeded()
            } catch {
                pullRequestError = error.localizedDescription
            }
        }
    }

    /// While an autopilot PR still has checks running, re-probe just those tasks
    /// every few minutes. The poll stops once none are pending; a focus probe
    /// that finds one red again restarts it.
    private func scheduleAutopilotPollIfNeeded() {
        guard !autopilotPendingTaskIDs.isEmpty, !autopilotPollScheduled else { return }
        autopilotPollScheduled = true
        let interval = ProcessInfo.processInfo.environment["PLAYHOUSE_E2E_PR_AUTOPILOT_POLL_SECONDS"]
            .flatMap(TimeInterval.init) ?? 180
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(interval))
            autopilotPollScheduled = false
            let pending = tasks.filter { autopilotPendingTaskIDs.contains($0.id) && $0.status == .review && $0.pullRequestAutopilot }
            autopilotPendingTaskIDs = Set(pending.map(\.id))
            let manager = BoardTaskManager(modelContext: modelContext)
            for task in pending {
                do {
                    let states = try await manager.reviewPullRequests(task)
                    recordPullRequestHealth(task.id, states: states)
                    followPullRequestAutopilot(for: task.id, states: states)
                } catch {
                    autopilotPendingTaskIDs.remove(task.id)
                    pullRequestError = error.localizedDescription
                }
            }
            scheduleAutopilotPollIfNeeded()
        }
    }

    /// A reviewed task must not hold local-only pull request changes. When a
    /// probe finds the local and remote heads diverged on a mergeable PR, sync
    /// (commit, merge remote PR commits, push) through the shared bridge command.
    /// Each head pairing is attempted once, so a repository the sync cannot act
    /// on (for example, one with no publishing remote) keeps its conflict action
    /// without a retry loop; the daemon moves the task to Blocked when a sync fails.
    private func syncReviewChangesIfNeeded(for id: UUID, states: [PullRequestReviewState]) {
        let needsSync = states.contains { state in
            !state.merged && !state.hasConflicts && state.headRefOid != nil && state.headRefOid != state.localHeadOid
        }
        guard needsSync else { return }
        let signature = states
            .map { "\($0.number):\($0.headRefOid ?? "-"):\($0.localHeadOid ?? "-")" }
            .sorted()
            .joined(separator: "|")
        guard attemptedReviewSyncSignatures[id] != signature, !syncingReviewTaskIDs.contains(id) else { return }
        attemptedReviewSyncSignatures[id] = signature
        syncingReviewTaskIDs.insert(id)
        Task { @MainActor in
            defer { syncingReviewTaskIDs.remove(id) }
            do {
                let outcome = try await remoteConversations.syncPullRequestChanges(taskID: id)
                if outcome.skipped != nil {
                    // An active turn owns the worktree; let a later probe retry.
                    attemptedReviewSyncSignatures.removeValue(forKey: id)
                    return
                }
                guard outcome.records.contains(where: { $0.action.hasSuffix("pushed") }) else { return }
                lastMergedPullRequestCheckAt = nil
                checkReviewPullRequests()
            } catch {
                attemptedReviewSyncSignatures.removeValue(forKey: id)
                pullRequestError = error.localizedDescription
            }
        }
    }

    private var reviewPullRequestSignature: [String] {
        tasks.flatMap { task in
            task.repositoryWorktrees.compactMap { record in
                guard task.status == .review, let number = record.pullRequestNumber else {
                    return nil
                }
                // The mode is part of the key so turning autopilot on re-probes
                // once the board sees the change.
                return "\(task.id.uuidString):\(record.repositoryPath):\(number):\(task.pullRequestMode.rawValue)"
            }
        }.sorted()
    }

    private func createPullRequests(for task: BoardTask) {
        guard taskCreatingPullRequests.insert(task.id).inserted else { return }
        Task { @MainActor in
            defer { taskCreatingPullRequests.remove(task.id) }
            do {
                _ = try await remoteConversations.createPullRequests(taskID: task.id)
            } catch {
                pullRequestError = error.localizedDescription
            }
        }
    }

    private func setPullRequestMode(for task: BoardTask, mode: PullRequestMode) {
        Task { @MainActor in
            do {
                // Turning autopilot on in Review changes `reviewPullRequestSignature`,
                // which re-probes the PR and starts following it.
                _ = try await remoteConversations.setPullRequestMode(taskID: task.id, mode: mode)
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
    let onSetPullRequestMode: (BoardTask, PullRequestMode) -> Void
    let onResolveConflicts: (BoardTask) -> Void
    let creatingPullRequestTaskIDs: Set<UUID>
    let mergedReviewTaskIDs: Set<UUID>
    let conflictedReviewTaskIDs: Set<UUID>
    let pullRequestHealth: [UUID: [Int: PullRequestHealth]]
    let onAddTask: () -> Void
    let onOpenTask: (BoardTask) -> Void
    let onRenameTask: (BoardTask) -> Void
    let onDeleteTask: (BoardTask) -> Void
    let onShowTaskTokenStats: (BoardTask) -> Void
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
                    .nativeHelp("Add task to Backlog")
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
            onShowTokenStats: { onShowTaskTokenStats(task) },
            onCreatePullRequests: { onCreatePullRequests(task) },
            onSetPullRequestMode: { onSetPullRequestMode(task, $0) },
            onResolveConflicts: { onResolveConflicts(task) },
            isCreatingPullRequests: creatingPullRequestTaskIDs.contains(task.id),
            isPullRequestMerged: mergedReviewTaskIDs.contains(task.id),
            hasPullRequestConflicts: conflictedReviewTaskIDs.contains(task.id),
            pullRequestHealth: pullRequestHealth[task.id] ?? [:],
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
    @AppStorage(WorkspaceSettings.tokenUsageColorMaxKey, store: WorkspaceSettings.preferencesStore)
    private var tokenUsageColorMax = WorkspaceSettings.defaultTokenUsageColorMax
    @AppStorage(WorkspaceSettings.cpuUsageColorMaxKey, store: WorkspaceSettings.preferencesStore)
    private var cpuUsageColorMax = WorkspaceSettings.defaultCPUUsageColorMax
    @EnvironmentObject private var cpuUsageModel: TaskCPUUsageModel
    let task: BoardTask
    let onOpen: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    let onShowTokenStats: () -> Void
    let onCreatePullRequests: () -> Void
    let onSetPullRequestMode: (PullRequestMode) -> Void
    let onResolveConflicts: () -> Void
    let isCreatingPullRequests: Bool
    let isPullRequestMerged: Bool
    let hasPullRequestConflicts: Bool
    let pullRequestHealth: [Int: PullRequestHealth]
    let onMoveToDone: (() -> Void)?

    var body: some View {
        // Card rows, top to bottom: the title, the live updates, the time with
        // the live token counter, then the pull-request controls on the right
        // (absent until the task has started and has a repository).
        VStack(alignment: .leading, spacing: 10) {
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
                .allowsHitTesting(false)

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
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("task-progress-report-\(task.id.uuidString)")
                .accessibilityLabel([progressLabel, task.progressDetail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "))
                .accessibilityValue("Progress icon: \(TaskProgressType(rawValue: task.progressTypeRawValue ?? "")?.symbol ?? "sparkle")")
                .allowsHitTesting(false)
            }

            if let statusMessage = task.statusMessage, !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.system(size: 10))
                    .foregroundStyle(task.status == .blocked ? Color.red : Color.secondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("task-status-message-\(task.id.uuidString)")
                    .allowsHitTesting(false)
            }

            timeRow

            if showPullRequestControls {
                HStack(spacing: 8) {
                    Spacer(minLength: 8)
                    pullRequestControls
                }
                .frame(minHeight: 30)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            // The open button sits behind the content and owns the card chrome.
            // The content above it must not absorb clicks (no fill, no
            // contentShape, and non-interactive rows disable hit testing), so a
            // click anywhere on the card except the pull-request controls
            // reaches this button.
            Button(action: {
                DispatchQueue.main.async(execute: onOpen)
            }) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(WorkspaceTheme.windowBackground)
                    .shadow(color: .black.opacity(0.035), radius: 5, x: 0, y: 2)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .buttonHoverPointer()
            .buttonStyle(.plain)
            .nativeHelp("Open task: \(task.title)")
            .accessibilityLabel(task.title)
            .accessibilityHint("Open task")
            .accessibilityIdentifier("task-card-\(task.id.uuidString)")
        }
        .overlay(alignment: .leading) {
            if let fraction = cpuFraction {
                GeometryReader { proxy in
                    // The gradient is rendered at the track's full height so a
                    // given y-position always maps to the same color, then
                    // masked down to the filled portion — a copy of the
                    // gradient squeezed into just the fill height would remap
                    // the whole green...red range into that sliver and show
                    // red even at low usage.
                    CPUUsageHeatmap.gradient
                        .opacity(0.15)
                    CPUUsageHeatmap.gradient
                        .mask(alignment: .bottom) {
                            Rectangle().frame(height: proxy.size.height * fraction)
                        }
                }
                .frame(width: 4)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.vertical, 1)
                .animation(.easeInOut(duration: 1.2), value: fraction)
                .allowsHitTesting(false)
                .accessibilityIdentifier("task-cpu-usage-bar-\(task.id.uuidString)")
                .accessibilityLabel(CPUUsageHeatmap.label(percent: cpuPercent ?? 0))
            }
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
            Button("Token Stats…", systemImage: "chart.bar", action: onShowTokenStats)
            .buttonHoverPointer()
            .help("Token Stats")
                .accessibilityIdentifier("token-stats-task-menu-item")
            Button("Delete Task", systemImage: "trash", role: .destructive, action: onDelete)
            .buttonHoverPointer()
            .help("Delete Task")
                .accessibilityIdentifier("delete-task-menu-item")
        }
    }

    private var linkedPullRequests: [RepositoryWorktreeRecord] {
        task.repositoryWorktrees.filter { $0.pullRequestNumber != nil && $0.pullRequestURL != nil }
    }

    /// `nil` for a task with no running turn or no sample yet. For Codex
    /// it's the task's working-directory share of the shared app-server
    /// (see `TaskCPUUsageSnapshot`).
    private var cpuPercent: Double? {
        cpuUsageModel.percent(threadID: task.activeConversationID)
    }

    private var cpuFraction: Double? {
        cpuPercent.map { CPUUsageHeatmap.fraction(percent: $0, max: cpuUsageColorMax) }
    }

    private var hasRepositoriesMissingPullRequests: Bool {
        task.repositoryWorktrees.contains { !$0.isPending && ($0.pullRequestNumber == nil || $0.pullRequestURL == nil) }
    }

    private var showPullRequestControls: Bool {
        task.status != .backlog && !task.repositoryWorktrees.isEmpty
    }

    /// While the task is still being worked on (before it reaches Review), the
    /// Manual/PR/Green/Merge mode pill replaces the manual create button: once the task moves
    /// to Review, the PR and Auto modes create the pull request themselves.
    private var isAutoPRWorkingState: Bool {
        switch task.status {
        case .inProgress, .blocked, .waitingResponse: true
        case .backlog, .review, .done: false
        }
    }

    private var timeRow: some View {
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
            // A zero counter says nothing yet, so it stays hidden until the task has sent tokens.
            if task.counterTokens > 0 {
                tokenCounter
            }
        }
        .foregroundStyle(.tertiary)
        .allowsHitTesting(false)
    }

    /// Everything the task has sent to the model so far, subagents included.
    /// It climbs while a turn runs and keeps the heatmap colour, so the
    /// configured ceiling still reads as "this task is getting expensive".
    private var tokenCounter: some View {
        let tokens = task.counterTokens
        return Text(TokenUsageHeatmap.compact(tokens))
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(TokenUsageHeatmap.color(totalTokens: tokens, max: tokenUsageColorMax))
            .contentTransition(.numericText())
            .animation(.default, value: tokens)
            .nativeHelp(counterDescription)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(counterDescription)
            .accessibilityIdentifier("task-token-usage-counter-\(task.id.uuidString)")
    }

    private var counterDescription: String {
        guard task.hasCallUsage else { return TokenUsageHeatmap.label(totalTokens: task.totalTokens) }
        return "\(TokenUsageHeatmap.compact(task.totalSentTokens)) tokens sent · \(task.totalCalls) \(task.totalCalls == 1 ? "call" : "calls") · \(TokenUsageHeatmap.compact(task.finalTranscriptTokens)) final transcript"
    }

    @ViewBuilder
    private var pullRequestControls: some View {
        HStack(spacing: 5) {
            let linked = linkedPullRequests
            if linked.isEmpty && isAutoPRWorkingState {
                pullRequestModePill
            } else if linked.isEmpty {
                let hasMultipleRepositories = task.repositoryWorktrees.filter { !$0.isPending }.count > 1
                Button(action: onCreatePullRequests) {
                    if isCreatingPullRequests {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text(hasMultipleRepositories ? "PRs" : "PR").font(.system(size: 10, weight: .semibold))
                            .frame(minWidth: 30, minHeight: 30)
                    }
                }
                .actionButtonHoverEmphasis(padding: 10)
                .buttonHoverPointer()
                .nativeHelp("Create a pull request for each repository linked to this task")
                .disabled(isCreatingPullRequests)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
                .accessibilityLabel(hasMultipleRepositories ? "PRs. Create pull requests for each repository linked to this task" : "PR. Create a pull request for each repository linked to this task")
                .accessibilityIdentifier("task-create-pr-\(task.id.uuidString)")
            } else {
                if hasRepositoriesMissingPullRequests {
                    Button(action: onCreatePullRequests) {
                        if isCreatingPullRequests {
                            ProgressView().controlSize(.mini)
                        } else {
                            Text(task.repositoryWorktrees.filter { !$0.isPending }.count > 1 ? "PRs" : "PR")
                                .font(.system(size: 10, weight: .semibold))
                        }
                    }
                    .actionButtonHoverEmphasis(padding: 10)
                    .buttonHoverPointer()
                    .nativeHelp("Create pull requests for repositories without a linked pull request")
                    .disabled(isCreatingPullRequests)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
                    .accessibilityLabel(task.repositoryWorktrees.filter { !$0.isPending }.count > 1 ? "PRs. Create pull requests for repositories without a linked pull request" : "PR. Create a pull request for the repository without a linked pull request")
                    .accessibilityIdentifier("task-create-pr-\(task.id.uuidString)")
                }
                if isPullRequestMerged, let onMoveToDone {
                    Button(action: onMoveToDone) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.green)
                    }
                    .actionButtonHoverEmphasis(padding: 10)
                    .buttonHoverPointer()
                    .nativeHelp("Complete task: all linked pull requests have merged")
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
                    .accessibilityLabel("Green checkmark. Complete task, all linked pull requests merged")
                    .accessibilityIdentifier("task-complete-merged-pr-\(task.id.uuidString)")
                } else {
                    if hasPullRequestConflicts {
                        Button(action: onResolveConflicts) {
                            Image("ConflictIndicator")
                                .resizable()
                                .renderingMode(.template)
                                .scaledToFit()
                                .foregroundStyle(.orange)
                                .frame(width: 16, height: 16)
                                .accessibilityIdentifier("task-resolve-pr-conflicts-icon-\(task.id.uuidString)")
                        }
                        .actionButtonHoverEmphasis(padding: 10)
                        .buttonHoverPointer()
                        .nativeHelp("Resolve pull request conflicts with \(task.conversationProvider.displayName)")
                        .accessibilityLabel("Resolve pull request conflicts")
                        .accessibilityIdentifier("task-resolve-pr-conflicts-\(task.id.uuidString)")
                        .frame(minWidth: 30, minHeight: 30)
                        .contentShape(Rectangle())
                    }
                    pullRequestModePill
                    ForEach(linked, id: \.repositoryPath) { record in
                        if let number = record.pullRequestNumber, let url = URL(string: record.pullRequestURL ?? "") {
                            let health = pullRequestHealth[number]
                            Link(destination: url) {
                                Text(verbatim: "#\(number)")
                                    .foregroundStyle(health.map(Self.healthColor) ?? Color.accentColor)
                            }
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .actionButtonHoverEmphasis(padding: 5)
                                .buttonHoverPointer()
                                .nativeHelp(URL(fileURLWithPath: record.repositoryPath).lastPathComponent + (health.map { " · \(Self.healthDescription($0))" } ?? ""))
                                // The chip stays compact; the click target keeps the 30 pt minimum of its sibling actions.
                                .frame(minWidth: 30, minHeight: 30)
                                .contentShape(Rectangle())
                                .accessibilityValue(health?.rawValue ?? "unknown")
                                .accessibilityIdentifier("task-pr-link-\(task.id.uuidString)-\(number)")
                        }
                    }
                }
            }
        }
        .buttonStyle(.borderless)
    }

    static func healthColor(_ health: PullRequestHealth) -> Color {
        switch health {
        case .green: .green
        case .red: .red
        case .pending: .blue
        // GitHub's merged purple.
        case .merged: Color(red: 0.64, green: 0.44, blue: 0.97)
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

    /// Shown in place of the manual "PR" button while the task is being worked on,
    /// and beside linked PRs afterwards so autopilot and merge stay switchable.
    private var pullRequestModePill: some View {
        PullRequestModePill(taskID: task.id, mode: task.pullRequestMode, onSelect: onSetPullRequestMode)
    }

    private func workingDuration(at date: Date) -> String {
        let activeInterval = task.inProgressStartedAt.map { max(0, date.timeIntervalSince($0)) } ?? 0
        let activeText = Self.shortDuration(activeInterval)
        guard task.totalInProgressSeconds > 0 else { return activeText }
        return "\(activeText) (\(Self.shortDuration(task.totalInProgressSeconds + activeInterval)) total)"
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

/// Where the session files the token map reads live, as this window's bridge
/// requests would name them.
private extension ProviderSessionHomes {
    static var forThisApp: ProviderSessionHomes {
        let configuration = DaemonClient.Configuration.fromEnvironment()
        return .resolve(claudeConfigDirectory: configuration.claudeConfigDirectory, codexHome: configuration.codexHome)
    }
}

/// What the raw input sheet opens on: one agent's item, or the start of its transcript.
private struct RawInputFocus: Identifiable {
    let id = UUID()
    let agent: String?
    let item: Int?
    let inFinalTranscript: Bool
}

/// How each kind of context item is named on screen.
private func contextKindName(_ kind: String) -> String {
    switch ProviderContextKind(rawValue: kind) {
    case .systemPrompt: "System prompt"
    case .toolDefinition: "Tool definition"
    case .hiddenOverhead: "Hidden overhead"
    case .systemReminder: "Injected text"
    case .userText: "User"
    case .assistantText: "Assistant"
    case .thinking: "Thinking"
    case .toolCall: "Tool call"
    case .toolResult: "Tool result"
    case .image: "Image"
    case .other, nil: "Other"
    }
}

/// A bar whose length and heat follow an item's share of the largest one in view.
private struct TokenShareBar: View {
    let tokens: Int
    let maxTokens: Int

    var body: some View {
        let fraction = maxTokens > 0 ? min(1, Double(tokens) / Double(maxTokens)) : 0
        ZStack(alignment: .leading) {
            Capsule().fill(Color.primary.opacity(0.07))
            Capsule()
                .fill(TokenUsageHeatmap.color(totalTokens: tokens, max: max(1, maxTokens)))
                .frame(width: max(2, 72 * fraction))
        }
        .frame(width: 72, height: 6)
        .accessibilityHidden(true)
    }
}

/// A row of mutually exclusive choices, each its own button so it can be found by identifier.
private struct ChoiceBar<Choice: Hashable>: View {
    let choices: [(value: Choice, title: String, id: String)]
    @Binding var selection: Choice

    var body: some View {
        HStack(spacing: 2) {
            ForEach(choices, id: \.id) { choice in
                Button {
                    selection = choice.value
                } label: {
                    Text(choice.title)
                        .font(.system(size: 11, weight: selection == choice.value ? .semibold : .regular))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 5).fill(selection == choice.value ? Color.accentColor.opacity(0.2) : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .buttonHoverPointer()
                .nativeHelp(choice.title)
                .accessibilityIdentifier(choice.id)
                .accessibilityAddTraits(selection == choice.value ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
    }
}

/// A task's token accounting: the totals, the per-turn detail, and what each
/// tool took part in, plus a map of what filled the context, read from the
/// providers' own session files.
private struct TokenStatsSheet: View {
    private enum Section: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case wasters = "Wasters"
        case tools = "Tools & MCP"
        case overhead = "Overhead"
        var id: String { String(describing: self) }
    }

    @Environment(\.dismiss) private var dismiss
    let taskID: UUID
    let taskTitle: String
    let modelContext: ModelContext
    @State private var summary: TaskTokenUsageSummary?
    @State private var waste: TaskTokenWasteReport?
    @State private var didLoad = false
    @State private var section = Section.overview
    @State private var rawInputFocus: RawInputFocus?

    private static let number = IntegerFormatStyle<Int>().grouping(.automatic)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Token stats")
                        .font(.system(size: 19, weight: .semibold, design: .rounded))
                    Text(taskTitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button("View raw input…", systemImage: "doc.text.magnifyingglass") {
                    rawInputFocus = RawInputFocus(agent: nil, item: nil, inFinalTranscript: true)
                }
                .buttonHoverPointer()
                .nativeHelp("Open the full input the model was sent, item by item")
                .disabled(waste?.available != true)
                .accessibilityIdentifier("token-stats-raw-input-button")
            }
            ChoiceBar(
                choices: Section.allCases.map { ($0, $0.rawValue, "token-stats-section-\($0.id)") },
                selection: $section
            )
            switch section {
            case .overview: overview
            case .wasters: map { wasters($0) }
            case .tools: map { measuredTools($0) }
            case .overhead: map { overhead($0) }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonHoverPointer()
                    .nativeHelp("Done")
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("close-token-stats-button")
            }
        }
        .padding(24)
        .frame(width: 720)
        // Keeps reading while the sheet is open, so a running turn's calls
        // show up live. The map extends its parsed logs from where they
        // stopped, so a poll only reads what the session files gained.
        .task {
            while !Task.isCancelled {
                let manager = BoardTaskManager(modelContext: modelContext)
                summary = try? manager.tokenUsageSummary(taskID)
                waste = try? await manager.tokenWasteReport(taskID, homes: .forThisApp)
                didLoad = true
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .sheet(item: $rawInputFocus) { focus in
            RawInputSheet(taskID: taskID, taskTitle: taskTitle, modelContext: modelContext, focus: focus)
        }
    }

    @ViewBuilder
    private var overview: some View {
        if let summary, summary.totalTokens > 0 || summary.callUsage.available {
            totals(summary)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    tools(summary)
                    turns(summary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 320)
        } else if didLoad {
            Text("No tokens recorded for this task yet.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("token-stats-empty")
        }
    }

    /// A map section, or why there is no map: the providers only log their
    /// requests once a conversation has run with a version that writes them.
    @ViewBuilder
    private func map<Content: View>(@ViewBuilder _ content: @escaping (TaskTokenWasteReport) -> Content) -> some View {
        if let waste, waste.available {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) { content(waste) }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 420)
        } else if didLoad {
            Text("No request log for this task yet. Claude Code and Codex write one to their session files as the conversation runs.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("token-stats-map-unavailable")
        }
    }

    private func sectionHeader(_ title: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            Text(caption)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    private func tokens(_ value: Int, id: String) -> some View {
        Text(value.formatted(Self.number))
            .font(.system(size: 11, weight: .medium))
            .monospacedDigit()
            .accessibilityIdentifier(id)
    }

    private func detail(_ text: String, id: String? = nil) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .accessibilityIdentifier(id ?? "")
    }

    private func agentLabel(_ id: String, in report: TaskTokenWasteReport) -> String {
        report.agents.first { $0.id == id }?.label ?? id
    }

    @ViewBuilder
    private func wasters(_ report: TaskTokenWasteReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader(
                "Largest items",
                "Ranked by the tokens each item added. ×N is how many requests carried it; show one to read its full text."
            )
            let largest = report.wasters.first?.tokens ?? 0
            ForEach(Array(report.wasters.enumerated()), id: \.element.id) { index, item in
                HStack(alignment: .center, spacing: 8) {
                    TokenShareBar(tokens: item.tokens, maxTokens: largest)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(item.label)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                                .accessibilityIdentifier("token-stats-waster-\(index)-label")
                            Text(contextKindName(item.kind))
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                            if !item.inFinalTranscript {
                                Text("removed by compaction")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.orange)
                                    .accessibilityIdentifier("token-stats-waster-\(index)-removed")
                            }
                        }
                        detail(item.preview)
                    }
                    Spacer(minLength: 8)
                    detail("×\(item.requests)", id: "token-stats-waster-\(index)-requests")
                    tokens(item.tokens, id: "token-stats-waster-\(index)-tokens")
                    Button("Show") {
                        rawInputFocus = RawInputFocus(agent: item.agent, item: item.item, inFinalTranscript: item.inFinalTranscript)
                    }
                    .buttonHoverPointer()
                    .nativeHelp("Show the full text the model received")
                    .controlSize(.small)
                    .accessibilityIdentifier("token-stats-waster-\(index)-show")
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("token-stats-waster-\(index)")
            }
        }
        if !report.duplicates.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                sectionHeader("Repeated results", "Tool results whose text was sent more than once in the same agent.")
                ForEach(Array(report.duplicates.enumerated()), id: \.element.id) { index, duplicate in
                    HStack(spacing: 8) {
                        Text(duplicate.label)
                            .font(.system(size: 11))
                            .lineLimit(1)
                        detail("\(duplicate.copies) copies of \(duplicate.tokensPerCopy.formatted(Self.number))", id: "token-stats-duplicate-\(index)-copies")
                        Spacer(minLength: 8)
                        tokens(duplicate.wastedTokens, id: "token-stats-duplicate-\(index)-wasted")
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("token-stats-duplicate-\(index)")
                }
            }
        }
        if !report.cacheMisses.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                sectionHeader("Cache misses", "Requests that re-sent most of the previous request's context without the prompt cache, paying for it again.")
                ForEach(Array(report.cacheMisses.enumerated()), id: \.element.id) { index, miss in
                    HStack(spacing: 8) {
                        Text("Request \(miss.request)")
                            .font(.system(size: 11))
                            .accessibilityIdentifier("token-stats-cache-miss-\(index)-request")
                        detail("\(agentLabel(miss.agent, in: report)) · \(miss.contextTokens.formatted(Self.number)) in context")
                        Spacer(minLength: 8)
                        tokens(miss.rewrittenTokens, id: "token-stats-cache-miss-\(index)-rewritten")
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("token-stats-cache-miss-\(index)")
                }
            }
        }
    }

    @ViewBuilder
    private func measuredTools(_ report: TaskTokenWasteReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Tools", "Tokens each tool's calls and results added to the context, across every agent.")
            let largest = report.tools.first?.totalTokens ?? 0
            ForEach(report.tools) { tool in
                HStack(spacing: 8) {
                    TokenShareBar(tokens: tool.totalTokens, maxTokens: largest)
                    Text(tool.id)
                        .font(.system(size: 11))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    detail("\(tool.calls) \(tool.calls == 1 ? "call" : "calls") · largest \(tool.largestResultTokens.formatted(Self.number)) · average \(tool.averageResultTokens.formatted(Self.number))",
                           id: "token-stats-measured-tool-\(tool.id)-calls")
                    tokens(tool.totalTokens, id: "token-stats-measured-tool-\(tool.id)-total")
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("token-stats-measured-tool-\(tool.id)")
            }
        }
        if !report.servers.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                sectionHeader("MCP servers", "What each server's calls added, and what its tool definitions cost on every request.")
                ForEach(report.servers) { server in
                    HStack(spacing: 8) {
                        Text(server.id)
                            .font(.system(size: 11))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        detail("\(server.tools) tools · \(server.calls) calls · definitions \(server.definitionTokens.formatted(Self.number))",
                               id: "token-stats-server-\(server.id)-detail")
                        tokens(server.totalTokens, id: "token-stats-server-\(server.id)-total")
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("token-stats-server-\(server.id)")
                }
            }
        }
    }

    @ViewBuilder
    private func overhead(_ report: TaskTokenWasteReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Sent with every request", "The system prompt and tool definitions each main agent carries, whatever the conversation does.")
            let largest = report.overhead.first?.tokens ?? 0
            ForEach(Array(report.overhead.enumerated()), id: \.element.id) { index, entry in
                HStack(spacing: 8) {
                    TokenShareBar(tokens: entry.tokens, maxTokens: largest)
                    Text(entry.label)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .accessibilityIdentifier("token-stats-overhead-\(index)-label")
                    Spacer(minLength: 8)
                    detail(entry.everyRequest ? "× every request" : "×\(entry.requests)", id: "token-stats-overhead-\(index)-requests")
                    tokens(entry.tokens, id: "token-stats-overhead-\(index)-tokens")
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("token-stats-overhead-\(index)")
            }
        }
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Agents", "Each agent's own requests, everything they sent, and the size of its final transcript.")
            ForEach(report.agents) { agent in
                HStack(spacing: 8) {
                    Text(agent.label)
                        .font(.system(size: 11))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    detail("\(agent.requests) requests · final \(agent.finalTranscriptTokens.formatted(Self.number))\(agent.compactions > 0 ? " · \(agent.compactions) compacted" : "")",
                           id: "token-stats-agent-\(agent.id)-detail")
                    tokens(agent.sentTokens, id: "token-stats-agent-\(agent.id)-sent")
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("token-stats-agent-\(agent.id)")
            }
        }
    }

    private func totals(_ summary: TaskTokenUsageSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            callTotals(summary.callUsage)
            Text(summary.totalTokens.formatted(Self.number))
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .accessibilityIdentifier("token-stats-total")
            let turnsTotal = summary.turns.reduce(0) { $0 + $1.totalTokens }
            Text("tokens across \(summary.turnCount) \(summary.turnCount == 1 ? "turn" : "turns")")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if turnsTotal != summary.totalTokens {
                // A private recovery turn contributes to the total with no
                // visible row, so the two numbers can legitimately differ;
                // say so rather than let it read as a miscount.
                Text("Includes tokens from private turns not shown below.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .accessibilityIdentifier("token-stats-hidden-turns-note")
            }
            HStack(spacing: 18) {
                bucket("Input", summary.usage.inputTokens)
                bucket("Output", summary.usage.outputTokens)
                bucket("Cache read", summary.usage.cacheReadTokens)
                bucket("Cache write", summary.usage.cacheCreationTokens)
            }
        }
    }

    /// The two numbers a task is judged by: how large its transcript grew, and
    /// how much it re-sent over all of its model calls, subagents included.
    @ViewBuilder
    private func callTotals(_ usage: TaskTokenUsageSummary.CallUsage) -> some View {
        if usage.available {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 28) {
                    headline("Final transcript size", usage.finalTranscriptTokens, id: "token-stats-final-transcript")
                    headline("Total sent (incl. subagents)", usage.totalSentTokens, id: "token-stats-total-sent")
                }
                let subagents = usage.subagents
                Text("\(usage.totalCalls) model \(usage.totalCalls == 1 ? "call" : "calls") · \(usage.mainAgent.calls) main, \(subagents.calls) across \(subagents.count) \(subagents.count == 1 ? "subagent" : "subagents")")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("token-stats-total-calls")
                Text("Output \(usage.totalOutputTokens.formatted(Self.number))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("token-stats-output")
                Divider()
                Text("Main agent turns")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        } else {
            Text("Call-level stats are not recorded for this task yet.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .accessibilityIdentifier("token-stats-calls-unavailable")
        }
    }

    private func headline(_ name: String, _ value: Int, id: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Text(value.formatted(Self.number))
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .accessibilityIdentifier(id)
        }
    }

    private func bucket(_ name: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Text(value.formatted(Self.number))
                .font(.system(size: 13, weight: .medium))
        }
    }

    @ViewBuilder
    private func tools(_ summary: TaskTokenUsageSummary) -> some View {
        if !summary.tools.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("By tool, skill and MCP")
                    .font(.system(size: 12, weight: .semibold))
                // Providers report usage once per turn, so a turn's cost counts
                // toward every tool that ran in it. Say so rather than implying
                // these totals add up to the task total.
                Text("Cost of the turns each ran in; turns with several tools count toward each.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                ForEach(summary.tools) { tool in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(tool.id)
                            .font(.system(size: 11))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text("\(tool.turnCount) \(tool.turnCount == 1 ? "turn" : "turns")")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Text(tool.totalTokens.formatted(Self.number))
                            .font(.system(size: 11, weight: .medium))
                            .monospacedDigit()
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("token-stats-tool-\(tool.id)")
                }
            }
        }
    }

    private func turns(_ summary: TaskTokenUsageSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("By turn")
                .font(.system(size: 12, weight: .semibold))
            ForEach(summary.turns) { turn in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(turn.recordedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 11))
                        Text(turn.provider.displayName)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Spacer(minLength: 8)
                        Text(turn.totalTokens.formatted(Self.number))
                            .font(.system(size: 11, weight: .medium))
                            .monospacedDigit()
                    }
                    if !turn.tools.isEmpty {
                        Text(turn.tools.joined(separator: " · "))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("token-stats-turn-\(turn.id)")
            }
        }
    }
}

private extension TaskRawInputPage.Row {
    /// A single request can list one item twice, so its rows are keyed by position.
    var listKey: Int { position ?? id }
    var accessibilityID: String { position.map { "raw-input-request-row-\($0)" } ?? "raw-input-row-\(id)" }
}

/// The input a task's model requests were sent, one row per item: the final
/// transcript or everything ever sent (including what a compaction removed)
/// list each item once, and a single request lists everything it sent in
/// order, repeats included and flagged. Rows load a page at a time as the list scrolls.
private struct RawInputSheet: View {
    @Environment(\.dismiss) private var dismiss
    let taskID: UUID
    let taskTitle: String
    let modelContext: ModelContext
    let focus: RawInputFocus
    @State private var agent: String?
    @State private var scope: TaskRawInputScope
    @State private var order = TaskRawInputOrder.transcript
    @State private var query = ""
    @State private var submittedQuery = ""
    @State private var page: TaskRawInputPage?
    @State private var rows: [TaskRawInputPage.Row] = []
    @State private var isLoading = false
    @State private var selected: Int?
    /// In a single request, which copy of the selected item is highlighted.
    @State private var selectedPosition: Int?
    @State private var scrollTarget: Int?
    /// `nil` is the request the final transcript was read from.
    @State private var requestNumber: Int?
    @State private var requestField = ""
    @State private var exportFormat = TaskRawInputExportFormat.text
    @State private var exportStatus: String?

    private static let pageSize = 100
    private static let number = IntegerFormatStyle<Int>().grouping(.automatic)

    /// Wide enough for the list beside the text, but never wider or taller than the screen.
    private static var size: CGSize {
        let visible = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1200, height: 800)
        return CGSize(width: min(1120, max(800, visible.width - 60)), height: min(720, max(480, visible.height - 80)))
    }

    init(taskID: UUID, taskTitle: String, modelContext: ModelContext, focus: RawInputFocus) {
        self.taskID = taskID
        self.taskTitle = taskTitle
        self.modelContext = modelContext
        self.focus = focus
        _agent = State(initialValue: focus.agent)
        _scope = State(initialValue: focus.inFinalTranscript ? .finalTranscript : .everything)
        _selected = State(initialValue: focus.item)
    }

    private var hasMore: Bool { rows.count < (page?.total ?? 0) }
    private var reloadKey: String {
        "\(agent ?? "")|\(scope.rawValue)|\(order.rawValue)|\(submittedQuery)|\(scope == .request ? requestNumber ?? 0 : 0)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Raw input")
                        .font(.system(size: 19, weight: .semibold, design: .rounded))
                    Text(taskTitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if let page {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(page.total) \(page.total == 1 ? "item" : "items") · \(page.totalTokens.formatted(Self.number)) tokens")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("raw-input-summary")
                        Text("\(rows.count) of \(page.total) loaded")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .accessibilityIdentifier("raw-input-loaded-rows")
                    }
                }
            }
            controls
            if scope == .request, let request = page?.request {
                requestBar(request)
            }
            HStack(alignment: .top, spacing: 0) {
                list
                    .frame(width: min(460, Self.size.width * 0.42))
                Divider()
                Group {
                    if let selected {
                        RawInputTextPane(taskID: taskID, modelContext: modelContext, agent: page?.agent ?? agent, item: selected)
                            .id("\(page?.agent ?? agent ?? "")#\(selected)")
                    } else {
                        Text("Select an item to read the full text the model received.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .accessibilityIdentifier("raw-input-no-selection")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonHoverPointer()
                    .nativeHelp("Done")
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("close-raw-input-button")
            }
        }
        .padding(20)
        .frame(width: Self.size.width, height: Self.size.height)
        .task(id: reloadKey) { await reload() }
        // Item IDs belong to one agent's log; another agent's item with the same ID is unrelated.
        .onChange(of: agent) {
            selected = nil
            selectedPosition = nil
            requestNumber = nil
        }
        .onChange(of: requestNumber) {
            selected = nil
            selectedPosition = nil
            exportStatus = nil
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            if let page, page.agents.count > 1 {
                Picker("Agent", selection: Binding(get: { agent ?? page.agent ?? "" }, set: { agent = $0 })) {
                    ForEach(page.agents) { Text($0.label).tag($0.id) }
                }
                .frame(width: 240)
                .accessibilityIdentifier("raw-input-agent-picker")
            }
            ChoiceBar(
                choices: [
                    (TaskRawInputScope.finalTranscript, "Final transcript", "raw-input-scope-final"),
                    (TaskRawInputScope.everything, "Everything sent", "raw-input-scope-all"),
                    (TaskRawInputScope.request, "Single request", "raw-input-scope-request"),
                ],
                selection: $scope
            )
            Picker("Order", selection: $order) {
                Text("Transcript order").tag(TaskRawInputOrder.transcript)
                Text("Largest first").tag(TaskRawInputOrder.size)
                Text("Most tokens carried").tag(TaskRawInputOrder.rent)
            }
            .frame(width: 220)
            .accessibilityIdentifier("raw-input-order-picker")
            TextField("Search the full text", text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submittedQuery = query }
                .accessibilityIdentifier("raw-input-search-field")
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(rows, id: \.listKey) { row in
                        RawInputRowView(
                            row: row, maxTokens: page?.maxTokens ?? 0,
                            isSelected: row.position.map { $0 == selectedPosition } ?? (row.id == selected)
                        )
                        .id(row.listKey)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selected = row.id
                            selectedPosition = row.position
                        }
                        .onAppear {
                            if row.listKey == rows.last?.listKey { Task { await loadMore() } }
                        }
                    }
                    if hasMore {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                            .padding(8)
                            .accessibilityIdentifier("raw-input-loading-more")
                    } else if page != nil, rows.isEmpty {
                        Text(submittedQuery.isEmpty ? "Nothing was sent yet." : "No item contains “\(submittedQuery)”.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(12)
                            .accessibilityIdentifier("raw-input-empty")
                    }
                }
                .padding(.trailing, 8)
            }
            .accessibilityIdentifier("raw-input-list")
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                proxy.scrollTo(target, anchor: .center)
                scrollTarget = nil
            }
        }
    }

    private func fetch(offset: Int, focusing item: Int?) async -> TaskRawInputPage? {
        try? await BoardTaskManager(modelContext: modelContext).rawInputPage(
            taskID, homes: .forThisApp, agent: agent, scope: scope, order: order, query: submittedQuery,
            offset: offset, limit: Self.pageSize, focus: item, request: scope == .request ? requestNumber : nil
        )
    }

    /// Which request is shown, how the provider measured it, how exact the
    /// rebuild is, and the whole request's export.
    private func requestBar(_ request: TaskRawInputPage.Request) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button("Previous request", systemImage: "chevron.left") { requestNumber = request.number - 1 }
                    .labelStyle(.iconOnly)
                    .buttonHoverPointer()
                    .nativeHelp("Show the request before this one")
                    .disabled(request.number <= 1)
                    .accessibilityIdentifier("raw-input-request-previous")
                Text("Request \(request.number) of \(request.count)")
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .accessibilityIdentifier("raw-input-request-number")
                Button("Next request", systemImage: "chevron.right") { requestNumber = request.number + 1 }
                    .labelStyle(.iconOnly)
                    .buttonHoverPointer()
                    .nativeHelp("Show the request after this one")
                    .disabled(request.number >= request.count)
                    .accessibilityIdentifier("raw-input-request-next")
                TextField("Go to #", text: $requestField)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                    .onSubmit {
                        if let number = Int(requestField.trimmingCharacters(in: .whitespaces)) {
                            requestNumber = min(max(1, number), request.count)
                        }
                        requestField = ""
                    }
                    .accessibilityIdentifier("raw-input-request-field")
                Button("Latest") { requestNumber = nil }
                    .buttonHoverPointer()
                    .nativeHelp("Show the request the final transcript was read from")
                    .controlSize(.small)
                    .disabled(request.number == request.latest)
                    .accessibilityIdentifier("raw-input-request-latest")
                Text(request.exact ? "Exact" : "Reconstructed")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(request.exact ? Color.green : Color.orange)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill((request.exact ? Color.green : Color.orange).opacity(0.15)))
                    .nativeHelp(request.note)
                    .accessibilityIdentifier("raw-input-request-exactness")
                if let timestamp = request.timestamp {
                    Text(Self.displayTime(timestamp))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .accessibilityIdentifier("raw-input-request-time")
                }
                Spacer(minLength: 8)
                ChoiceBar(
                    choices: [
                        (TaskRawInputExportFormat.text, "Text", "raw-input-export-format-text"),
                        (TaskRawInputExportFormat.json, "JSON", "raw-input-export-format-json"),
                    ],
                    selection: $exportFormat
                )
                Button("Copy all", systemImage: "doc.on.doc") { Task { await exportRequest(request, open: false) } }
                    .buttonHoverPointer()
                    .nativeHelp("Copy this whole request, every item in order")
                    .controlSize(.small)
                    .accessibilityIdentifier("raw-input-request-copy-button")
                Button("Open in editor", systemImage: "square.and.pencil") { Task { await exportRequest(request, open: true) } }
                    .buttonHoverPointer()
                    .nativeHelp("Write this whole request to a file and open it")
                    .controlSize(.small)
                    .accessibilityIdentifier("raw-input-request-open-editor-button")
            }
            // The bar keeps one height whatever it shows: a bar that grows
            // resizes the lazy list below it while it lays out its rows.
            HStack(spacing: 8) {
                Text(Self.usageLine(request))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .layoutPriority(1)
                    .accessibilityIdentifier("raw-input-request-usage")
                Spacer(minLength: 8)
                Text(exportStatus ?? "")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityIdentifier("raw-input-request-export-status")
            }
            Text("\(request.note) \(request.tokenNote)")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(2, reservesSpace: true)
                .nativeHelp("\(request.note) \(request.tokenNote)")
                .accessibilityIdentifier("raw-input-request-note")
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.04)))
    }

    private static func usageLine(_ request: TaskRawInputPage.Request) -> String {
        var parts: [String] = []
        if let context = request.contextTokens {
            var reported = "Reported input \(context.formatted(number))"
            var split = ["uncached \((request.inputTokens ?? 0).formatted(number))", "cache read \((request.cacheReadTokens ?? 0).formatted(number))"]
            if let write = request.cacheWriteTokens { split.append("cache write \(write.formatted(number))") }
            reported += " (\(split.joined(separator: " · ")))"
            parts.append(reported)
        } else {
            parts.append("No usage reported")
        }
        parts.append("items add up to \(request.itemTokens.formatted(number))")
        parts.append("\(request.repeatedItems) repeated")
        if let source = request.querySource, !source.isEmpty { parts.append("source \(source)") }
        return parts.joined(separator: " · ")
    }

    private static func displayTime(_ timestamp: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: timestamp) ?? ISO8601DateFormatter().date(from: timestamp)
        return date?.formatted(date: .abbreviated, time: .standard) ?? timestamp
    }

    private func exportRequest(_ request: TaskRawInputPage.Request, open: Bool) async {
        let format = exportFormat
        do {
            let export = try await BoardTaskManager(modelContext: modelContext).rawInputExport(
                taskID, homes: .forThisApp, agent: page?.agent ?? agent, request: request.number, format: format
            )
            let name = format == .json ? "JSON" : "text"
            if open {
                let file = FileManager.default.temporaryDirectory
                    .appendingPathComponent("playhouse-request-\(taskID.uuidString.prefix(8))-\(export.agent.replacingOccurrences(of: "/", with: "-"))-\(export.request).\(format == .json ? "json" : "txt")")
                try export.text.write(to: file, atomically: true, encoding: .utf8)
                NSWorkspace.shared.open(file)
                exportStatus = "Opened request \(export.request) as \(name): \(export.items) items"
            } else {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(export.text, forType: .string)
                exportStatus = "Copied request \(export.request) as \(name): \(export.items) items"
            }
        } catch {
            exportStatus = error.localizedDescription
        }
    }

    /// Loads the first page, then on up to the selected item so the list can scroll to it.
    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        guard let first = await fetch(offset: 0, focusing: selected) else { return }
        page = first
        rows = first.rows
        if let position = first.focusPosition {
            while rows.count <= position, let next = await fetch(offset: rows.count, focusing: nil), !next.rows.isEmpty {
                rows += next.rows
            }
            guard rows.indices.contains(position) else { return }
            if selectedPosition == nil || scope != .request { selectedPosition = rows[position].position }
            scrollTarget = rows[position].listKey
        }
    }

    private func loadMore() async {
        guard hasMore, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        guard let next = await fetch(offset: rows.count, focusing: nil) else { return }
        page = next
        rows += next.rows
    }
}

private struct RawInputRowView: View {
    let row: TaskRawInputPage.Row
    let maxTokens: Int
    let isSelected: Bool

    private static let number = IntegerFormatStyle<Int>().grouping(.automatic)

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(contextKindName(row.kind))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                if let position = row.position {
                    Text("#\(position + 1)")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                Text(row.label)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .accessibilityIdentifier("\(row.accessibilityID)-label")
                if !row.inFinalTranscript {
                    Text("removed")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                }
                Spacer(minLength: 6)
                Text("×\(row.requests)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Text(row.tokens.formatted(Self.number))
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .accessibilityIdentifier("\(row.accessibilityID)-tokens")
            }
            HStack(spacing: 6) {
                TokenShareBar(tokens: row.tokens, maxTokens: maxTokens)
                Text(row.preview)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            // Every row of a single request keeps this line, flagged or not: rows
            // of one height keep the lazy list's placement from oscillating.
            if row.position != nil {
                if let repeated = row.repeated {
                    Text("Duplicate \(repeated.copy) of \(repeated.copies)\(repeated.copy > 1 ? " · first at #\(repeated.first + 1)" : "")")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.red)
                        .lineLimit(1)
                        .accessibilityIdentifier("\(row.accessibilityID)-repeat")
                } else {
                    Text(" ")
                        .font(.system(size: 9, weight: .semibold))
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(background))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(row.accessibilityID)
    }

    private var background: Color {
        if isSelected { return Color.accentColor.opacity(0.18) }
        return row.repeated == nil ? .clear : Color.red.opacity(0.08)
    }
}

/// One item's full text, line-numbered, read from the session file a chunk at
/// a time as it scrolls; a chunk always ends on a line break.
private struct RawInputTextPane: View {
    private struct Line: Identifiable {
        let id: Int
        let number: Int?
        let text: String
    }

    let taskID: UUID
    let modelContext: ModelContext
    let agent: String?
    let item: Int
    @State private var header: TaskRawInputText?
    @State private var lines: [Line] = []
    @State private var nextOffset: Int? = 0
    @State private var nextNumber = 1
    /// A chunk with no line break in its second half ends mid-line; the next one continues that line.
    @State private var continuesLine = false
    @State private var loadedLength = 0
    @State private var isLoading = false
    @State private var failure: String?

    private static let number = IntegerFormatStyle<Int>().grouping(.automatic)
    /// A very long line (minified JSON, a base64 blob) wraps across rows of this many characters.
    private static let segmentLength = 2_000

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let header {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(header.label)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .accessibilityIdentifier("raw-input-text-label")
                    Text(contextKindName(header.kind))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("Copy all", systemImage: "doc.on.doc") { Task { await copyAll() } }
                        .buttonHoverPointer()
                        .nativeHelp("Copy this item's full text")
                        .controlSize(.small)
                        .accessibilityIdentifier("raw-input-copy-button")
                    Button("Open in editor", systemImage: "square.and.pencil") { Task { await openInEditor() } }
                        .buttonHoverPointer()
                        .nativeHelp("Write this item's full text to a file and open it")
                        .controlSize(.small)
                        .accessibilityIdentifier("raw-input-open-editor-button")
                }
                Text("\(header.tokens.formatted(Self.number)) tokens · carried in \(header.requests) \(header.requests == 1 ? "request" : "requests") · \(header.totalLength.formatted(Self.number)) characters")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("raw-input-text-size")
                Text("\(loadedLength.formatted(Self.number)) of \(header.totalLength.formatted(Self.number)) characters loaded")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .accessibilityIdentifier("raw-input-text-loaded")
                if let call = header.call {
                    Text("Called as \(call)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("raw-input-text-call")
                }
                Divider()
            } else if let failure {
                Text(failure)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("raw-input-text-failure")
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in
                        HStack(alignment: .top, spacing: 10) {
                            Text(line.number.map(String.init) ?? "")
                                .foregroundStyle(.tertiary)
                                .frame(width: 52, alignment: .trailing)
                            Text(line.text.isEmpty ? " " : line.text)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier(line.number.map { "raw-input-text-line-\($0)" } ?? "")
                        .onAppear {
                            if line.id == lines.last?.id { Task { await loadNextChunk() } }
                        }
                    }
                }
                .padding(.trailing, 8)
            }
            .accessibilityIdentifier("raw-input-text")
        }
        .padding(.leading, 12)
        .task { await loadNextChunk() }
    }

    private func loadNextChunk() async {
        guard let offset = nextOffset, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let chunk = try await BoardTaskManager(modelContext: modelContext).rawInputText(
                taskID, homes: .forThisApp, agent: agent, item: item, offset: offset, length: ProviderTokenMap.defaultTextChunk
            )
            header = chunk
            append(chunk.text, isLast: chunk.nextOffset == nil)
            nextOffset = chunk.nextOffset
            loadedLength = chunk.nextOffset ?? chunk.totalLength
        } catch {
            failure = error.localizedDescription
            nextOffset = nil
        }
    }

    private func append(_ text: String, isLast: Bool) {
        var parts = text.components(separatedBy: "\n")
        let endsOnLineBreak = parts.last == ""
        // A chunk that ends on a line break leaves one empty part after it.
        if !isLast, endsOnLineBreak { parts.removeLast() }
        var added: [Line] = []
        for (index, part) in parts.enumerated() {
            var rest = Substring(part)
            let continuing = index == 0 && continuesLine
            var number: Int? = continuing ? nil : nextNumber
            repeat {
                added.append(Line(id: lines.count + added.count, number: number, text: String(rest.prefix(Self.segmentLength))))
                rest = rest.dropFirst(Self.segmentLength)
                number = nil
            } while !rest.isEmpty
            if !continuing { nextNumber += 1 }
        }
        continuesLine = !isLast && !endsOnLineBreak
        lines += added
    }

    private func fullText() async -> String? {
        try? await BoardTaskManager(modelContext: modelContext).rawInputText(
            taskID, homes: .forThisApp, agent: agent, item: item, offset: 0, length: Int.max
        ).text
    }

    private func copyAll() async {
        guard let text = await fullText() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func openInEditor() async {
        guard let text = await fullText() else { return }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("playhouse-raw-input-\(item).txt")
        guard (try? text.write(to: file, atomically: true, encoding: .utf8)) != nil else { return }
        NSWorkspace.shared.open(file)
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
                .nativeHelp("Cancel")
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(normalizedTitle)
                    dismiss()
                }
                .buttonHoverPointer()
                .nativeHelp("Save")
                .buttonStyle(.borderedProminent)
                .disabled(normalizedTitle.isEmpty)
                .accessibilityIdentifier("save-task-rename-button")
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}

/// A compact pill showing the task's PR mode. Clicking it slides the other modes
/// out beside it; choosing one (or the current one again) selects it and folds the
/// pill back. macOS has no native control for this, so it's drawn to fit the card.
private struct PullRequestModePill: View {
    let taskID: UUID
    let mode: PullRequestMode
    let onSelect: (PullRequestMode) -> Void
    @State private var isExpanded = false
    /// The mode just chosen, shown until the stored mode catches up with it.
    @State private var chosenMode: PullRequestMode?
    @Namespace private var selection

    private var shownMode: PullRequestMode { chosenMode ?? mode }

    var body: some View {
        HStack(spacing: 0) {
            if isExpanded {
                ForEach(Array(PullRequestMode.allCases.enumerated()), id: \.element) { index, option in
                    if index > 0 {
                        Rectangle()
                            .fill(Color.primary.opacity(0.18))
                            .frame(width: 1, height: 9)
                            .opacity(option == shownMode || PullRequestMode.allCases[index - 1] == shownMode ? 0 : 1)
                    }
                    optionButton(option)
                        .transition(.asymmetric(
                            insertion: .move(edge: .leading).combined(with: .opacity),
                            removal: .opacity
                        ))
                }
            } else {
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { isExpanded = true }
                } label: {
                    HStack(spacing: 3) {
                        Text(shownMode.label)
                            .font(.system(size: 9, weight: .semibold))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 7)
                    .frame(height: 17)
                    .background(Capsule().fill(Color.primary.opacity(0.14)).matchedGeometryEffect(id: "selected", in: selection))
                    .frame(minHeight: 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .buttonHoverPointer()
                .nativeHelp("How Playhouse handles this task's pull request. \(shownMode.helpText). Click to choose another mode.")
                .accessibilityLabel("Pull request mode")
                .accessibilityValue(shownMode.rawValue)
                .accessibilityIdentifier("task-pr-mode-\(taskID.uuidString)")
            }
        }
        .padding(.horizontal, 1)
        .background(Capsule().fill(Color.primary.opacity(0.07)).frame(height: 19))
        .clipShape(Capsule().inset(by: -6))
        .fixedSize()
        .accessibilityElement(children: .contain)
        .onChange(of: mode) { _, stored in
            if stored == chosenMode { chosenMode = nil }
        }
        // A choice the daemon rejected must not stick on the pill.
        .task(id: chosenMode) {
            guard chosenMode != nil else { return }
            try? await Task.sleep(for: .seconds(5))
            chosenMode = nil
        }
    }

    private func optionButton(_ option: PullRequestMode) -> some View {
        let isSelected = option == shownMode
        return Button {
            if !isSelected {
                chosenMode = option
                onSelect(option)
            }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { isExpanded = false }
        } label: {
            Text(option.label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .padding(.horizontal, 7)
                .frame(height: 17)
                .background {
                    if isSelected {
                        Capsule().fill(Color.primary.opacity(0.14)).matchedGeometryEffect(id: "selected", in: selection)
                    }
                }
                .frame(minHeight: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .buttonHoverPointer()
        .nativeHelp(option.helpText)
        .accessibilityLabel(option.label)
        .accessibilityValue(isSelected ? "selected" : "")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("task-pr-mode-\(option.rawValue)-\(taskID.uuidString)")
    }
}
