import AppKit
import ServiceManagement
import SwiftData
import SwiftUI

/// The standalone chat sidebar's width, which the user sets by dragging its right border.
enum ChatSidebarLayout {
    static let widthKey = "chatSidebarWidth"
    static let defaultWidth: CGFloat = 460
    static let minimumWidth: CGFloat = 320
    /// The board's own minimum width (see the board's `minWidth`).
    static let minimumBoardWidth: CGFloat = 980
    /// The board's main sidebar, which the chat opens beside rather than over.
    static let boardSidebarWidth: CGFloat = 216
    /// The chat's leading edge: just past the main sidebar and its 1-point border.
    static let chatLeadingEdge: CGFloat = boardSidebarWidth + 1

    /// The window grows to fit the main sidebar, the chat and the board's minimum width, so the
    /// chat can widen only until that total reaches the screen, and never below its default width.
    static func clampedWidth(_ width: CGFloat) -> CGFloat {
        let screenWidth = (NSApp.keyWindow?.screen ?? NSScreen.main)?.visibleFrame.width ?? 0
        let maximum = max(defaultWidth, screenWidth - minimumBoardWidth - chatLeadingEdge)
        return min(max(width, minimumWidth), maximum)
    }
}

private struct SkillsPageWindowWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    /// The board's width beside the main sidebar, set on the standalone chat sidebar so the chat's
    /// Skills page covers the whole board from the chat's leading edge instead of only the chat.
    var skillsPageWindowWidth: CGFloat? {
        get { self[SkillsPageWindowWidthKey.self] }
        set { self[SkillsPageWindowWidthKey.self] = newValue }
    }
}

/// A conversation whose Token Stats the window shows.
struct TokenStatsTarget: Equatable {
    let id: UUID
    let title: String
}

/// Opens the window's Token Stats modal for a conversation. The board presents it over the
/// whole window, so a reply in the narrow chat sidebar can open it without clipping it.
/// Always equal, like SwiftUI's own actions: the board makes a new one each time its body
/// runs, and a change would re-render the whole chat behind its `.equatable()` boundary.
struct ShowTokenStatsAction: Equatable {
    let open: (TokenStatsTarget) -> Void
    func callAsFunction(_ target: TokenStatsTarget) { open(target) }
    static func == (lhs: Self, rhs: Self) -> Bool { true }
}

private struct ShowTokenStatsKey: EnvironmentKey {
    static let defaultValue: ShowTokenStatsAction? = nil
}

extension EnvironmentValues {
    /// Set on the standalone chat sidebar; nil where no window-wide Token Stats modal exists.
    var showTokenStats: ShowTokenStatsAction? {
        get { self[ShowTokenStatsKey.self] }
        set { self[ShowTokenStatsKey.self] = newValue }
    }
}

/// Lays out a conversation's Skills page `skillsPageWindowWidth` wide when set. It reads that
/// value itself, so a window resize re-renders only this frame rather than the whole conversation.
struct SkillsPageWindowFrame<Content: View>: View {
    @Environment(\.skillsPageWindowWidth) private var width
    @ViewBuilder let content: Content

    var body: some View {
        content.frame(width: width)
    }
}

/// Whether a conversation's Skills page is open, so the chat sidebar stops clipping it to its
/// own width and hides its resize edge while the page covers the window.
struct SkillsPageShowingKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

/// Clips the chat sidebar to its own width from its leading edge, or, while its Skills page is
/// open, to the given wider width so the page reaches across the board beside the main sidebar.
private struct ChatSidebarClip: Shape {
    var width: CGFloat?

    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX, y: rect.minY, width: width ?? rect.width, height: rect.height))
    }
}

/// A standalone chat's conversation: the chat sidebar's, or a plugin editor's. The board re-renders
/// on every frame of a chat resize and on every runtime change of any task, and a conversation view
/// rebuilt from it, closures and all, re-ran its whole transcript each time; compared by the chat it
/// shows, it updates only from its own state and the chat's model. Any input added here that can
/// change must also be compared in `==`, or its changes are ignored. The closures only reach the
/// board's state storage, so an older copy of them stays valid.
struct StandaloneChatPanel: View, Equatable {
    let chat: StandaloneChat
    /// A new plugin editor's starting prompt.
    var initialDraft: String? = nil
    let onOpenTask: (UUID, String) -> Void
    let onClose: () -> Void

    static func == (lhs: StandaloneChatPanel, rhs: StandaloneChatPanel) -> Bool {
        lhs.chat === rhs.chat && lhs.initialDraft == rhs.initialDraft
    }

    var body: some View {
        TaskConversationView(
            task: chat, isNewTask: false,
            conflictResolutionRequested: false,
            onConflictResolutionChecked: { _ in },
            initialDraft: initialDraft,
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
struct TaskConversationPanel: View, Equatable {
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
    let boardSidebarWidth = ChatSidebarLayout.boardSidebarWidth
    @AppStorage(ChatSidebarLayout.widthKey, store: WorkspaceSettings.preferencesStore)
    var storedChatSidebarWidth = Double(ChatSidebarLayout.defaultWidth)
    @State var chatSidebarResizeStartWidth: CGFloat?
    /// The width while a drag is under way; it is saved to the preferences only when the drag ends.
    @State var chatSidebarDragWidth: CGFloat?
    /// The width the chat was last laid out at during a drag. Laying out every reply again on each
    /// frame of the drag made it stutter, so the chat catches up only when the edge pauses, and
    /// when the drag ends.
    @State var chatSidebarReflowWidth: CGFloat?
    /// How far the chat's open page labels widen the sidebar beyond its set width, pushing the board aside.
    @State var chatPageAnchorsPush: CGFloat = 0

    var chatSidebarWidth: CGFloat {
        chatSidebarDragWidth ?? ChatSidebarLayout.clampedWidth(CGFloat(storedChatSidebarWidth))
    }
    /// The chat sidebar's width on screen: its set width and the room its open page labels take.
    var chatSidebarShownWidth: CGFloat { chatSidebarWidth + chatPageAnchorsPush }

    @Environment(\.modelContext) var modelContext
    @Environment(PluginRegistry.self) var pluginRegistry
    @EnvironmentObject var conversationRuntime: ConversationRuntimeModel
    @Query(filter: #Predicate<BoardTask> { $0.statusRawValue != "Done" }, sort: \BoardTask.createdAt, order: .reverse) var allTasks: [BoardTask]
    /// Board cards. Recurring schedule templates aren't board tasks; the Scheduled Tasks popover
    /// lists them, and each of their runs appears here as its own task.
    var tasks: [BoardTask] { allTasks.filter { !$0.isRecurringScheduleTemplate && !deletingTaskIDs.contains($0.id) } }
    /// Every scheduled task, soonest first, as `schedule.list` lists them for
    /// the main sidebar's `props.schedules`.
    @Query(filter: #Predicate<BoardTask> { $0.scheduleKindRawValue != nil }) var scheduledTasks: [BoardTask]
    /// Opens the next new task with the schedule hint already showing, set to this kind.
    @State var presentScheduleOnOpen: TaskScheduleKind?
    @State var isCreatingNewTask = false
    @State var saveError: String?
    @State var lifecycleResetNotice: String?
    @State var draggedTaskID: UUID?
    @State var selectedTask: BoardTask?
    @State var isSelectedTaskNew = false
    @State var taskBeingRenamed: BoardTask?
    @State var taskShowingTokenStats: TokenStatsTarget?
    @State var taskBeingDeleted: BoardTask?
    /// Tasks whose confirmed delete is still running in the daemon. Their cards leave the board
    /// at once, and come back only when the delete fails.
    @State var deletingTaskIDs: Set<UUID> = []
    @State var deleteError: String?
    @State var isShowingDeleteConfirmation = false
    @State var isDoneTargetActive = false
    @State var isShowingDoneArchive = false
    @State var archiveSearchText = ""
    @State var isIndexingArchive = false
    @State var archiveSearchResults: [BoardTask]?
    @State var archiveTasks: [BoardTask] = []
    @State var archiveOffset = 0
    @State var archiveHasMore = true
    @State var isLoadingArchivePage = false
    @State var taskCreatingPullRequests = Set<UUID>()
    @State var conflictResolutionTaskID: UUID?
    /// Prompts that tasks opened by the Skills page's Fix with Agent send when they appear.
    @State var skillFixPrompts: [UUID: String] = [:]
    @State var taskAwaitingUnmergedConfirmation: UUID?
    @State var taskAwaitingDiscardConfirmation: UUID?
    @State var discardConfirmationMessage = ""
    @State var pullRequestError: String?
    /// An alert a task card's plugin raised with `ui.alert`.
    @State var pluginAlert: PluginAlert?
    @State var pluginConfirmations = PluginConfirmations()
    /// A modal, sidebar or page plugin opened from a task card, and that card's task.
    @State var openTaskItemPlugin: PluginRecord?
    @State var openTaskItemPluginTask: BoardTask?
    @State var doneMoveError: String?
    @State var reviewMoveError: String?
    @State var isShowingBoardSearch = false
    @State var boardSearchText = ""
    @FocusState var isBoardSearchFocused: Bool
    @State var isShowingChatSidebar = false
    @State var chatTask: StandaloneChat?
    /// The chat's open parallel bubbles, oldest first, and the one opened into its larger view.
    @State var parallelBubbles: [StandaloneChat] = []
    @State var openParallelBubbleID: UUID?
    @State var pluginChat: StandaloneChat?
    @State var showPluginDraftNotice = false
    @State var pluginInitialDraft: String?
    @State var isOpeningChatSidebar = false
    /// The chat's Skills page is open and covers the whole board, laid out `boardContentWidth` wide.
    @State var isChatSkillsPageShowing = false
    @State var boardContentWidth: CGFloat = 0
    /// Where the board's sidebar and columns start, below the header and its divider.
    @State var boardBodyTop: CGFloat = 0
    /// A modal, sidebar or page plugin opened from the board's sidebar.
    @State var openBoardPlugin: PluginRecord?
    @State var pluginSetupPlacement: PluginPlacement?
    @State var isStartingPluginTask = false
    @AppStorage(WorkspaceSettings.appearanceKey, store: WorkspaceSettings.preferencesStore) var appearance = "dark"

    /// Provider-owning operations run in the bridge daemon.
    var remoteConversations: RemoteConversationManager {
        RemoteConversationManager(daemon: conversationRuntime.client, runtime: conversationRuntime, modelContext: modelContext)
    }

    var isChatOverlayVisible: Bool {
        isShowingChatSidebar && selectedTask == nil && chatTask != nil
    }

    var body: some View {
        mainContent
    }

    func conversationView(for selectedTask: BoardTask) -> some View {
        TaskConversationPanel(
            task: selectedTask, isNewTask: isSelectedTaskNew,
            conflictResolutionRequested: conflictResolutionTaskID == selectedTask.id,
            skillFixPrompt: skillFixPrompts[selectedTask.id],
            presentScheduleOnAppear: presentScheduleOnOpen,
            onConflictResolutionChecked: { _ in },
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

    var mainContent: some View {
        Group {
            if let placement = pluginSetupPlacement {
                PluginCreationSetup(placement: placement, isStarting: isStartingPluginTask, onCancel: {
                    pluginSetupPlacement = nil
                }, onStart: { name, presentation in
                    finishPluginSetup(placement, name: name, presentation: presentation)
                })
            } else if let pluginChat, let pluginID = pluginChat.authoredPluginID {
                HStack(spacing: 0) {
                    StandaloneChatPanel(chat: pluginChat, initialDraft: pluginInitialDraft, onOpenTask: openTask(_:sending:)) {
                        if let folder = pluginChat.contextFolderPaths.first {
                            let draftData = URL(fileURLWithPath: folder).deletingLastPathComponent()
                            let data = draftData.deletingLastPathComponent().deletingLastPathComponent()
                            let library = PluginLibrary(dataDirectory: data.path)
                            if library.hasDraftChanges(id: pluginID) { showPluginDraftNotice = true; return }
                        }
                        self.pluginChat = nil; pluginInitialDraft = nil
                    }
                        .equatable()
                        .id(pluginChat.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    PluginAuthoringPreview(task: pluginChat, pluginID: pluginID, onClose: {
                        self.pluginChat = nil; pluginInitialDraft = nil
                    })
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            } else if let selectedTask {
                conversationView(for: selectedTask)
            } else {
                boardContent
                    .modifier(DeleteTaskErrorAlert(message: $deleteError))
            }
        }
        .alert("Draft saved", isPresented: $showPluginDraftNotice) {
            Button("OK") { pluginChat = nil; pluginInitialDraft = nil }
                .buttonHoverPointer().nativeHelp("Close plugin editor")
        } message: { Text("Your changes are saved as a draft. You can return and continue editing later.") }
        .background(WorkspaceTheme.windowBackground)
        // The open chat adds its width and the main sidebar's to the board's minimum, so the
        // content-sized window grows to keep the pushed columns visible beside them.
        .frame(minWidth: ChatSidebarLayout.minimumBoardWidth + (isChatOverlayVisible ? ChatSidebarLayout.chatLeadingEdge + chatSidebarWidth : 0), minHeight: 640)
        .task(id: allTasks.contains { $0.scheduleKind != nil && !$0.schedulePaused }) {
            SchedulerAgent.sync(hasActiveSchedules: allTasks.contains { $0.scheduleKind != nil && !$0.schedulePaused })
        }
        .onAppear {
            // The board renders from its own @Query, not the board.list path, so it has to
            // convert a chat still stored as a hidden task itself or that row shows as a card.
            try? BoardTaskManager(modelContext: modelContext).migrateLegacyStandaloneChatTasks()
            let retained = PlayhouseStore.takeLifecycleResetNotice(
                dataDirectory: ProcessInfo.processInfo.environment["PLAYHOUSE_DATA_DIRECTORY"]
            )
            if !retained.isEmpty {
                lifecycleResetNotice = "Existing tasks were cleared. These dirty managed worktrees were kept:\n\n" + retained.joined(separator: "\n")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .playhouseStartPluginCreation)) { notification in
            guard let placement = notification.object as? PluginPlacement else { return }
            PluginRegistry.setAddMode(false)
            withAnimation(.easeInOut(duration: 0.25)) { pluginSetupPlacement = placement }
        }
        .onReceive(NotificationCenter.default.publisher(for: .playhouseEditPlugin)) { notification in
            guard let id = notification.object as? UUID else { return }
            openPluginConversation(id, draft: nil)
        }
        .onReceive(NotificationCenter.default.publisher(for: .playhousePreparePluginDelete)) { notification in
            guard let id = notification.object as? UUID else { return }
            if pluginChat?.id == id { pluginChat = nil; pluginInitialDraft = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: .playhouseShowBoardSearch)) { _ in
            withAnimation(.easeInOut(duration: 0.18)) { isShowingBoardSearch = true }
            isBoardSearchFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // The built-in plugins' daemon services hear the focus too.
            PluginServiceHost.publish(PluginEvent(name: PluginEvent.appFocus))
        }
        .task {
            // And the launch, once.
            if PluginLaunch.claim("#services") { PluginServiceHost.publish(PluginEvent(name: PluginEvent.appLaunched)) }
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
        .atomModal(ModalProps(isPresented: taskShowingTokenStats != nil, inset: 0), onDismiss: { taskShowingTokenStats = nil }) {
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
                let taskID = taskBeingDeleted.id
                deletingTaskIDs.insert(taskID)
                self.taskBeingDeleted = nil
                Task { @MainActor in
                    do {
                        try await remoteConversations.deleteTask(taskID: taskID)
                    } catch {
                        deletingTaskIDs.remove(taskID)
                        deleteError = "\(error.localizedDescription)\n\nDiagnostic log: \(PlayhouseDiagnostics.logURL.path)"
                    }
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
        .alert("Couldn't move task to Done", isPresented: Binding(
            get: { doneMoveError != nil },
            set: { if !$0 { doneMoveError = nil } }
        )) {
            Button("OK", role: .cancel) { doneMoveError = nil }
            .buttonHoverPointer()
            .nativeHelp("Dismiss move to Done error")
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

    var boardContent: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    boardHeader

                    Rectangle()
                        .fill(Color.primary.opacity(0.07))
                        .frame(height: 1)
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { boardBodyTop = $0 }

                HStack(spacing: 0) {
                    boardSidebar

                    Rectangle()
                        .fill(Color.primary.opacity(0.07))
                        .frame(width: 1)

                    if isChatOverlayVisible {
                        Color.clear
                            .frame(width: chatSidebarShownWidth)
                            .accessibilityHidden(true)
                    }

                    VStack(spacing: 0) {
                        if let lifecycleResetNotice {
                            lifecycleResetBanner(lifecycleResetNotice)
                        }

                        HStack(spacing: 0) {
                            // The board pins its columns to the top, just under the header, centers them
                            // across its width with its own viewport-sized frame, and keeps the scroll
                            // view's clip origin at zero. Left to itself, the two-axis scroll view centers
                            // narrower content by giving AppKit's clip view a negative bounds origin, and
                            // after a horizontal scroll nudge followed by a content-height change, SwiftUI's
                            // hit testing lost that offset: the board drew centered while clicks resolved as
                            // if it were flush left, so buttons stopped responding until the window was resized.
                            // The board's scrollers always float over the content (see HoverRevealScrollers),
                            // so the visible area is the reader's full frame.
                            GeometryReader { viewport in
                                ScrollView([.horizontal, .vertical]) {
                                    HStack(alignment: .top, spacing: 0) {
                                        Spacer(minLength: 30)
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
                                        // The trailing spacer also leaves room for the Done drawer, so the last
                                        // column scrolls clear of it. The spacers split spare width evenly, so the
                                        // columns center in the whole board once it is wide enough for both minimums.
                                        Spacer(minLength: 30 + DoneDropDrawer.gutterWidth)
                                    }
                                    .padding(.top, 22)
                                    .padding(.bottom, 28)
                                    .frame(minWidth: viewport.size.width, minHeight: viewport.size.height, alignment: .top)
                                    .hoverRevealScrollers()
                                }
                                .modifier(TopLeadingScrollAlignment())
                                .background(WorkspaceTheme.windowBackground)
                                .scrollContentBackground(.hidden)
                                .accessibilityIdentifier("board-columns-scroll-view")
                                // The drawer floats over the scroll view's trailing edge rather than
                                // beside it, so the vertical scroller sits at the window edge with the
                                // drawer to its left, and the drawer stays put while scrolling.
                                .overlay(alignment: .trailing) {
                                    DoneDropDrawer(
                                        isOpen: draggedTaskStatus.map(TaskStatus.manualDoneSources.contains) ?? false,
                                        isActive: $isDoneTargetActive,
                                        onDrop: { moveTask(id: $0, to: .done) }
                                    )
                                    .padding(.trailing, HoverRevealScrollers.scrollerWidth)
                                }
                            }
                        }
                    }
                }
            }

            // The chat opens beside the board sidebar, aligned with its top under the header, and
            // slides out from the sidebar's edge rather than over the sidebar or the header.
            standaloneChatOverlay
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
                .padding(.leading, ChatSidebarLayout.chatLeadingEdge)
                .padding(.top, boardBodyTop)

            // Bubbles float from the chat's right edge, below the header.
            parallelChatBubblesOverlay
                .padding(.top, boardBodyTop)
        }
        .animation(.easeInOut(duration: 0.22), value: isShowingChatSidebar)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Measured only while the chat is open, so resizing the window without it doesn't re-run the board.
        .background {
            if isShowingChatSidebar {
                Color.clear.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { boardContentWidth = $0 }
            }
        }
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
        // The SidePanel atom below keeps a platform view behind the board, without which
        // accessibility hit tests over the opened Done archive resolve to the board's scroll
        // view underneath (see `AccessibilityHitTestAnchor`).
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
        // The archive is a SidePanel atom over the board; the main sidebar's
        // page, modal and side panel plugins present over it too.
        .atomSidePanel(
            SidePanelProps(isPresented: isShowingDoneArchive, width: 340),
            common: AtomCommon(testID: "done-archive-panel")
        ) {
            doneArchivePanel
        }
        .pluginPresentation(
            $openBoardPlugin,
            props: mainSidebarPluginProps,
            actions: boardPluginActions
        )
        .background {
            Color.clear.pluginPresentation(
                $openTaskItemPlugin,
                props: { PluginContext.props(plugin: $0, appearance: appearance, task: openTaskItemPluginTask.map { PluginTaskContext(task: $0) }, composer: nil) },
                actions: taskItemPluginActions
            )
            .modifier(PluginAlertModifier(alert: $pluginAlert))
            .modifier(PluginConfirmationModifier(confirmations: pluginConfirmations))
        }
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

    /// The width the chat's Skills page covers: the board from the sidebar's edge to the window's.
    var chatSkillsPageWidth: CGFloat? {
        boardContentWidth > 0 ? max(0, boardContentWidth - ChatSidebarLayout.chatLeadingEdge) : nil
    }

    /// The board sidebar's Chat entry, drawn like the plugin entries below it: it shows the
    /// standalone chat beside the sidebar, and shows as selected while the chat is open, when
    /// pressing it again hides the chat.
    var chatSidebarEntry: some View {
        AtomButton(
            props: ButtonProps(disabled: isOpeningChatSidebar, shortcut: AppShortcut.chat),
            common: AtomCommon(testID: "chat-sidebar-button", label: "Chat", help: isChatOverlayVisible ? "Hide the standalone chat" : "Open the standalone chat", fillWidth: true),
            action: openChatSidebar
        ) {
            AtomStack(props: StackProps(align: "leading", fill: "accent", fillOpacity: isChatOverlayVisible ? 0.14 : 0, cornerRadius: 8), common: AtomCommon(fillWidth: true, paddingX: 12, paddingY: 9)) {
                AtomLabel(props: LabelProps(text: "Chat", icon: "bubble.left.and.bubble.right", size: 12, weight: "medium"))
            }
        }
        .accessibilityValue(isChatOverlayVisible ? "Shown" : "Hidden")
    }

    var standaloneChatOverlay: some View {
        Group {
            if isShowingChatSidebar, selectedTask == nil, let chatTask {
                StandaloneChatPanel(chat: chatTask, onOpenTask: openTask(_:sending:)) {
                    setChatSidebarVisible(false)
                }
                .equatable()
                // The chat's Skills page spans the board beside the sidebar, not just the chat.
                .environment(\.skillsPageWindowWidth, chatSkillsPageWidth)
                .environment(\.showTokenStats, ShowTokenStatsAction { taskShowingTokenStats = $0 })
                .onPreferenceChange(SkillsPageShowingKey.self) { isChatSkillsPageShowing = $0 }
                // The open page labels widen the sidebar, pushing the board aside, and the chat moves
                // its rows right by the same width in the same update, so they never narrow.
                .onPreferenceChange(ChatPageAnchorsPushKey.self) { push in
                    guard push != chatPageAnchorsPush else { return }
                    withAnimation(ChatPageAnchorsLayout.slideAnimation) { chatPageAnchorsPush = push }
                }
                // Opening a task from the page removes the chat without a closing preference change.
                .onDisappear {
                    isChatSkillsPageShowing = false
                    chatPageAnchorsPush = 0
                }
                .environment(\.chatPageAnchorsPush, chatPageAnchorsPush)
                // While the edge moves, the chat keeps the width it was last laid out at, and the panel
                // clips or reveals the rest; it reflows when the edge rests and when the drag ends.
                .frame(width: (chatSidebarReflowWidth ?? chatSidebarWidth) + chatPageAnchorsPush)
                .frame(width: chatSidebarShownWidth, alignment: .leading)
                .background(WorkspaceTheme.windowBackground)
                .clipShape(ChatSidebarClip(width: isChatSkillsPageShowing ? chatSkillsPageWidth : nil))
                .task(id: chatSidebarDragWidth) {
                    // Each move restarts this wait, so the chat reflows once the edge rests.
                    guard let chatSidebarDragWidth else { return }
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !Task.isCancelled else { return }
                    chatSidebarReflowWidth = chatSidebarDragWidth
                }
                .frame(maxHeight: .infinity, alignment: .topLeading)
                .overlay(alignment: .trailing) {
                    if !isChatSkillsPageShowing {
                        chatSidebarResizeHandle(width: chatSidebarWidth)
                    }
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
    func kanbanColumn(_ status: TaskStatus, minHeight: CGFloat = 480) -> some View {
        KanbanColumnView(
            status: status,
            tasks: tasks.filter { task in
                task.status == status && (boardSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || task.title.localizedCaseInsensitiveContains(boardSearchText.trimmingCharacters(in: .whitespacesAndNewlines)))
            },
            onMoveTask: { id, status in moveTask(id: id, to: status) },
            pluginActions: taskItemPluginActions,
            onOpenPlugin: { plugin, task in
                openTaskItemPluginTask = task
                openTaskItemPlugin = plugin
            },
            onAddPlugin: startPluginTask,
            onAddTask: openNewTask,
            onOpenTask: { selectedTask = $0 },
            onRenameTask: { taskBeingRenamed = $0 },
            onDeleteTask: {
                taskBeingDeleted = $0
                isShowingDeleteConfirmation = true
            },
            onShowTaskTokenStats: { taskShowingTokenStats = TokenStatsTarget(id: $0.id, title: $0.title) },
            draggedTaskID: $draggedTaskID,
            acceptsDraggedTask: status == .review && draggedTaskStatus.map(TaskStatus.manualReviewSources.contains) ?? false,
            minHeight: minHeight
        )
        .frame(width: 264)
        .frame(minHeight: minHeight)
    }

    var boardSearchBar: some View {
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

    var runningTaskCountByProvider: [ConversationProvider: Int] {
        tasks.filter { $0.status == .inProgress }.reduce(into: [:]) { $0[$1.conversationProvider, default: 0] += 1 }
    }

    var boardSidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Spaced like the plugin entries, so Chat reads as the first of them.
            VStack(alignment: .leading, spacing: 6) {
                chatSidebarEntry

                PluginSlot(
                    placement: .mainSidebar,
                    props: mainSidebarPluginProps,
                    actions: boardPluginActions,
                    open: { openBoardPlugin = $0 },
                    add: startPluginTask,
                    openPluginID: openBoardPlugin?.id
                )
            }

            Spacer(minLength: 0)

            BoardSidebarBottomSlot(runningProviders: runningTaskCountByProvider, appearance: appearance, actions: boardPluginActions, add: startPluginTask)
        }
        .padding(12)
        .frame(width: boardSidebarWidth)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(WorkspaceTheme.panelBackground.opacity(0.62))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Kanban sidebar")
    }

    /// The board's header, composed only of plugin atoms (Plugins/Atoms). The
    /// New Task button takes the window's tint (`WorkspaceTheme.accent`).
    var boardHeader: some View {
        AtomStack(props: StackProps(axis: "h", spacing: 24), common: AtomCommon(paddingX: 30)) {
            AtomStack(props: StackProps(axis: "h", spacing: 14)) {
                AtomIcon(props: IconProps(asset: "PlayhouseLogo", original: true), common: AtomCommon(label: "Playhouse logo", width: 50, height: 50))
                AtomStack(props: StackProps(spacing: 3, align: "leading")) {
                    AtomText(props: TextProps(text: "Playhouse", size: 21, weight: "semibold", design: "rounded"), common: AtomCommon(testID: "board-title"))
                    AtomText(props: TextProps(text: "Let the show begin.", size: 12.5, color: "secondary"))
                }
            }

            AtomSpacer(props: SpacerProps(minLength: 20))

            AtomStack(props: StackProps(axis: "h", spacing: 14)) {
                DoneArchiveButton(shortcut: AppShortcut.doneArchive) {
                    withAnimation(.easeInOut(duration: 0.24)) { isShowingDoneArchive.toggle() }
                }
                AtomButton(
                    props: ButtonProps(style: "prominent", disabled: isCreatingNewTask, shortcut: AppShortcut.newTask),
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
    func lifecycleResetBanner(_ notice: String) -> some View {
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

    /// The archive's display model and actions; the board owns the loaded pages and the search.
    var doneArchivePanel: some View {
        let query = archiveSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let results = query.isEmpty ? archiveTasks : (archiveSearchResults ?? [])
        let isEmpty = results.isEmpty && (query.isEmpty ? !archiveHasMore && !isLoadingArchivePage : archiveSearchResults != nil) && !isIndexingArchive
        let model = DoneArchiveModel(
            search: archiveSearchText,
            rows: results.map { DoneArchiveModel.row($0, isCreatingPullRequests: taskCreatingPullRequests.contains($0.id)) },
            emptyMessage: isEmpty ? (query.isEmpty ? "No completed tasks" : "No matching tasks") : nil,
            loading: isLoadingArchivePage || isIndexingArchive,
            loadedCount: archiveTasks.count
        )
        return DoneArchivePanel(model: model, actions: DoneArchiveActions(
            close: closeDoneArchive,
            search: { archiveSearchText = $0 },
            open: { id in
                guard let task = results.first(where: { $0.id.uuidString == id }) else { return }
                selectedTask = task
                isSelectedTaskNew = false
                closeDoneArchive()
            },
            createPullRequests: { id in
                if let task = results.first(where: { $0.id.uuidString == id }) { createPullRequests(for: task) }
            },
            loadMore: { if query.isEmpty { loadNextArchivePage() } }
        ))
    }


    /// `Playhouse.props` for a main sidebar plugin: the standalone context plus `schedules`.
    func mainSidebarPluginProps(_ plugin: PluginRecord) -> [String: PluginValue] {
        let records = BoardTaskManager.scheduledTaskRecords(scheduledTasks)
        let schedules = PluginSchedulesContext(
            tasks: (try? BridgeValue.encoding(records)).map(PluginValue.init(bridge:))?.array ?? [],
            needsLoginItemsApproval: SchedulerAgent.requiresApproval
        )
        return PluginContext.props(plugin: plugin, appearance: appearance, task: nil, composer: nil, schedules: schedules)
    }

    var boardPluginActions: PluginUIActions {
        let confirmations = pluginConfirmations
        var actions = PluginUIActions(openTask: { id in
            if let task = try? BoardTaskManager(modelContext: modelContext).taskModel(id) {
                // A page stays up behind the task, so closing the task returns to it.
                if openBoardPlugin?.presentationKind != .page { openBoardPlugin = nil }
                isSelectedTaskNew = false
                conflictResolutionTaskID = nil
                presentScheduleOnOpen = nil
                selectedTask = task
            }
        })
        actions.confirm = { await confirmations.ask($0) }
        actions.newTask = { schedule in openNewTask(presentingSchedule: schedule) }
        actions.openLoginItems = { SMAppService.openSystemSettingsLoginItems() }
        return actions
    }

    /// What a task card's plugins can do: the board's actions, plus moving a
    /// card, opening it to resolve conflicts, and raising an alert.
    var taskItemPluginActions: PluginUIActions {
        var actions = boardPluginActions
        actions.close = { openTaskItemPlugin = nil }
        actions.moveTask = { id, status, merged in moveTask(id: id, to: status, skipMergeVerification: merged) }
        actions.resolveConflicts = { id in
            guard let task = tasks.first(where: { $0.id == id }) else { return }
            openTaskItemPlugin = nil
            conflictResolutionTaskID = id
            selectedTask = task
        }
        actions.alert = { title, message in pluginAlert = PluginAlert(title: title, message: message) }
        return actions
    }

    /// An Add Plugin mode placeholder was pressed: the new task's agent builds
    /// a plugin for that placement, and the mode ends.

    /// Each drag reveals only the target its source column can move to: Review
    /// cards get the Done target, Waiting Response cards the Review column.
    var draggedTaskStatus: TaskStatus? {
        draggedTaskID.flatMap { id in tasks.first(where: { $0.id == id })?.status }
    }


}

/// Where the session files the token map reads live, as this window's bridge
/// requests would name them.

struct RenameTaskSheet: View {
    @Environment(\.dismiss) var dismiss
    @State var title: String

    let onSave: (String) -> Void

    init(title: String, onSave: @escaping (String) -> Void) {
        _title = State(initialValue: title)
        self.onSave = onSave
    }

    var normalizedTitle: String {
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


extension Notification.Name {
    static let playhouseStartPluginCreation = Notification.Name("playhouseStartPluginCreation")
    static let playhouseEditPlugin = Notification.Name("playhouseEditPlugin")
    static let playhousePreparePluginDelete = Notification.Name("playhousePreparePluginDelete")
}

/// An alert a plugin raised with `ui.alert`.
struct PluginAlert: Equatable {
    let title: String
    let message: String
}

/// The error a confirmed task delete failed with, after its card came back to the board.
struct DeleteTaskErrorAlert: ViewModifier {
    @Binding var message: String?

    func body(content: Content) -> some View {
        content.alert("Couldn't delete task", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button("OK", role: .cancel) { message = nil }
            .buttonHoverPointer()
            .nativeHelp("Dismiss delete error")
            .accessibilityIdentifier("dismiss-delete-error-button")
        } message: {
            Text(message ?? "Please try again.")
        }
    }
}

struct PluginAlertModifier: ViewModifier {
    @Binding var alert: PluginAlert?

    func body(content: Content) -> some View {
        content.alert(alert?.title ?? "", isPresented: Binding(
            get: { alert != nil },
            set: { if !$0 { alert = nil } }
        )) {
            Button("OK", role: .cancel) { alert = nil }
                .buttonHoverPointer()
                .nativeHelp("Dismiss")
        } message: {
            Text(alert?.message ?? "")
        }
    }
}
