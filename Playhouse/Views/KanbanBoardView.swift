import Foundation
import PlayhouseAtoms
import PlayhouseCore
import PlayhouseUI

/// The standalone chat sidebar's width, which the user sets by dragging its right border.
package enum ChatSidebarLayout {
    package static let widthKey = "chatSidebarWidth"
    package static let defaultWidth: CGFloat = 460
    package static let minimumWidth: CGFloat = 320
    /// The board's own minimum width (see the board's `minWidth`).
    package static let minimumBoardWidth: CGFloat = 980
    /// The board's main sidebar, which the chat opens beside rather than over.
    package static let boardSidebarWidth: CGFloat = 216
    /// The chat's leading edge: just past the main sidebar and its 1-point border.
    package static let chatLeadingEdge: CGFloat = boardSidebarWidth + 1

    /// The window grows to fit the main sidebar, the chat and the board's minimum width, so the
    /// chat can widen only until that total reaches the screen, and never below its default width.
    package static func clampedWidth(_ width: CGFloat) -> CGFloat {
        let screenWidth = Platform.services.activeScreenVisibleFrame?.width ?? 0
        let maximum = max(defaultWidth, screenWidth - minimumBoardWidth - chatLeadingEdge)
        return min(max(width, minimumWidth), maximum)
    }
}

private struct SkillsPageWindowWidthKey: PHEnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension PHEnvironmentValues {
    /// The board's width beside the main sidebar, set on the standalone chat sidebar so the chat's
    /// Skills page covers the whole board from the chat's leading edge instead of only the chat.
    package var skillsPageWindowWidth: CGFloat? {
        get { self[SkillsPageWindowWidthKey.self] }
        set { self[SkillsPageWindowWidthKey.self] = newValue }
    }
}

/// A conversation whose Token Stats the window shows: all of it, or only one of its turns.
package struct TokenStatsTarget: Equatable {
    package let id: UUID
    package let title: String
    package var turnID: String?

    package init(id: UUID, title: String, turnID: String? = nil) {
        self.id = id
        self.title = title
        self.turnID = turnID
    }
}

/// Opens the window's Token Stats modal for a conversation. The board presents it over the
/// whole window, so a reply in the narrow chat sidebar can open it without clipping it.
/// Always equal, like SwiftUI's own actions: the board makes a new one each time its body
/// runs, and a change would re-render the whole chat behind its `.equatable()` boundary.
package struct ShowTokenStatsAction: Equatable {
    package let open: (TokenStatsTarget) -> Void
    package func callAsFunction(_ target: TokenStatsTarget) { open(target) }
    package static func == (lhs: Self, rhs: Self) -> Bool { true }

    package init(open: @escaping (TokenStatsTarget) -> Void) {
        self.open = open
    }
}

private struct ShowTokenStatsKey: PHEnvironmentKey {
    static let defaultValue: ShowTokenStatsAction? = nil
}

extension PHEnvironmentValues {
    /// Set on the standalone chat sidebar; nil where no window-wide Token Stats modal exists.
    package var showTokenStats: ShowTokenStatsAction? {
        get { self[ShowTokenStatsKey.self] }
        set { self[ShowTokenStatsKey.self] = newValue }
    }
}

/// Lays out a conversation's Skills page `skillsPageWindowWidth` wide when set. It reads that
/// value itself, so a window resize re-renders only this frame rather than the whole conversation.
package struct SkillsPageWindowFrame<Content: PHView>: PHView {
    @PHEnvironment(\.skillsPageWindowWidth) private var width
    @PHViewBuilder package let content: Content

    package var body: some PHView {
        AtomStack(common: AtomCommon(width: width.map { Double($0) })) { content }
    }

    package init(@PHViewBuilder content: () -> Content) {
        self.content = content()
    }
}

/// Whether a conversation's Skills page is open, so the chat sidebar stops clipping it to its
/// own width and hides its resize edge while the page covers the window.
package struct SkillsPageShowingKey: PHPreferenceKey {
    package static let defaultValue = false
    package static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }

    package init() {}
}

/// Clips the chat sidebar to its own width from its leading edge, or, while its Skills page is
/// open, to the given wider width so the page reaches across the board beside the main sidebar.
private struct ChatSidebarClip: PHShape {
    var width: CGFloat?

    func path(in rect: CGRect) -> PHPath {
        PHPath(CGRect(x: rect.minX, y: rect.minY, width: width ?? rect.width, height: rect.height))
    }
}

/// A standalone chat's conversation: the chat sidebar's, or a plugin editor's. The board re-renders
/// on every frame of a chat resize and on every runtime change of any task, and a conversation view
/// rebuilt from it, closures and all, re-ran its whole transcript each time; compared by the chat it
/// shows, it updates only from its own state and the chat's model. Any input added here that can
/// change must also be compared in `==`, or its changes are ignored. The closures only reach the
/// board's state storage, so an older copy of them stays valid.
package struct StandaloneChatPanel: PHView, Equatable {
    package let chat: StandaloneChat
    /// A new plugin editor's starting prompt.
    package var initialDraft: String? = nil
    package let onOpenTask: (UUID, String) -> Void
    package let onClose: () -> Void

    package static func == (lhs: StandaloneChatPanel, rhs: StandaloneChatPanel) -> Bool {
        lhs.chat === rhs.chat && lhs.initialDraft == rhs.initialDraft
    }

    package var body: some PHView {
        TaskConversationView(
            task: chat, isNewTask: false,
            initialDraft: initialDraft,
            onOpenTask: onOpenTask,
            onBack: onClose
        )
    }

    package init(chat: StandaloneChat, initialDraft: String? = nil, onOpenTask: @escaping (UUID, String) -> Void, onClose: @escaping () -> Void) {
        self.chat = chat
        self.initialDraft = initialDraft
        self.onOpenTask = onOpenTask
        self.onClose = onClose
    }
}

/// An open task's conversation. The board re-renders whenever any task's runtime state changes,
/// and a conversation view rebuilt from it, closures and all, re-ran its whole transcript each
/// time; compared by its inputs, it updates only from its own state and the task's model. Any
/// input added here that can change must also be compared in `==`. The closures only reach the
/// board's state storage, so an older copy of them stays valid.
package struct TaskConversationPanel: PHView, Equatable {
    package let task: BoardTask
    package let isNewTask: Bool
    package let skillFixPrompt: String?
    package let presentScheduleOnAppear: TaskScheduleKind?
    package let onOpenTask: (UUID, String) -> Void
    package let onBack: () -> Void

    package static func == (lhs: TaskConversationPanel, rhs: TaskConversationPanel) -> Bool {
        lhs.task === rhs.task && lhs.isNewTask == rhs.isNewTask
            && lhs.skillFixPrompt == rhs.skillFixPrompt
            && lhs.presentScheduleOnAppear == rhs.presentScheduleOnAppear
    }

    package var body: some PHView {
        TaskConversationView(
            task: task, isNewTask: isNewTask,
            skillFixPrompt: skillFixPrompt,
            onOpenTask: onOpenTask,
            presentScheduleOnAppear: presentScheduleOnAppear,
            onBack: onBack
        )
    }

    package init(task: BoardTask, isNewTask: Bool, skillFixPrompt: String?, presentScheduleOnAppear: TaskScheduleKind?, onOpenTask: @escaping (UUID, String) -> Void, onBack: @escaping () -> Void) {
        self.task = task
        self.isNewTask = isNewTask
        self.skillFixPrompt = skillFixPrompt
        self.presentScheduleOnAppear = presentScheduleOnAppear
        self.onOpenTask = onOpenTask
        self.onBack = onBack
    }
}

package struct KanbanBoardView: PHView {
    package let boardSidebarWidth = ChatSidebarLayout.boardSidebarWidth
    @PHAppStorage(ChatSidebarLayout.widthKey, store: WorkspaceSettings.preferencesStore)
    package var storedChatSidebarWidth = Double(ChatSidebarLayout.defaultWidth)
    @PHState package var chatSidebarResizeStartWidth: CGFloat?
    /// The width while a drag is under way; it is saved to the preferences only when the drag ends.
    @PHState package var chatSidebarDragWidth: CGFloat?
    /// The width the chat was last laid out at during a drag. Laying out every reply again on each
    /// frame of the drag made it stutter, so the chat catches up only when the edge pauses, and
    /// when the drag ends.
    @PHState package var chatSidebarReflowWidth: CGFloat?
    /// How far the chat's open page labels widen the sidebar beyond its set width, pushing the board aside.
    @PHState package var chatPageAnchorsPush: CGFloat = 0

    package var chatSidebarWidth: CGFloat {
        chatSidebarDragWidth ?? ChatSidebarLayout.clampedWidth(CGFloat(storedChatSidebarWidth))
    }
    /// The chat sidebar's width on screen: its set width and the room its open page labels take.
    package var chatSidebarShownWidth: CGFloat { chatSidebarWidth + chatPageAnchorsPush }

    @PHEnvironment(\.modelContext) package var modelContext
    @PHEnvironment(PluginRegistry.self) package var pluginRegistry
    @PHEnvironment(ConversationRuntimeModel.self) package var conversationRuntime
    @PHState private var activeTasksQuery = ModelQuery<BoardTask>(ModelFetch(.notEquals("statusRawValue", TaskStatus.done.rawValue), sortBy: [("createdAt", false)]))
    package var allTasks: [BoardTask] { activeTasksQuery.results(in: modelContext) }
    /// Board cards. Recurring schedule templates aren't board tasks; the Scheduled Tasks popover
    /// lists them, and each of their runs appears here as its own task.
    package var tasks: [BoardTask] { allTasks.filter { !$0.isRecurringScheduleTemplate && !deletingTaskIDs.contains($0.id) } }
    /// Every scheduled task, soonest first, as `schedule.list` lists them for
    /// the main sidebar's `props.schedules`.
    @PHState private var scheduledTasksQuery = ModelQuery<BoardTask>(ModelFetch(.isNotNull("scheduleKindRawValue")))
    package var scheduledTasks: [BoardTask] { scheduledTasksQuery.results(in: modelContext) }
    /// Opens the next new task with the schedule hint already showing, set to this kind.
    @PHState package var presentScheduleOnOpen: TaskScheduleKind?
    @PHState package var isCreatingNewTask = false
    @PHState package var saveError: String?
    @PHState package var lifecycleResetNotice: String?
    @PHState package var draggedTaskID: UUID?
    @PHState package var selectedTask: BoardTask?
    @PHState package var isSelectedTaskNew = false
    @PHState package var taskBeingRenamed: BoardTask?
    @PHState package var taskShowingTokenStats: TokenStatsTarget?
    @PHState package var taskBeingDeleted: BoardTask?
    /// Tasks whose confirmed delete is still running in the daemon. Their cards leave the board
    /// at once, and come back only when the delete fails.
    @PHState package var deletingTaskIDs: Set<UUID> = []
    @PHState package var deleteError: String?
    @PHState package var isShowingDeleteConfirmation = false
    @PHState package var isDoneTargetActive = false
    @PHState package var isShowingDoneArchive = false
    @PHState package var archiveSearchText = ""
    @PHState package var isIndexingArchive = false
    @PHState package var archiveSearchResults: [BoardTask]?
    @PHState package var archiveTasks: [BoardTask] = []
    @PHState package var archiveOffset = 0
    @PHState package var archiveHasMore = true
    @PHState package var isLoadingArchivePage = false
    @PHState package var taskCreatingPullRequests = Set<UUID>()
    /// Prompts that tasks opened by the Skills page's Fix with Agent send when they appear.
    @PHState package var skillFixPrompts: [UUID: String] = [:]
    @PHState package var taskAwaitingUnmergedConfirmation: UUID?
    @PHState package var taskAwaitingDiscardConfirmation: UUID?
    @PHState package var discardConfirmationMessage = ""
    @PHState package var pullRequestError: String?
    /// An alert a task card's plugin raised with `ui.alert`.
    @PHState package var pluginAlert: PluginAlert?
    @PHState package var pluginConfirmations = PluginConfirmations()
    /// A modal, sidebar or page plugin opened from a task card, and that card's task.
    @PHState package var openTaskItemPlugin: PluginRecord?
    @PHState package var openTaskItemPluginTask: BoardTask?
    @PHState package var doneMoveError: String?
    @PHState package var reviewMoveError: String?
    @PHState package var isShowingBoardSearch = false
    @PHState package var boardSearchText = ""
    /// Bumped to focus the board search field (the Search Tasks command).
    @PHState package var boardSearchFocusRequest = 0
    @PHState package var isShowingChatSidebar = false
    @PHState package var chatTask: StandaloneChat?
    /// The chat's open parallel bubbles, oldest first, and the one opened into its larger view.
    @PHState package var parallelBubbles: [StandaloneChat] = []
    @PHState package var openParallelBubbleID: UUID?
    @PHState package var pluginChat: StandaloneChat?
    @PHState package var showPluginDraftNotice = false
    @PHState package var pluginInitialDraft: String?
    @PHState package var isOpeningChatSidebar = false
    /// The chat's Skills page is open and covers the whole board, laid out `boardContentWidth` wide.
    @PHState package var isChatSkillsPageShowing = false
    @PHState package var boardContentWidth: CGFloat = 0
    /// Where the board's sidebar and columns start, below the header and its divider.
    @PHState package var boardBodyTop: CGFloat = 0
    /// A modal, sidebar or page plugin opened from the board's sidebar.
    @PHState package var openBoardPlugin: PluginRecord?
    @PHState package var pluginSetupPlacement: PluginPlacement?
    @PHState package var isStartingPluginTask = false
    @PHAppStorage(WorkspaceSettings.appearanceKey, store: WorkspaceSettings.preferencesStore) package var appearance = "dark"

    /// Provider-owning operations run in the bridge daemon.
    package var remoteConversations: RemoteConversationManager {
        RemoteConversationManager(daemon: conversationRuntime.client, runtime: conversationRuntime, modelContext: modelContext)
    }

    package var isChatOverlayVisible: Bool {
        isShowingChatSidebar && selectedTask == nil && chatTask != nil
    }

    package var body: some PHView {
        mainContent
    }

    package func conversationView(for selectedTask: BoardTask) -> some PHView {
        TaskConversationPanel(
            task: selectedTask, isNewTask: isSelectedTaskNew,
            skillFixPrompt: skillFixPrompts[selectedTask.id],
            presentScheduleOnAppear: presentScheduleOnOpen,
            onOpenTask: openTask(_:sending:)
        ) {
            self.skillFixPrompts[selectedTask.id] = nil
            self.selectedTask = nil
            self.isSelectedTaskNew = false
            self.presentScheduleOnOpen = nil
        }
        .equatable()
        .id(selectedTask.id)
    }

    /// The first part of `mainContent`'s modifier chain, split off so the type checker handles each part in time.
    private var boardBase: some PHView {
        // The open chat adds its width and the main sidebar's to the board's minimum, so the
        // content-sized window grows to keep the pushed columns visible beside them.
        AtomStack(
            props: StackProps(fill: "window"),
            common: AtomCommon(minWidth: Double(ChatSidebarLayout.minimumBoardWidth + (isChatOverlayVisible ? ChatSidebarLayout.chatLeadingEdge + chatSidebarWidth : 0)), minHeight: 640)
        ) {
            boardPage
        }
        .task(id: allTasks.contains { $0.scheduleKind != nil && !$0.schedulePaused }) {
            SchedulerAgent.sync(hasActiveSchedules: allTasks.contains { $0.scheduleKind != nil && !$0.schedulePaused })
        }
        .onAppear {
            // The board renders from its own query, not the board.list path, so it has to
            // convert a chat still stored as a hidden task itself or that row shows as a card.
            try? BoardTaskManager(modelContext: modelContext).migrateLegacyStandaloneChatTasks()
            let retained = PlayhouseStore.takeLifecycleResetNotice(
                dataDirectory: ProcessInfo.processInfo.environment["PLAYHOUSE_DATA_DIRECTORY"]
            )
            if !retained.isEmpty {
                lifecycleResetNotice = "Existing tasks were cleared. These dirty managed worktrees were kept:\n\n" + retained.joined(separator: "\n")
            }
        }
        .onNotification(.playhouseStartPluginCreation) { notification in
            guard let placement = notification.object as? PluginPlacement else { return }
            PluginRegistry.setAddMode(false)
            phWithAnimation(.easeInOut(duration: 0.25)) { pluginSetupPlacement = placement }
        }
        .onNotification(.playhouseEditPlugin) { notification in
            guard let id = notification.object as? UUID else { return }
            openPluginConversation(id, draft: nil)
        }
        .onNotification(.playhousePreparePluginDelete) { notification in
            guard let id = notification.object as? UUID else { return }
            if pluginChat?.id == id { pluginChat = nil; pluginInitialDraft = nil }
        }
        .onNotification(.playhouseShowBoardSearch) { _ in
            phWithAnimation(.easeInOut(duration: 0.18)) { isShowingBoardSearch = true }
            boardSearchFocusRequest += 1
        }
        .phOnAppActivation {
            // The built-in plugins' daemon services hear the focus too.
            PluginServiceHost.publish(PluginEvent(name: PluginEvent.appFocus))
        }
        .task {
            // And the launch, once.
            if PluginLaunch.claim("#services") { PluginServiceHost.publish(PluginEvent(name: PluginEvent.appLaunched)) }
        }
    }

    /// The page the board shows: a plugin's setup or editor, an open task, or the board itself.
    private var boardPage: some PHView {
        PHGroup {
            if let placement = pluginSetupPlacement {
                PluginCreationSetup(placement: placement, isStarting: isStartingPluginTask, onCancel: {
                    pluginSetupPlacement = nil
                }, onStart: { name, presentation in
                    finishPluginSetup(placement, name: name, presentation: presentation)
                })
            } else if let pluginChat, let pluginID = pluginChat.authoredPluginID {
                AtomStack(props: StackProps(axis: "h", spacing: 0)) {
                    AtomStack(common: AtomCommon(fillWidth: true, fillHeight: true, frameAlign: "center")) {
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
                    }
                    AtomDivider()
                    AtomStack(common: AtomCommon(fillWidth: true, fillHeight: true, frameAlign: "center")) {
                        PluginAuthoringPreview(task: pluginChat, pluginID: pluginID, onClose: {
                            self.pluginChat = nil; pluginInitialDraft = nil
                        })
                    }
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
            PHButton("OK") { pluginChat = nil; pluginInitialDraft = nil }
                .buttonHoverPointer().nativeHelp("Close plugin editor")
        } message: { PHText("Your changes are saved as a draft. You can return and continue editing later.") } // ATOM-GAP: no alert atom (system alert actions and message)
    }

    package var mainContent: some PHView {
        boardBase
        .sheet(isPresented: PHBinding(
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
                TokenStatsSheet(
                    taskID: taskShowingTokenStats.id, taskTitle: taskShowingTokenStats.title,
                    turnID: taskShowingTokenStats.turnID, modelContext: modelContext
                )
            }
        }
        .confirmationDialog(
            "Delete this task?",
            isPresented: $isShowingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            PHButton("Delete Task", role: .destructive) {
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
            PHButton("Cancel", role: .cancel) {
                taskBeingDeleted = nil
            }
            .buttonHoverPointer()
            .nativeHelp("Cancel task deletion")
            .accessibilityIdentifier("cancel-delete-task-button")
        } message: {
            PHText("The task conversation and saved working folders will also be deleted.")
        }
        .alert("Pull request operation failed", isPresented: PHBinding(
            get: { pullRequestError != nil },
            set: { if !$0 { pullRequestError = nil } }
        )) {
            PHButton("OK", role: .cancel) { pullRequestError = nil }
            .buttonHoverPointer()
            .nativeHelp("Dismiss pull request error")
        } message: {
            PHText(pullRequestError ?? "Please try again.")
        }
        .alert("Couldn't move task to Done", isPresented: PHBinding(
            get: { doneMoveError != nil },
            set: { if !$0 { doneMoveError = nil } }
        )) {
            PHButton("OK", role: .cancel) { doneMoveError = nil }
            .buttonHoverPointer()
            .nativeHelp("Dismiss move to Done error")
        } message: {
            PHText(doneMoveError ?? "Please try again.")
        }
        .alert("Couldn't move task to Review", isPresented: PHBinding(
            get: { reviewMoveError != nil },
            set: { if !$0 { reviewMoveError = nil } }
        )) {
            PHButton("OK", role: .cancel) { reviewMoveError = nil }
            .buttonHoverPointer()
            .nativeHelp("Dismiss Review move error")
        } message: {
            PHText(reviewMoveError ?? "Please try again.")
        }
        .confirmationDialog(
            "This task has an unmerged pull request",
            isPresented: PHBinding(
                get: { taskAwaitingUnmergedConfirmation != nil },
                set: { if !$0 { taskAwaitingUnmergedConfirmation = nil } }
            ),
            titleVisibility: .visible
        ) {
            PHButton("Mark Done Anyway", role: .destructive) {
                guard let id = taskAwaitingUnmergedConfirmation else { return }
                taskAwaitingUnmergedConfirmation = nil
                moveTask(id: id, to: .done, allowUnmergedPullRequests: true)
            }
            .buttonHoverPointer()
            .nativeHelp("Mark Done Anyway")
            PHButton("Cancel", role: .cancel) { taskAwaitingUnmergedConfirmation = nil }
            .buttonHoverPointer()
            .nativeHelp("Cancel marking this task Done")
        } message: {
            PHText("The pull request hasn't been merged. Marking this task Done removes its worktree and keeps its branch.")
        }
        .confirmationDialog(
            "Discard uncommitted changes?",
            isPresented: PHBinding(
                get: { taskAwaitingDiscardConfirmation != nil },
                set: { if !$0 { taskAwaitingDiscardConfirmation = nil } }
            ),
            titleVisibility: .visible
        ) {
            PHButton("Discard Changes and Mark Done", role: .destructive) {
                guard let id = taskAwaitingDiscardConfirmation else { return }
                taskAwaitingDiscardConfirmation = nil
                moveTask(id: id, to: .done, allowUnmergedPullRequests: true, allowDiscardingUncommittedChanges: true)
            }
            .buttonHoverPointer()
            .nativeHelp("Discard uncommitted changes and mark this task Done")
            .accessibilityIdentifier("discard-changes-confirm-button")
            PHButton("Cancel", role: .cancel) { taskAwaitingDiscardConfirmation = nil }
            .buttonHoverPointer()
            .nativeHelp("Keep the worktree and leave this task in Review")
            .accessibilityIdentifier("discard-changes-cancel-button")
        } message: {
            PHText(discardConfirmationMessage)
        }
        .alert("Some task worktrees were kept", isPresented: PHBinding(
            get: { lifecycleResetNotice != nil },
            set: { if !$0 { lifecycleResetNotice = nil } }
        )) {
            PHButton("OK", role: .cancel) { lifecycleResetNotice = nil }
                .buttonHoverPointer()
                .nativeHelp("Dismiss worktree notice")
        } message: {
            PHText(lifecycleResetNotice ?? "")
        }
        .alert("Couldn't save changes", isPresented: isShowingSaveError) {
            PHButton("OK", role: .cancel) {
                saveError = nil
            }
            .buttonHoverPointer()
            .nativeHelp("Dismiss save error")
        } message: {
            PHText(saveError ?? "Please try again.")
        }
    }

    package var boardContent: some PHView {
        // The host of the card plugins' presentations and alerts sits behind the board, at its size.
        AtomStack(props: StackProps(axis: "z")) {
            AtomStack(common: AtomCommon(fillWidth: true, fillHeight: true)) {
                PHEmptyView()
            }
            .pluginPresentation(
                $openTaskItemPlugin,
                props: { PluginContext.props(plugin: $0, appearance: appearance, task: openTaskItemPluginTask.map { PluginTaskContext(task: $0) }, composer: nil) },
                actions: taskItemPluginActions
            )
            .modifier(PluginAlertModifier(alert: $pluginAlert))
            .modifier(PluginConfirmationModifier(confirmations: pluginConfirmations))

            boardLayers
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

    /// The board's header, sidebar and columns, with the chat, its bubbles and the search bar over
    /// them, and the archive and main sidebar plugins presented over all of it.
    private var boardLayers: some PHView {
        AtomStack(props: StackProps(axis: "z", align: "topLeading"), common: AtomCommon(fillWidth: true, fillHeight: true, frameAlign: "topLeading")) {
            // Measured only while the chat is open, so resizing the window without it doesn't re-run the board.
            if isShowingChatSidebar {
                AtomStack(common: AtomCommon(fillWidth: true, fillHeight: true)) {
                    PHEmptyView()
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { boardContentWidth = $0 }
            }

            AtomStack(props: StackProps(spacing: 0)) {
                AtomStack(props: StackProps(spacing: 0)) {
                    boardHeader

                    AtomStack(props: StackProps(fill: "primary", fillOpacity: 0.07), common: AtomCommon(height: 1, fillWidth: true)) {
                        PHEmptyView()
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { boardBodyTop = $0 }

                AtomStack(props: StackProps(axis: "h", spacing: 0)) {
                    boardSidebar

                    AtomStack(props: StackProps(fill: "primary", fillOpacity: 0.07), common: AtomCommon(width: 1, fillHeight: true)) {
                        PHEmptyView()
                    }

                    if isChatOverlayVisible {
                        AtomStack(common: AtomCommon(width: Double(chatSidebarShownWidth), fillHeight: true, decorative: true)) {
                            PHEmptyView()
                        }
                    }

                    AtomStack(props: StackProps(spacing: 0)) {
                        if let lifecycleResetNotice {
                            lifecycleResetBanner(lifecycleResetNotice)
                        }

                        AtomStack(props: StackProps(axis: "h", spacing: 0)) {
                            // The board pins its columns to the top, just under the header, centers them
                            // across its width with its own viewport-sized frame, and keeps the scroll
                            // view's clip origin at zero. Left to itself, the two-axis scroll view centers
                            // narrower content by giving AppKit's clip view a negative bounds origin, and
                            // after a horizontal scroll nudge followed by a content-height change, SwiftUI's
                            // hit testing lost that offset: the board drew centered while clicks resolved as
                            // if it were flush left, so buttons stopped responding until the window was resized.
                            // The board's scrollers always float over the content (see HoverRevealScrollers),
                            // so the visible area is the reader's full frame.
                            PHGeometryReader { viewport in
                                // The drawer floats over the scroll view's trailing edge rather than
                                // beside it, so the vertical scroller sits at the window edge with the
                                // drawer to its left, and the drawer stays put while scrolling.
                                AtomStack(props: StackProps(axis: "z", align: "trailing", fill: "window")) {
                                    AtomScroll(props: ScrollProps(axis: "both")) {
                                        boardColumns(viewport: viewport.size)
                                    }
                                    .modifier(TopLeadingScrollAlignment())
                                    .scrollContentBackground(.hidden)
                                    .accessibilityIdentifier("board-columns-scroll-view")

                                    AtomStack(common: AtomCommon(paddingTrailing: Double(HoverRevealScrollers.scrollerWidth))) {
                                        DoneDropDrawer(
                                            isOpen: draggedTaskStatus.map(TaskStatus.manualDoneSources.contains) ?? false,
                                            isActive: $isDoneTargetActive,
                                            onDrop: { moveTask(id: $0, to: .done) }
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // The chat opens beside the board sidebar, aligned with its top under the header, and
            // slides out from the sidebar's edge rather than over the sidebar or the header.
            AtomStack(common: AtomCommon(paddingTop: Double(boardBodyTop), paddingLeading: Double(ChatSidebarLayout.chatLeadingEdge))) {
                AtomStack(props: StackProps(align: "leading", clip: true), common: AtomCommon(fillWidth: true, fillHeight: true, frameAlign: "topLeading")) {
                    standaloneChatOverlay
                }
            }

            // Bubbles float from the chat's right edge, below the header.
            AtomStack(common: AtomCommon(paddingTop: Double(boardBodyTop))) {
                parallelChatBubblesOverlay
            }

            // The search bar floats over the board's top trailing corner.
            AtomStack(common: AtomCommon(fillWidth: true, fillHeight: true, frameAlign: "topTrailing")) {
                if isShowingBoardSearch {
                    AtomStack(common: AtomCommon(paddingTop: 16, paddingTrailing: 20)) {
                        AtomStack(common: AtomCommon(width: 360)) {
                            boardSearchBar
                        }
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .zIndex(2)
        }
        .animation(.easeInOut(duration: 0.22), value: isShowingChatSidebar)
        .task(id: draggedTaskID) {
            // SwiftUI reports no end for a drag that lands outside every drop target (for
            // example a card dropped back in place), and the drag session consumes the
            // mouse-up, so watch the button itself. The grace period lets a real drop finish
            // against the open drawer before it closes.
            guard draggedTaskID != nil else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(120))
                guard !Platform.services.isPrimaryMouseButtonDown else { continue }
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                if !Platform.services.isPrimaryMouseButtonDown {
                    draggedTaskID = nil
                    isDoneTargetActive = false
                    return
                }
            }
        }
        // The SidePanel atom below keeps a platform view behind the board, without which
        // accessibility hit tests over the opened Done archive resolve to the board's scroll
        // view underneath (see `PHAccessibilityHitTestAnchor`).
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
    }

    /// The columns, pinned to the top of the board's scroll view and centered across the viewport.
    /// The outer layer is surfaced (an unclipped surface) only so its minimum frame places the
    /// columns at the top, as the viewport-sized frame did.
    private func boardColumns(viewport: CGSize) -> some PHView {
        AtomStack(
            props: StackProps(axis: "z", align: "top", clip: false),
            common: AtomCommon(minWidth: Double(viewport.width), minHeight: Double(viewport.height))
        ) {
            boardColumnRow
        }
        .hoverRevealScrollers()
    }

    private var boardColumnRow: some PHView {
        AtomStack(props: StackProps(axis: "h", spacing: 0, align: "top"), common: AtomCommon(paddingTop: 22, paddingBottom: 28)) {
            AtomSpacer(props: SpacerProps(minLength: 30))
            AtomStack(props: StackProps(axis: "h", spacing: 16, align: "top"), common: AtomCommon(fixedSize: true)) {
                PHForEach(TaskStatus.allCases.filter { $0 != .blocked && $0 != .waitingResponse && $0 != .done }) { status in
                    if status == .backlog {
                        let hasBlockedTasks = tasks.contains(where: { $0.status == .blocked })
                        AtomStack(props: StackProps(spacing: 12), common: AtomCommon(width: 264)) {
                            if hasBlockedTasks {
                                kanbanColumn(.blocked, minHeight: 220)
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                            kanbanColumn(.backlog, minHeight: hasBlockedTasks ? 220 : 480)
                        }
                        .animation(.easeInOut(duration: 0.2), value: hasBlockedTasks)
                    } else if status == .inProgress {
                        let hasWaitingResponseTasks = tasks.contains(where: { $0.status == .waitingResponse })
                        AtomStack(props: StackProps(spacing: 12), common: AtomCommon(width: 264)) {
                            if hasWaitingResponseTasks {
                                kanbanColumn(.waitingResponse, minHeight: 220)
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                            kanbanColumn(.inProgress, minHeight: hasWaitingResponseTasks ? 220 : 480)
                        }
                        .animation(.easeInOut(duration: 0.2), value: hasWaitingResponseTasks)
                    } else {
                        kanbanColumn(status)
                    }
                }
            }
            // The trailing spacer also leaves room for the Done drawer, so the last
            // column scrolls clear of it. The spacers split spare width evenly, so the
            // columns center in the whole board once it is wide enough for both minimums.
            AtomSpacer(props: SpacerProps(minLength: 30 + Double(DoneDropDrawer.gutterWidth)))
        }
    }

    /// The width the chat's Skills page covers: the board from the sidebar's edge to the window's.
    package var chatSkillsPageWidth: CGFloat? {
        boardContentWidth > 0 ? max(0, boardContentWidth - ChatSidebarLayout.chatLeadingEdge) : nil
    }

    /// The board sidebar's Chat entry, drawn like the plugin entries below it: it shows the
    /// standalone chat beside the sidebar, and shows as selected while the chat is open, when
    /// pressing it again hides the chat.
    package var chatSidebarEntry: some PHView {
        AtomButton(
            props: ButtonProps(disabled: isOpeningChatSidebar, shortcut: AppShortcut.chat),
            common: AtomCommon(testID: "chat-sidebar-button", label: "Chat", help: isChatOverlayVisible ? "Hide the standalone chat" : "Open the standalone chat", fillWidth: true),
            action: openChatSidebar
        ) {
            AtomStack(props: StackProps(align: "leading", fill: "accent", fillOpacity: isChatOverlayVisible ? 0.14 : 0, cornerRadius: 8), common: AtomCommon(fillWidth: true, paddingX: 12, paddingY: 9)) {
                AtomLabel(props: LabelProps(text: "Chat", icon: PHIcon.bubbleLeftAndBubbleRight.name, size: 12, weight: "medium"))
            }
        }
        .accessibilityValue(isChatOverlayVisible ? "Shown" : "Hidden")
    }

    package var standaloneChatOverlay: some PHView {
        PHGroup {
            if isShowingChatSidebar, selectedTask == nil, let chatTask {
                // The Overlay is the accessibility container the identifier needs: without one,
                // it replaces the conversation controls' own.
                AtomOverlay(props: OverlayProps(align: "trailing"), common: AtomCommon(testID: "chat-sidebar")) {
                    AtomStack(props: StackProps(align: "leading"), common: AtomCommon(fillHeight: true, frameAlign: "topLeading")) {
                        // While the edge moves, the chat keeps the width it was last laid out at, and the panel
                        // clips or reveals the rest; it reflows when the edge rests and when the drag ends.
                        AtomStack(props: StackProps(align: "leading", fill: "window"), common: AtomCommon(width: Double(chatSidebarShownWidth), frameAlign: "leading")) {
                            AtomStack(common: AtomCommon(width: Double((chatSidebarReflowWidth ?? chatSidebarWidth) + chatPageAnchorsPush))) {
                                standaloneChatPanel(chatTask)
                            }
                        }
                        .clipShape(ChatSidebarClip(width: isChatSkillsPageShowing ? chatSkillsPageWidth : nil)) // ATOM-GAP: no clip to a rect wider than the view (StackProps clip uses the view's own shape)
                        .task(id: chatSidebarDragWidth) {
                            // Each move restarts this wait, so the chat reflows once the edge rests.
                            guard let chatSidebarDragWidth else { return }
                            try? await Task.sleep(for: .milliseconds(150))
                            guard !Task.isCancelled else { return }
                            chatSidebarReflowWidth = chatSidebarDragWidth
                        }
                    }
                } overlay: {
                    if !isChatSkillsPageShowing {
                        chatSidebarResizeHandle(width: chatSidebarWidth)
                    }
                }
                .transition(.move(edge: .leading).combined(with: .opacity))
                .id(chatTask.id)
            }
        }
    }

    private func standaloneChatPanel(_ chatTask: StandaloneChat) -> some PHView {
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
            phWithAnimation(ChatPageAnchorsLayout.slideAnimation) { chatPageAnchorsPush = push }
        }
        // Opening a task from the page removes the chat without a closing preference change.
        .onDisappear {
            isChatSkillsPageShowing = false
            chatPageAnchorsPush = 0
        }
        .environment(\.chatPageAnchorsPush, chatPageAnchorsPush)
    }

    package func kanbanColumn(_ status: TaskStatus, minHeight: CGFloat = 480) -> some PHView {
        AtomStack(common: AtomCommon(width: 264, minHeight: Double(minHeight))) {
            kanbanColumnView(status, minHeight: minHeight)
        }
    }

    private func kanbanColumnView(_ status: TaskStatus, minHeight: CGFloat) -> some PHView {
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
    }

    package var boardSearchBar: some PHView {
        AtomStack(
            props: StackProps(
                axis: "h", spacing: 9, group: true, cornerRadius: 12, stroke: "primary", strokeOpacity: 0.12, strokeWidth: 1,
                material: "regular", shadow: 10, shadowOpacity: 0.10, shadowY: 3
            ),
            common: AtomCommon(testID: "board-search-bar", paddingX: 13, paddingY: 9)
        ) {
            AtomIcon(props: IconProps(name: PHIcon.magnifyingglass.name, size: 14, weight: "medium", color: "themeAccent"))
            AtomTextField(
                props: TextFieldProps(text: boardSearchText, placeholder: "Search tasks", autoFocus: true, style: "plain", size: 14, focusRequest: boardSearchFocusRequest),
                common: AtomCommon(testID: "board-search-field"),
                onChange: { boardSearchText = $0 },
                onEscape: closeBoardSearch
            )
            if !boardSearchText.isEmpty {
                AtomText(
                    props: TextProps(text: "\(tasks.filter { $0.status != .done && $0.title.localizedCaseInsensitiveContains(boardSearchText.trimmingCharacters(in: .whitespacesAndNewlines)) }.count) matches", size: 11, weight: "medium", color: "secondary"),
                    common: AtomCommon(testID: "board-search-match-count")
                )
                AtomButton(common: AtomCommon(testID: "clear-board-search-button", help: "Clear search"), action: { boardSearchText = "" }) {
                    AtomIcon(props: IconProps(name: PHIcon.xmarkCircleFill.name, size: 12, color: "secondary"))
                }
            }
            AtomButton(common: AtomCommon(testID: "close-board-search-button", label: "Close search", help: "Close search"), action: closeBoardSearch) {
                AtomIcon(props: IconProps(name: PHIcon.xmark.name, size: 11, weight: "semibold", color: "secondary"), common: AtomCommon(width: 22, height: 22))
            }
        }
    }

    private func closeBoardSearch() {
        boardSearchText = ""
        phWithAnimation(.easeInOut(duration: 0.18)) { isShowingBoardSearch = false }
    }

    package var runningTaskCountByProvider: [ConversationProvider: Int] {
        tasks.filter { $0.status == .inProgress }.reduce(into: [:]) { $0[$1.conversationProvider, default: 0] += 1 }
    }

    package var boardSidebar: some PHView {
        AtomStack(
            props: StackProps(spacing: 12, align: "leading", group: true, fill: "panel", fillOpacity: 0.62),
            common: AtomCommon(label: "Kanban sidebar", width: Double(boardSidebarWidth), fillHeight: true, paddingX: 12, paddingY: 12)
        ) {
            // Spaced like the plugin entries, so Chat reads as the first of them.
            AtomStack(props: StackProps(spacing: 6, align: "leading")) {
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

            AtomSpacer(props: SpacerProps(minLength: 0))

            BoardSidebarBottomSlot(runningProviders: runningTaskCountByProvider, appearance: appearance, actions: boardPluginActions, add: startPluginTask)
        }
    }

    /// The board's header, composed only of plugin atoms (Plugins/Atoms). The
    /// New Task button takes the window's tint (`WorkspaceTheme.accent`).
    package var boardHeader: some PHView {
        AtomStack(props: StackProps(axis: "h", spacing: 24, group: true), common: AtomCommon(label: "Kanban header", paddingX: 30, paddingTop: 24, paddingBottom: 21)) {
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
                    phWithAnimation(.easeInOut(duration: 0.24)) { isShowingDoneArchive.toggle() }
                }
                AtomButton(
                    props: ButtonProps(style: "prominent", disabled: isCreatingNewTask, shortcut: AppShortcut.newTask),
                    common: AtomCommon(testID: "new-task-button", help: "Create a new task", paddingX: 7, paddingY: 3),
                    action: openNewTask
                ) {
                    AtomLabel(props: LabelProps(text: "New Task", icon: PHIcon.plus.name, size: 13, weight: "semibold"))
                }
            }
        }
    }

    /// The notice that some task worktrees were kept, composed only of plugin atoms (Plugins/Atoms).
    package func lifecycleResetBanner(_ notice: String) -> some PHView {
        AtomPanel(
            props: PanelProps(fill: "panel", fillOpacity: 1, cornerRadius: 0),
            common: AtomCommon(testID: "task-lifecycle-reset-notice", fillWidth: true, padding: 12, paddingX: 6)
        ) {
            AtomStack(props: StackProps(axis: "h", spacing: 12, align: "top")) {
                AtomIcon(props: IconProps(name: PHIcon.exclamationmarkTriangleFill.name, color: "orange"))
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
    package var doneArchivePanel: some PHView {
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
    package func mainSidebarPluginProps(_ plugin: PluginRecord) -> [String: PluginValue] {
        let records = BoardTaskManager.scheduledTaskRecords(scheduledTasks)
        let schedules = PluginSchedulesContext(
            tasks: (try? BridgeValue.encoding(records)).map(PluginValue.init(bridge:))?.array ?? [],
            needsLoginItemsApproval: SchedulerAgent.requiresApproval
        )
        return PluginContext.props(plugin: plugin, appearance: appearance, task: nil, composer: nil, schedules: schedules)
    }

    package var boardPluginActions: PluginUIActions {
        let confirmations = pluginConfirmations
        var actions = PluginUIActions(openTask: { id in
            if let task = try? BoardTaskManager(modelContext: modelContext).taskModel(id) {
                // A page stays up behind the task, so closing the task returns to it.
                if openBoardPlugin?.presentationKind != .page { openBoardPlugin = nil }
                isSelectedTaskNew = false
                presentScheduleOnOpen = nil
                selectedTask = task
            }
        })
        actions.confirm = { await confirmations.ask($0) }
        actions.newTask = { schedule in openNewTask(presentingSchedule: schedule) }
        actions.openLoginItems = { Platform.services.openLoginItemSettings() }
        return actions
    }

    /// What a task card's plugins can do: the board's actions, plus moving a
    /// card and raising an alert.
    package var taskItemPluginActions: PluginUIActions {
        var actions = boardPluginActions
        actions.close = { openTaskItemPlugin = nil }
        actions.moveTask = { id, status, merged in moveTask(id: id, to: status, skipMergeVerification: merged) }
        actions.alert = { title, message in pluginAlert = PluginAlert(title: title, message: message) }
        return actions
    }

    /// An Add Plugin mode placeholder was pressed: the new task's agent builds
    /// a plugin for that placement, and the mode ends.

    /// Each drag reveals only the target its source column can move to: Review
    /// cards get the Done target, Waiting Response cards the Review column.
    package var draggedTaskStatus: TaskStatus? {
        draggedTaskID.flatMap { id in tasks.first(where: { $0.id == id })?.status }
    }



    package init() {}
}

/// Where the session files the token map reads live, as this window's bridge
/// requests would name them.

package struct RenameTaskSheet: PHView {
    @PHEnvironment(\.dismiss) package var dismiss
    @PHState package var title: String

    package let onSave: (String) -> Void

    package init(title: String, onSave: @escaping (String) -> Void) {
        _title = PHState(initialValue: title)
        self.onSave = onSave
    }

    package var normalizedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Composed only of plugin atoms (Plugins/Atoms).
    package var body: some PHView {
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
    package static let playhouseStartPluginCreation = Notification.Name("playhouseStartPluginCreation")
    package static let playhouseEditPlugin = Notification.Name("playhouseEditPlugin")
    package static let playhousePreparePluginDelete = Notification.Name("playhousePreparePluginDelete")
    /// The Search Tasks menu command.
    package static let playhouseShowBoardSearch = Notification.Name("playhouseShowBoardSearch")
}

/// An alert a plugin raised with `ui.alert`.
package struct PluginAlert: Equatable {
    package let title: String
    package let message: String

    package init(title: String, message: String) {
        self.title = title
        self.message = message
    }
}

/// The error a confirmed task delete failed with, after its card came back to the board.
package struct DeleteTaskErrorAlert: PHViewModifier {
    @PHBinding package var message: String?

    package func body(content: Content) -> some PHView {
        content.alert("Couldn't delete task", isPresented: PHBinding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            PHButton("OK", role: .cancel) { message = nil }
            .buttonHoverPointer()
            .nativeHelp("Dismiss delete error")
            .accessibilityIdentifier("dismiss-delete-error-button")
        } message: {
            PHText(message ?? "Please try again.")
        }
    }

    package init(message: PHBinding<String?>) {
        _message = message
    }
}

package struct PluginAlertModifier: PHViewModifier {
    @PHBinding package var alert: PluginAlert?

    package func body(content: Content) -> some PHView {
        content.alert(alert?.title ?? "", isPresented: PHBinding(
            get: { alert != nil },
            set: { if !$0 { alert = nil } }
        )) {
            PHButton("OK", role: .cancel) { alert = nil }
                .buttonHoverPointer()
                .nativeHelp("Dismiss")
        } message: {
            PHText(alert?.message ?? "")
        }
    }

    package init(alert: PHBinding<PluginAlert?>) {
        _alert = alert
    }
}
