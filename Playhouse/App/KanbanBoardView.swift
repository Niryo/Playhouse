import AppKit
import SwiftData
import SwiftUI

/// The standalone chat sidebar's width, which the user sets by dragging its right border.
enum ChatSidebarLayout {
    static let widthKey = "chatSidebarWidth"
    static let defaultWidth: CGFloat = 460
    static let minimumWidth: CGFloat = 320
    /// The board's own minimum width (see the board's `minWidth`).
    static let minimumBoardWidth: CGFloat = 980

    /// The window grows to fit the sidebar and the board's minimum width, so the sidebar can
    /// widen only until that total reaches the screen, and never below its default width.
    static func clampedWidth(_ width: CGFloat) -> CGFloat {
        let screenWidth = (NSApp.keyWindow?.screen ?? NSScreen.main)?.visibleFrame.width ?? 0
        let maximum = max(defaultWidth, screenWidth - minimumBoardWidth)
        return min(max(width, minimumWidth), maximum)
    }
}

/// The standalone chat's conversation. The board re-renders on every frame of a chat resize, and
/// a conversation view rebuilt from it, closures and all, re-ran its whole transcript each time;
/// compared by the chat it shows, it updates only from its own state and the chat's model. Any
/// input added here that can change must also be compared in `==`, or its changes are ignored. The
/// closures only reach the board's state storage, so an older copy of them stays valid.
private struct StandaloneChatPanel: View, Equatable {
    let chat: StandaloneChat
    let onOpenTask: (UUID, String) -> Void
    let onClose: () -> Void

    static func == (lhs: StandaloneChatPanel, rhs: StandaloneChatPanel) -> Bool {
        lhs.chat === rhs.chat
    }

    var body: some View {
        TaskConversationView(
            task: chat, isNewTask: false,
            conflictResolutionRequested: false,
            onConflictResolutionChecked: { _ in },
            onOpenTask: onOpenTask,
            onBack: onClose
        )
    }
}

/// An open task's conversation. The board re-renders whenever any task's runtime state changes,
/// and a conversation view rebuilt from it, closures and all, re-ran its whole transcript each
/// time; compared by its inputs, it updates only from its own state and the task's model. Any
/// input added here that can change must also be compared in `==`. The closures only reach the
/// board's state storage, so an older copy of them stays valid.
private struct TaskConversationPanel: View, Equatable {
    let task: BoardTask
    let isNewTask: Bool
    let conflictResolutionRequested: Bool
    let skillFixPrompt: String?
    let presentScheduleOnAppear: TaskScheduleKind?
    let onConflictResolutionChecked: (Bool) -> Void
    let onOpenTask: (UUID, String) -> Void
    let onBack: () -> Void

    static func == (lhs: TaskConversationPanel, rhs: TaskConversationPanel) -> Bool {
        lhs.task === rhs.task && lhs.isNewTask == rhs.isNewTask
            && lhs.conflictResolutionRequested == rhs.conflictResolutionRequested
            && lhs.skillFixPrompt == rhs.skillFixPrompt
            && lhs.presentScheduleOnAppear == rhs.presentScheduleOnAppear
    }

    var body: some View {
        TaskConversationView(
            task: task, isNewTask: isNewTask,
            conflictResolutionRequested: conflictResolutionRequested,
            onConflictResolutionChecked: onConflictResolutionChecked,
            skillFixPrompt: skillFixPrompt,
            onOpenTask: onOpenTask,
            presentScheduleOnAppear: presentScheduleOnAppear,
            onBack: onBack
        )
    }
}

struct KanbanBoardView: View {
    private let boardSidebarWidth: CGFloat = 200
    @AppStorage(ChatSidebarLayout.widthKey, store: WorkspaceSettings.preferencesStore)
    private var storedChatSidebarWidth = Double(ChatSidebarLayout.defaultWidth)
    @State private var chatSidebarResizeStartWidth: CGFloat?
    /// The width while a drag is under way; it is saved to the preferences only when the drag ends.
    @State private var chatSidebarDragWidth: CGFloat?
    /// The width the chat was last laid out at during a drag. Laying out every reply again on each
    /// frame of the drag made it stutter, so the chat catches up only when the edge pauses, and
    /// when the drag ends.
    @State private var chatSidebarReflowWidth: CGFloat?

    private var chatSidebarWidth: CGFloat {
        chatSidebarDragWidth ?? ChatSidebarLayout.clampedWidth(CGFloat(storedChatSidebarWidth))
    }

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var conversationRuntime: ConversationRuntimeModel
    @Query(filter: #Predicate<BoardTask> { $0.statusRawValue != "Done" }, sort: \BoardTask.createdAt, order: .reverse) private var allTasks: [BoardTask]
    /// Board cards. Recurring schedule templates aren't board tasks; the Scheduled Tasks page
    /// lists them, and each of their runs appears here as its own task.
    private var tasks: [BoardTask] { allTasks.filter { !$0.isRecurringScheduleTemplate } }
    @State private var isShowingScheduledTasks = false
    /// Opens the next new task with the schedule hint already showing, set to this kind.
    @State private var presentScheduleOnOpen: TaskScheduleKind?
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
    /// Prompts that tasks opened by the Skills page's Fix with Agent send when they appear.
    @State private var skillFixPrompts: [UUID: String] = [:]
    @State private var checkingMergedPullRequests = false
    @State private var mergedPullRequestCheckPending = false
    @State private var mergedPullRequestCheckTimerScheduled = false
    @State private var lastMergedPullRequestCheckAt: Date?
    @State private var taskAwaitingUnmergedConfirmation: UUID?
    @State private var taskAwaitingDiscardConfirmation: UUID?
    @State private var discardConfirmationMessage = ""
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
    @State private var reviewMoveError: String?
    @State private var isShowingBoardSearch = false
    @State private var boardSearchText = ""
    @FocusState private var isBoardSearchFocused: Bool
    @State private var isShowingChatSidebar = false
    /// The thickness a legacy (always visible) scroller takes from the board's visible area.
    @State private var boardScrollerInset = KanbanBoardView.legacyScrollerInset()
    @State private var chatTask: StandaloneChat?
    @State private var isOpeningChatSidebar = false
    /// A modal, sidebar or page plugin opened from the board's sidebar.
    @State private var openBoardPlugin: PluginRecord?
    @State private var isStartingPluginTask = false
    @AppStorage(WorkspaceSettings.appearanceKey, store: WorkspaceSettings.preferencesStore) private var appearance = "dark"

    /// Provider-owning operations run in the bridge daemon.
    private var remoteConversations: RemoteConversationManager {
        RemoteConversationManager(daemon: conversationRuntime.client, runtime: conversationRuntime, modelContext: modelContext)
    }

    private var isChatOverlayVisible: Bool {
        isShowingChatSidebar && selectedTask == nil && chatTask != nil
    }

    var body: some View {
        mainContent
    }

    private func conversationView(for selectedTask: BoardTask) -> some View {
        TaskConversationPanel(
            task: selectedTask, isNewTask: isSelectedTaskNew,
            conflictResolutionRequested: conflictResolutionTaskID == selectedTask.id,
            skillFixPrompt: skillFixPrompts[selectedTask.id],
            presentScheduleOnAppear: presentScheduleOnOpen,
            onConflictResolutionChecked: { resolved in
                if resolved { conflictedReviewTaskIDs.remove(selectedTask.id) }
                else { conflictedReviewTaskIDs.insert(selectedTask.id) }
            },
            onOpenTask: openTask(_:sending:)
        ) {
            self.skillFixPrompts[selectedTask.id] = nil
            self.selectedTask = nil
            self.isSelectedTaskNew = false
            self.conflictResolutionTaskID = nil
            self.presentScheduleOnOpen = nil
        }
        .equatable()
        .id(selectedTask.id)
    }

    private var mainContent: some View {
        Group {
            if let selectedTask {
                conversationView(for: selectedTask)
            } else {
                boardContent
            }
        }
        .background(WorkspaceTheme.windowBackground)
        // The open chat adds its width to the board's minimum, so the content-sized window grows
        // to keep the pushed columns visible, as it did when the chat sat beside the board.
        .frame(minWidth: ChatSidebarLayout.minimumBoardWidth + (isChatOverlayVisible ? chatSidebarWidth : 0), minHeight: 640)
        .task(id: allTasks.contains { $0.scheduleKind != nil && !$0.schedulePaused }) {
            SchedulerAgent.sync(hasActiveSchedules: allTasks.contains { $0.scheduleKind != nil && !$0.schedulePaused })
        }
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
        .alert("Couldn't move task to Review", isPresented: Binding(
            get: { reviewMoveError != nil },
            set: { if !$0 { reviewMoveError = nil } }
        )) {
            Button("OK", role: .cancel) { reviewMoveError = nil }
            .buttonHoverPointer()
            .nativeHelp("Dismiss Review move error")
        } message: {
            Text(reviewMoveError ?? "Please try again.")
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
            Text("The pull request hasn't been merged. Marking this task Done removes its worktree and keeps its branch.")
        }
        .confirmationDialog(
            "Discard uncommitted changes?",
            isPresented: Binding(
                get: { taskAwaitingDiscardConfirmation != nil },
                set: { if !$0 { taskAwaitingDiscardConfirmation = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Discard Changes and Mark Done", role: .destructive) {
                guard let id = taskAwaitingDiscardConfirmation else { return }
                taskAwaitingDiscardConfirmation = nil
                moveTask(id: id, to: .done, allowUnmergedPullRequests: true, allowDiscardingUncommittedChanges: true)
            }
            .buttonHoverPointer()
            .nativeHelp("Discard uncommitted changes and mark this task Done")
            .accessibilityIdentifier("discard-changes-confirm-button")
            Button("Cancel", role: .cancel) { taskAwaitingDiscardConfirmation = nil }
            .buttonHoverPointer()
            .nativeHelp("Keep the worktree and leave this task in Review")
            .accessibilityIdentifier("discard-changes-cancel-button")
        } message: {
            Text(discardConfirmationMessage)
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

    /// Before macOS 15 the board can't anchor smaller content top leading, so it fills the full
    /// frame instead: a legacy scroller then gets a few points of needless travel, but the clip
    /// origin never goes negative, which is what desynchronized hit testing.
    private static func legacyScrollerInset() -> CGFloat {
        guard #available(macOS 15.0, *), NSScroller.preferredScrollerStyle == .legacy else { return 0 }
        return NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
    }

    private var boardContent: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                boardHeader

                Rectangle()
                    .fill(Color.primary.opacity(0.07))
                    .frame(height: 1)

                HStack(spacing: 0) {
                    boardSidebar

                    Rectangle()
                        .fill(Color.primary.opacity(0.07))
                        .frame(width: 1)

                    if isChatOverlayVisible {
                        Color.clear
                            .frame(width: max(0, chatSidebarWidth - boardSidebarWidth - 1))
                            .accessibilityHidden(true)
                    }

                    VStack(spacing: 0) {
                        if let lifecycleResetNotice {
                            lifecycleResetBanner(lifecycleResetNotice)
                        }

                        HStack(spacing: 0) {
                            // The board centers its columns with its own frame and keeps the scroll view's
                            // clip origin at zero. Left to itself, the two-axis scroll view centers narrower
                            // content by giving AppKit's clip view a negative bounds origin, and after a
                            // horizontal scroll nudge followed by a content-height change, SwiftUI's hit
                            // testing lost that offset: the board drew centered while clicks resolved as if
                            // it were flush left, so buttons stopped responding until the window was resized.
                            // The minimum size tracks the visible area, not the reader's frame: legacy
                            // scrollers take their thickness out of the visible area, and content sized to the
                            // full frame would show a needless scroll bar.
                            GeometryReader { viewport in
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
                                    .frame(
                                        minWidth: max(0, viewport.size.width - boardScrollerInset),
                                        minHeight: max(0, viewport.size.height - boardScrollerInset)
                                    )
                                }
                                .modifier(TopLeadingScrollAlignment())
                                .scrollIndicators(.visible)
                                .background(WorkspaceTheme.windowBackground)
                                .scrollContentBackground(.hidden)
                                .accessibilityIdentifier("board-columns-scroll-view")
                            }
                            .onReceive(NotificationCenter.default.publisher(for: NSScroller.preferredScrollerStyleDidChangeNotification)) { _ in
                                boardScrollerInset = Self.legacyScrollerInset()
                            }

                            // A fixed gutter beside the scroll view rather than an overlay, so the opened
                            // drawer never covers a column and stays put while scrolling.
                            DoneDropDrawer(
                                isOpen: draggedTaskStatus == .review,
                                isActive: $isDoneTargetActive,
                                onDrop: { moveTask(id: $0, to: .done) }
                            )
                        }
                    }
                }
            }

            standaloneChatOverlay
        }
        .animation(.easeInOut(duration: 0.22), value: isShowingChatSidebar)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: draggedTaskID) {
            // SwiftUI reports no end for a drag that lands outside every drop target (for
            // example a card dropped back in place), and the drag session consumes the
            // mouse-up, so watch the button itself. The grace period lets a real drop finish
            // against the open drawer before it closes.
            guard draggedTaskID != nil else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(120))
                guard NSEvent.pressedMouseButtons & 1 == 0 else { continue }
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                if NSEvent.pressedMouseButtons & 1 == 0 {
                    draggedTaskID = nil
                    isDoneTargetActive = false
                    return
                }
            }
        }
        // Keep a platform view behind the board. #156 removed the last one (the old drag-end
        // monitor). Without it, accessibility hit tests over parts of the opened Done archive
        // resolved to the board's scroll view underneath: the rows still took mouse clicks, but
        // XCUITest (and so assistive clients) did not find them. A platform view here restores
        // it; that was found by bisecting and experiment, and the AppKit mechanism is not
        // confirmed. Do not remove it without rerunning test_task_done_removes_worktree_and_preserves_branch,
        // whose archive hittability check guards it.
        .background(BoardAccessibilityHitTestAnchor())
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
        .overlay { scheduledTasksPage }
        .pluginPresentation(
            $openBoardPlugin,
            props: { PluginContext.props(plugin: $0, appearance: appearance, task: nil, composer: nil) },
            actions: boardPluginActions
        )
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

    /// The chat sidebar's right border; dragging it right widens the chat and left narrows it.
    private func chatSidebarResizeHandle(width: CGFloat) -> some View {
        Rectangle()
            .fill(Color.primary.opacity(0.07))
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .leading) {
                // A wide invisible strip makes the 1pt border easy to grab. It starts at the border
                // and extends only over the board, so the chat transcript's scroller, which runs
                // along the border's inner side, keeps its own pointer and drags.
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .hoverCursor(.resizeLeftRight)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                if chatSidebarResizeStartWidth == nil {
                                    // Held for the whole drag, so the pointer can leave the thin border.
                                    NSCursor.resizeLeftRight.push()
                                }
                                let start = chatSidebarResizeStartWidth ?? width
                                chatSidebarResizeStartWidth = start
                                if chatSidebarReflowWidth == nil { chatSidebarReflowWidth = start }
                                chatSidebarDragWidth = ChatSidebarLayout.clampedWidth(start + value.translation.width)
                            }
                            .onEnded { _ in
                                endChatSidebarResize()
                            }
                    )
                    .onDisappear {
                        // A sidebar closed mid-drag may never end the gesture.
                        endChatSidebarResize()
                    }
                    .accessibilityElement()
                    .accessibilityLabel("Resize chat")
                    .accessibilityValue("\(Int(width.rounded())) points")
                    .accessibilityIdentifier("chat-sidebar-resize-handle")
            }
    }

    private func endChatSidebarResize() {
        guard chatSidebarResizeStartWidth != nil else { return }
        NSCursor.pop()
        if let chatSidebarDragWidth {
            storedChatSidebarWidth = Double(chatSidebarDragWidth)
        }
        chatSidebarResizeStartWidth = nil
        chatSidebarDragWidth = nil
        chatSidebarReflowWidth = nil
    }

    private var standaloneChatOverlay: some View {
        Group {
            if isShowingChatSidebar, selectedTask == nil, let chatTask {
                StandaloneChatPanel(chat: chatTask, onOpenTask: openTask(_:sending:)) {
                    setChatSidebarVisible(false)
                }
                .equatable()
                // While the edge moves, the chat keeps the width it was last laid out at, and the panel
                // clips or reveals the rest; it reflows when the edge rests and when the drag ends.
                .frame(width: chatSidebarReflowWidth ?? chatSidebarWidth)
                .frame(width: chatSidebarWidth, alignment: .leading)
                .background(WorkspaceTheme.windowBackground)
                .clipped()
                .task(id: chatSidebarDragWidth) {
                    // Each move restarts this wait, so the chat reflows once the edge rests.
                    guard let chatSidebarDragWidth else { return }
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !Task.isCancelled else { return }
                    chatSidebarReflowWidth = chatSidebarDragWidth
                }
                .frame(maxHeight: .infinity, alignment: .topLeading)
                .overlay(alignment: .trailing) {
                    chatSidebarResizeHandle(width: chatSidebarWidth)
                }
                .transition(.move(edge: .leading).combined(with: .opacity))
                .id(chatTask.id)
                // Without a container, this identifier replaces the conversation controls' own.
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("chat-sidebar")
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
            acceptsDraggedTask: status == .review && draggedTaskStatus == .waitingResponse,
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

    private var runningTaskCountByProvider: [ConversationProvider: Int] {
        tasks.filter { $0.status == .inProgress }.reduce(into: [:]) { $0[$1.conversationProvider, default: 0] += 1 }
    }

    private var boardSidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            AtomButton(
                common: AtomCommon(testID: "scheduled-tasks-button", help: "Scheduled tasks", fillWidth: true),
                action: { isShowingScheduledTasks.toggle() }
            ) {
                AtomPanel(
                    props: PanelProps(fill: "accent", fillOpacity: isShowingScheduledTasks ? 0.14 : 0, cornerRadius: 8),
                    common: AtomCommon(fillWidth: true, paddingX: 12, paddingY: 9)
                ) {
                    AtomLabel(props: LabelProps(text: "Scheduled Tasks", icon: "clock", size: 12, weight: "medium"))
                }
            }

            PluginSlot(
                placement: .mainSidebar,
                props: { PluginContext.props(plugin: $0, appearance: appearance, task: nil, composer: nil) },
                actions: boardPluginActions,
                open: { openBoardPlugin = $0 },
                add: startPluginTask
            )

            Spacer(minLength: 0)

            AgentsInfoView(runningProviders: runningTaskCountByProvider)
        }
        .padding(12)
        .frame(width: boardSidebarWidth)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(WorkspaceTheme.panelBackground.opacity(0.62))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Kanban sidebar")
        .accessibilityHidden(isChatOverlayVisible)
    }

    /// The board's header, composed only of plugin atoms (Plugins/Atoms). The
    /// New Task button takes the window's tint (`WorkspaceTheme.accent`).
    private var boardHeader: some View {
        AtomStack(props: StackProps(axis: "h", spacing: 24), common: AtomCommon(paddingX: 30)) {
            AtomStack(props: StackProps(axis: "h", spacing: 14)) {
                AtomIcon(props: IconProps(asset: "PlayhouseLogo", original: true), common: AtomCommon(label: "Playhouse logo", width: 50, height: 50))
                AtomStack(props: StackProps(spacing: 3, align: "leading")) {
                    AtomText(props: TextProps(text: "Playhouse", size: 21, weight: "semibold", design: "rounded"), common: AtomCommon(testID: "board-title"))
                    AtomText(props: TextProps(text: "Let the show begin.", size: 12.5, color: "secondary"))
                }
            }
            .accessibilityHidden(isChatOverlayVisible)

            AtomSpacer(props: SpacerProps(minLength: 20))

            AtomStack(props: StackProps(axis: "h", spacing: 14)) {
                AtomButton(
                    props: ButtonProps(style: "bordered"),
                    common: AtomCommon(testID: "done-archive-button", label: "Done tasks", help: "Browse completed tasks"),
                    action: { withAnimation(.easeInOut(duration: 0.24)) { isShowingDoneArchive.toggle() } }
                ) {
                    AtomIcon(props: IconProps(name: "archivebox", size: 14, weight: "semibold"), common: AtomCommon(width: 30, height: 30))
                }
                AtomButton(
                    props: ButtonProps(style: "bordered", disabled: isOpeningChatSidebar),
                    common: AtomCommon(testID: "chat-sidebar-button", help: "Open the standalone chat", paddingX: 7, paddingY: 3),
                    action: openChatSidebar
                ) {
                    AtomLabel(props: LabelProps(text: "Chat", icon: "bubble.left.and.bubble.right", size: 13, weight: "semibold"))
                }
                AtomButton(
                    props: ButtonProps(style: "prominent", disabled: isCreatingNewTask),
                    common: AtomCommon(testID: "new-task-button", help: "Create a new task", paddingX: 7, paddingY: 3),
                    action: openNewTask
                ) {
                    AtomLabel(props: LabelProps(text: "New Task", icon: "plus", size: 13, weight: "semibold"))
                }
            }
        }
        .padding(.top, 24)
        .padding(.bottom, 21)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Kanban header")
    }

    /// The notice that some task worktrees were kept, composed only of plugin atoms (Plugins/Atoms).
    private func lifecycleResetBanner(_ notice: String) -> some View {
        AtomPanel(
            props: PanelProps(fill: "panel", fillOpacity: 1, cornerRadius: 0),
            common: AtomCommon(testID: "task-lifecycle-reset-notice", fillWidth: true, padding: 12, paddingX: 6)
        ) {
            AtomStack(props: StackProps(axis: "h", spacing: 12, align: "top")) {
                AtomIcon(props: IconProps(name: "exclamationmark.triangle.fill", color: "orange"))
                AtomStack(props: StackProps(spacing: 4, align: "leading")) {
                    AtomText(props: TextProps(text: "Some task worktrees were kept", size: 12, weight: "semibold"), common: AtomCommon(testID: "task-lifecycle-reset-title"))
                    AtomText(props: TextProps(text: notice, size: 11, wrap: true), common: AtomCommon(testID: "task-lifecycle-reset-details"))
                }
                AtomSpacer(props: SpacerProps(minLength: 8))
                AtomButton(
                    props: ButtonProps(style: "automatic"),
                    common: AtomCommon(testID: "dismiss-task-lifecycle-reset-notice", help: "Dismiss worktree notice"),
                    action: { lifecycleResetNotice = nil }
                ) {
                    AtomText(props: TextProps(text: "OK"))
                }
            }
        }
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

    /// The archive row's pull request actions, composed only of plugin atoms
    /// (Plugins/Atoms) like the task item's.
    @ViewBuilder
    private func archivedTaskPullRequestControl(_ task: BoardTask) -> some View {
        let linked = task.repositoryWorktrees.filter { $0.pullRequestNumber != nil && $0.pullRequestURL != nil }
        let awaiting = task.repositoryWorktrees.filter(\.awaitsPullRequest)
        let started = task.repositoryWorktrees.filter { !$0.isPending }
        let hasMultipleRepositories = (awaiting.isEmpty ? started : awaiting).count > 1
        let isCreating = taskCreatingPullRequests.contains(task.id)
        let title = hasMultipleRepositories ? "PRs" : "PR"
        if linked.isEmpty {
            archivedTaskCreatePullRequestButton(
                task, title: title, busy: isCreating,
                label: hasMultipleRepositories ? "PRs. Create pull requests for each repository linked to this completed task" : "PR. Create a pull request for each repository linked to this completed task",
                help: "Create a pull request for each repository linked to this completed task"
            )
        } else {
            AtomStack(props: StackProps(axis: "h", spacing: 5)) {
                if !awaiting.isEmpty {
                    archivedTaskCreatePullRequestButton(
                        task, title: title, busy: isCreating,
                        label: hasMultipleRepositories ? "PRs. Create pull requests for repositories without a linked pull request" : "PR. Create a pull request for the repository without a linked pull request",
                        help: "Create pull requests for repositories without a linked pull request"
                    )
                }
                // Pull requests merged before a renewed worktree stay listed ahead of the current ones.
                ForEach(task.pastRepositoryWorktrees.filter { $0.pullRequestNumber != nil && $0.pullRequestURL != nil } + linked, id: \.pullRequestURL) { record in
                    if let number = record.pullRequestNumber, let url = record.pullRequestURL {
                        // The chip stays compact; the click target keeps the 30 pt minimum of its sibling actions.
                        AtomLink(
                            props: LinkProps(url: url, emphasis: 5),
                            common: AtomCommon(
                                testID: "done-archive-pr-link-\(task.id.uuidString)-\(number)",
                                help: URL(fileURLWithPath: record.repositoryPath).lastPathComponent, minWidth: 30, minHeight: 30
                            )
                        ) {
                            AtomText(props: TextProps(text: "#\(number)", size: 10, weight: "semibold", design: "monospaced"))
                        }
                    }
                }
            }
        }
    }

    private func archivedTaskCreatePullRequestButton(_ task: BoardTask, title: String, busy: Bool, label: String, help: String) -> some View {
        AtomButton(
            props: ButtonProps(style: "borderless", emphasis: 4, disabled: busy),
            common: AtomCommon(testID: "done-archive-create-pr-\(task.id.uuidString)", label: label, help: help, width: 30, height: 30),
            action: { createPullRequests(for: task) }
        ) {
            if busy {
                AtomSpinner(props: SpinnerProps(size: "mini"))
            } else {
                AtomText(props: TextProps(text: title, size: 10, weight: "semibold"))
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
            setChatSidebarVisible(false)
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
                setChatSidebarVisible(true)
            } catch {
                saveError = error.localizedDescription
            }
        }
    }

    private func setChatSidebarVisible(_ visible: Bool) {
        withAnimation(.easeInOut(duration: 0.22)) { isShowingChatSidebar = visible }
    }

    private var boardPluginActions: PluginUIActions {
        PluginUIActions(openTask: { id in
            if let task = try? BoardTaskManager(modelContext: modelContext).taskModel(id) {
                openBoardPlugin = nil
                isSelectedTaskNew = false
                selectedTask = task
            }
        })
    }

    /// An Add Plugin mode placeholder was pressed: the new task's agent builds
    /// a plugin for that placement, and the mode ends.
    private func startPluginTask(_ placement: PluginPlacement) {
        guard !isStartingPluginTask else { return }
        isStartingPluginTask = true
        Task { @MainActor in
            defer { isStartingPluginTask = false }
            do {
                let started = try await PluginRegistry(client: conversationRuntime.client).author(placement)
                PluginRegistry.setAddMode(false)
                openTask(started.taskID, sending: started.prompt)
            } catch {
                saveError = error.localizedDescription
            }
        }
    }

    /// Shows a task the daemon just created, such as one fixing skills, and
    /// has its conversation send `prompt` once it opens.
    private func openTask(_ id: UUID, sending prompt: String) {
        let origin = selectedTask?.id
        Task { @MainActor in
            let manager = BoardTaskManager(modelContext: modelContext)
            // The daemon wrote the task; give this window's store a moment to see it.
            for _ in 0..<100 {
                // The user moved on while the store caught up; leave their choice alone.
                guard selectedTask?.id == origin else { return }
                if let task = try? manager.taskModel(id) {
                    // A plugin's openTask shows the task without sending anything.
                    skillFixPrompts[id] = prompt.isEmpty ? nil : prompt
                    setChatSidebarVisible(false)
                    isSelectedTaskNew = false
                    conflictResolutionTaskID = nil
                    selectedTask = task
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            saveError = "Playhouse created the task but couldn't open it. Find it in Backlog."
        }
    }

    /// Slides in over the board like the Skills page. It stays up while a task opened from it
    /// is showing, so closing that task returns here.
    private var scheduledTasksPage: some View {
        ZStack {
            if isShowingScheduledTasks {
                ScheduledTasksPageView(
                    scheduledTasks: allTasks.filter { $0.scheduleKind != nil },
                    remoteConversations: remoteConversations,
                    onNewTask: { openNewTask(presentingSchedule: .recurring) },
                    onOpenTask: { task in
                        isSelectedTaskNew = false
                        conflictResolutionTaskID = nil
                        presentScheduleOnOpen = nil
                        selectedTask = task
                    },
                    onOpenRunTask: { id in
                        if let task = try? BoardTaskManager(modelContext: modelContext).taskModel(id) {
                            isShowingScheduledTasks = false
                            isSelectedTaskNew = false
                            presentScheduleOnOpen = nil
                            selectedTask = task
                        }
                    }
                ) {
                    isShowingScheduledTasks = false
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .shadow(color: .black.opacity(0.25), radius: 16, x: -4)
                .transition(.move(edge: .trailing))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .allowsHitTesting(isShowingScheduledTasks)
        .animation(.spring(response: 0.34, dampingFraction: 0.92), value: isShowingScheduledTasks)
    }

    private func openNewTask() {
        openNewTask(presentingSchedule: nil)
    }

    private func openNewTask(presentingSchedule: TaskScheduleKind?) {
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
                    pullRequestMode: .pullRequest
                )
                let newTask = try manager.taskModel(created.id)
                presentScheduleOnOpen = presentingSchedule
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

    /// Each drag reveals only the target its source column can move to: Review
    /// cards get the Done target, Waiting Response cards the Review column.
    private var draggedTaskStatus: TaskStatus? {
        draggedTaskID.flatMap { id in tasks.first(where: { $0.id == id })?.status }
    }

    private func moveTask(
        id: UUID,
        to status: TaskStatus,
        allowUnmergedPullRequests: Bool = false,
        allowDiscardingUncommittedChanges: Bool = false
    ) {
        guard let task = tasks.first(where: { $0.id == id }), task.status != status else { return }
        if status == .review {
            guard task.status == .waitingResponse else { return }
            Task { @MainActor in
                do {
                    _ = try await remoteConversations.moveTaskToReview(taskID: id)
                } catch {
                    reviewMoveError = error.localizedDescription
                }
            }
            return
        }
        guard status == .done else { return }
        let skipMergeVerification = mergedReviewTaskIDs.contains(id)
        Task { @MainActor in
            do {
                _ = try await BoardTaskManager(modelContext: modelContext).move(
                    id,
                    to: status.rawValue,
                    allowUnmergedPullRequests: allowUnmergedPullRequests,
                    allowDiscardingUncommittedChanges: allowDiscardingUncommittedChanges,
                    skipMergeVerification: skipMergeVerification
                )
            } catch PlayhouseManagerError.unmergedPullRequests {
                taskAwaitingUnmergedConfirmation = id
            } catch let error as PlayhouseManagerError {
                if case .uncommittedChanges = error {
                    discardConfirmationMessage = error.localizedDescription
                    taskAwaitingDiscardConfirmation = id
                } else {
                    doneMoveError = error.localizedDescription
                }
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

/// Places scroll content smaller than its container at the top leading corner instead of
/// centering it through a negative clip origin; the board centers its columns itself.
private struct TopLeadingScrollAlignment: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.defaultScrollAnchor(.topLeading, for: .alignment)
        } else {
            content
        }
    }
}

/// An empty, zero-size AppKit view kept behind the board because, empirically, the Done
/// archive overlay's accessibility hit testing breaks without one; see its use in `body`.
private struct BoardAccessibilityHitTestAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private struct DoneDropDrawer: View {
    let isOpen: Bool
    @Binding var isActive: Bool
    let onDrop: (UUID) -> Void

    private static let tabWidth: CGFloat = 44
    private static let tabHeight: CGFloat = 168
    private static let gap: CGFloat = 10
    private static let trailingMargin: CGFloat = 10
    /// How much of the tab's leading edge stays visible while no drag is in progress.
    private static let peekWidth: CGFloat = 5

    var body: some View {
        // The gutter keeps its width so the board never reflows; only the tab slides, from
        // a sliver peeking at the window edge to fully open while a card is dragged.
        tab
            .frame(width: Self.tabWidth, height: Self.tabHeight)
            .scaleEffect(isActive ? 1.06 : 1)
            .offset(x: isOpen ? 0 : Self.tabWidth + Self.trailingMargin - Self.peekWidth)
            .padding(.leading, Self.gap)
            .padding(.trailing, Self.trailingMargin)
            .frame(maxHeight: .infinity)
            .clipped()
            .animation(.spring(response: 0.34, dampingFraction: 0.84), value: isOpen)
            .animation(.easeOut(duration: 0.14), value: isActive)
    }

    private var tab: some View {
        VStack(spacing: 7) {
            Image(systemName: "checkmark")
                .font(.system(size: 14, weight: .bold))
            Text("Done")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(isActive ? Color.white : TaskStatus.done.accent)
        .opacity(isOpen ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            isActive ? TaskStatus.done.accent : TaskStatus.done.accent.opacity(isOpen ? 0.12 : 0.45),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(TaskStatus.done.accent.opacity(isActive ? 0 : 0.45), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onDrop(of: [.plainText], delegate: DoneDrawerDropDelegate(isOpen: isOpen, isActive: $isActive, onDrop: onDrop))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("task-done-drop-target")
        .accessibilityLabel("Move task to Done")
        .accessibilityValue(isOpen ? "Open" : "Resting")
        .accessibilityHint("Drop a reviewed task here to move it to Done.")
    }
}

/// The resting sliver stays on screen during drags it doesn't open for (such as a
/// Waiting Response card heading to Review), so it must neither light up nor accept them.
private struct DoneDrawerDropDelegate: DropDelegate {
    let isOpen: Bool
    @Binding var isActive: Bool
    let onDrop: (UUID) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        isOpen && info.hasItemsConforming(to: [.plainText])
    }

    func dropEntered(info: DropInfo) {
        isActive = isOpen
    }

    func dropExited(info: DropInfo) {
        isActive = false
    }

    func performDrop(info: DropInfo) -> Bool {
        isActive = false
        guard isOpen, let provider = info.itemProviders(for: [.plainText]).first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { value, _ in
            guard let value = value as? String, let id = UUID(uuidString: value) else { return }
            DispatchQueue.main.async { onDrop(id) }
        }
        return true
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
    /// True while a card this column can receive is being dragged.
    let acceptsDraggedTask: Bool
    let minHeight: CGFloat
    @State private var isDropTargeted = false

    var body: some View {
        dropTarget
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("column-\(status.accessibilityKey)")
    }

    private var columnContent: some View {
        KanbanColumnSection(
            model: KanbanColumnModel(status: status, taskCount: tasks.count),
            minHeight: Double(minHeight),
            onAdd: onAddTask
        ) {
            ForEach(tasks) { task in
                draggableTaskCard(task)
            }
        }
        .overlay {
            if acceptsDraggedTask {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(status.accent.opacity(isDropTargeted ? 0.16 : 0.06))
                    .strokeBorder(status.accent.opacity(isDropTargeted ? 0.9 : 0.45), style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1.5, dash: isDropTargeted ? [] : [6, 4]))
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("task-\(status.accessibilityKey)-drop-target")
            }
        }
    }

    @ViewBuilder
    private var dropTarget: some View {
        if status == .review {
            // Waiting Response cards drop here; the board ignores any other source.
            columnContent
                .onDrop(of: [.plainText], isTargeted: $isDropTargeted) { providers in
                    guard acceptsDraggedTask, let provider = providers.first else { return false }
                    // End the drag now, so the card turning Review can't briefly open the Done drawer.
                    draggedTaskID = nil
                    _ = provider.loadObject(ofClass: NSString.self) { value, _ in
                        guard let value = value as? String, let id = UUID(uuidString: value) else { return }
                        DispatchQueue.main.async { onMoveTask(id, status) }
                    }
                    return true
                }
        } else if status != .done {
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
            onMoveToDone: task.status == .review ? { onMoveTask(task.id, .done) } : nil,
            onMoveToReview: task.status == .waitingResponse ? { onMoveTask(task.id, .review) } : nil
        )
        if task.status == .waitingResponse || task.status == .review {
            card.onDrag {
                draggedTaskID = task.id
                return NSItemProvider(object: task.id.uuidString as NSString)
            }
        } else {
            card
        }
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

/// A board card: the task's display model, rendered by the atom-built
/// `TaskItemView`, wired to the board's actions.
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
    let onMoveToReview: (() -> Void)?

    var body: some View {
        TaskItemView(model: model, actions: TaskItemActions(
            open: onOpen,
            menu: { id in
                switch id {
                case "done": onMoveToDone?()
                case "review": onMoveToReview?()
                case "rename": onRename()
                case "stats": onShowTokenStats()
                case "delete": onDelete()
                default: break
                }
            },
            showTokenStats: onShowTokenStats,
            createPullRequests: onCreatePullRequests,
            setPullRequestMode: { raw in
                if let mode = PullRequestMode(rawValue: raw) { onSetPullRequestMode(mode) }
            },
            moveToDone: { onMoveToDone?() },
            resolveConflicts: onResolveConflicts
        ))
    }

    /// For Codex the CPU share is the task's working-directory share of the
    /// shared app-server (see `TaskCPUUsageSnapshot`); `nil` with no running turn or sample yet.
    private var model: TaskItemModel {
        TaskItemModel(
            task: task,
            cpuPercent: cpuUsageModel.percent(threadID: task.activeConversationID),
            cpuUsageColorMax: cpuUsageColorMax,
            tokenUsageColorMax: tokenUsageColorMax,
            isCreatingPullRequests: isCreatingPullRequests,
            isPullRequestMerged: isPullRequestMerged,
            hasPullRequestConflicts: hasPullRequestConflicts,
            pullRequestHealth: pullRequestHealth,
            canMoveToDone: onMoveToDone != nil,
            canMoveToReview: onMoveToReview != nil
        )
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

/// The `ChoiceBar` atom over a string-backed choice, so the raw input sheet's
/// scope and export bars share the Token Stats section bar's view.
private struct ChoiceBar<Choice: RawRepresentable & Hashable>: View where Choice.RawValue == String {
    let choices: [(value: Choice, title: String, id: String)]
    @Binding var selection: Choice

    var body: some View {
        AtomChoiceBar(
            props: ChoiceBarProps(options: choices.map { .init(value: $0.value.rawValue, label: $0.title, testID: $0.id) }, selected: selection.rawValue)
        ) { value in
            if let choice = Choice(rawValue: value) { selection = choice }
        }
    }
}

/// The board's Token Stats modal: a task's token accounting, re-read every
/// two seconds while it is open, around the atom-built `TokenStatsView`. It
/// holds the selected section and opens the raw input sheet.
private struct TokenStatsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let taskID: UUID
    let taskTitle: String
    let modelContext: ModelContext
    @State private var summary: TaskTokenUsageSummary?
    @State private var waste: TaskTokenWasteReport?
    @State private var didLoad = false
    @State private var section = "overview"
    @State private var rawInputFocus: RawInputFocus?

    var body: some View {
        TokenStatsView(
            model: TokenStatsModel(taskTitle: taskTitle, summary: summary, waste: waste, loaded: didLoad),
            section: section,
            actions: TokenStatsActions(
                selectSection: { section = $0 },
                showRawInput: { rawInputFocus = RawInputFocus(agent: $0.agent, item: $0.item, inFinalTranscript: $0.inFinalTranscript) },
                done: { dismiss() }
            )
        )
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
                TokenShareBar(bar: TokenStatsModel.bar(row.tokens, largest: maxTokens))
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

    /// Composed only of plugin atoms (Plugins/Atoms).
    var body: some View {
        AtomStack(props: StackProps(spacing: 16, align: "leading"), common: AtomCommon(width: 420, paddingX: 24, paddingY: 24)) {
            AtomText(props: TextProps(text: "Rename task", size: 19, weight: "semibold", design: "rounded"))
            AtomTextField(
                props: TextFieldProps(text: title, placeholder: "Task title"),
                common: AtomCommon(testID: "rename-task-title-field", fillWidth: true),
                onChange: { title = $0 }
            )
            AtomStack(props: StackProps(axis: "h")) {
                AtomSpacer()
                AtomButton(props: ButtonProps(style: "automatic", shortcut: "cancel"), common: AtomCommon(help: "Cancel"), action: { dismiss() }) {
                    AtomText(props: TextProps(text: "Cancel"))
                }
                AtomButton(
                    props: ButtonProps(style: "prominent", disabled: normalizedTitle.isEmpty),
                    common: AtomCommon(testID: "save-task-rename-button", help: "Save"),
                    action: {
                        onSave(normalizedTitle)
                        dismiss()
                    }
                ) {
                    AtomText(props: TextProps(text: "Save"))
                }
            }
        }
    }
}
