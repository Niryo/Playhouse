import AppKit
import ImageIO
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Answers `sizeThatFits` for `CodeBlockTextView` and `SelectableAnnotationText`. One layout pass
/// proposes several widths, so heights are kept per width until the text changes. The height is
/// measured with the text view's own layout manager: a separate copy of the text laid out the
/// whole reply a second time at every new width, as on each frame of a chat resize, before the
/// view laid out its own copy again to draw it. Measured this way, the view's frame then takes
/// the width its text was just laid out for, and drawing reuses that layout.

struct TaskConversationView: View {
    struct PendingImage: Identifiable {
        let id = UUID()
        let dataURL: String
        let image: NSImage
    }

    /// An outlined pencil with a wide body, drawn on a 24-point grid. The SF Symbol pencil
    /// stays a thin stick at small sizes, which does not read as an edit button.
    struct EditPencilShape: Shape {
        func path(in rect: CGRect) -> Path {
            let scale = min(rect.width, rect.height) / 24
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: rect.minX + x * scale, y: rect.minY + y * scale)
            }
            var path = Path()
            path.move(to: point(4, 16.5))
            path.addLine(to: point(15.5, 5))
            path.addLine(to: point(19, 8.5))
            path.addLine(to: point(7.5, 20))
            path.addLine(to: point(3.5, 20.5))
            path.closeSubpath()
            path.move(to: point(13, 7.5))
            path.addLine(to: point(16.5, 11))
            return path
        }
    }

    struct ChangeRepositoryGroup: Identifiable {
        let repository: String
        let entries: [WorkspaceChangeEntry]
        var id: String { repository }
    }

    struct GoalAchievementTimelineEntry: Codable, Identifiable, Equatable {
        let id: String
        let summary: String
        let afterMessageID: String

        static let beforeFirstMessageID = "__before_first_message__"
    }

    @Environment(\.modelContext) var modelContext
    /// Read without observing; `runtimeSlice` re-renders this view for its own task's changes.
    @Environment(\.conversationRuntimeModel) var runtimeModel
    @StateObject var runtimeSlice = ConversationRuntimeSliceObserver()
    @Environment(\.colorScheme) var colorScheme
    @AppStorage(WorkspaceSettings.defaultParentFolderKey, store: WorkspaceSettings.preferencesStore) var defaultParentFolderPath = ""

    let task: any ConversationSubject
    var isNewTask = false
    var isReadOnly = false
    var conflictResolutionRequested = false
    var onConflictResolutionChecked: (Bool) -> Void = { _ in }
    /// The prompt a task opened from the Skills page's Fix with Agent sends on arrival.
    var skillFixPrompt: String? = nil
    /// Text prefilled into the composer without starting a turn.
    var initialDraft: String? = nil
    /// Shows another task's conversation, sending it the prompt once it opens.
    var onOpenTask: (UUID, String) -> Void = { _, _ in }
    /// Opens with the schedule hint showing, set to this kind (the Scheduled Tasks page's New Task).
    var presentScheduleOnAppear: TaskScheduleKind? = nil
    let onBack: () -> Void

    /// The draft lives in an observable model, so a keystroke re-renders only views that read it
    /// (the composer inside `ComposerDraftScope`), not the whole transcript. Read `draft` (or
    /// `isSendDisabled`) during body evaluation only inside that scope; handlers may read it freely.
    @State var composerDraft = ComposerDraftModel()
    @State var toolCallExpansion = ToolCallExpansionState()
    /// Owns the transcript's scroll position; see `TranscriptScrollController`.
    @State var transcriptScroll = TranscriptScrollController()
    var draft: String {
        get { composerDraft.text }
        nonmutating set { composerDraft.text = newValue }
    }
    /// Steers this window has shown but the turn's stream hasn't echoed yet, and
    /// the reverse. The turn streams every steer, including this window's own,
    /// but a reopened window no longer reads that stream, so it shows its own.
    @State var unechoedLocalSteers: [String] = []
    @State var unconfirmedStreamedSteers: [String] = []
    /// This window's own sends whose turn stream it is reading right now.
    @State var followedTurnStreams = 0
    /// A history reload for another caller's turn is running, and whether a
    /// newer revision arrived since it started.
    @State var isFollowingHistory = false
    @State var isWatchingRunningTurn = false
    @State var followedHistoryIsStale = false
    @State var composerHeight: CGFloat = 28
    var draftAutosaveTask: Task<Void, Never>? {
        get { composerDraft.autosaveTask }
        nonmutating set { composerDraft.autosaveTask = newValue }
    }
    var isDraftUnsaved: Bool { draft != composerDraft.settledText }
    @State var pendingImages: [PendingImage] = []
    /// The task's skill gallery covers the conversation, which keeps its draft underneath.
    @State var isShowingSkills = false
    /// Counts Skills page openings. Each opening gets its own page identity, so reopening while
    /// the previous page is still sliding out builds a fresh page that reloads the catalog
    /// instead of reviving the closing one with what it read before.
    @State var skillsPresentation = 0
    /// What the composer's `@` menu can mention, read from the daemon when a mention starts.
    @State var mentionCatalog: MentionCatalog?
    @State var isLoadingMentions = false
    /// The highlighted row of the open mention menu.
    @State var mentionSelection = 0
    /// The last chosen mention, which the editor inserts once.
    @State var mentionEdit: ChatEditorEdit?
    /// The `@` whose menu Escape closed; it stays closed until another mention starts.
    @State var dismissedMentionLocation: Int?
    /// Whether the composer's editor has the keyboard, as the editor itself reports it.
    @State var isComposerEditing = false
    @State var selectedChatImage: NSImage?
    @State var isGeneratingTitle = false
    @State var didCopyTaskTitle = false
    @State var taskTitleCopyFeedbackToken = UUID()
    @State var chatPagesByTurnID: [String: StandaloneChatPage] = [:]
    @State var conversationMode: ConversationMode = .code
    @State var isEnteringGoal = false
    @State var activeGoal: CodexThreadGoal?
    @State var goalAchievementTimelineEntries: [GoalAchievementTimelineEntry] = []
    @State var currentGoalGenerationID: String?
    @State var currentGoalObjective: String?
    @State var currentGoalTimeBaselineSeconds: Double?
    @State var isGoalExpanded = false
    @State var goalStatusUpdatedAt = Date.now
    @State var modelOptions: [ConversationModelOption] = []
    @State var selectedModelID = ""
    @State var selectedEffort: ConversationEffort = .medium
    @State var pickerModelID = ""
    @State var pickerEffort: ConversationEffort = .medium
    @State var isModelPickerPresented = false
    /// The schedule confirmed in the hint. While set, Send schedules the task instead of
    /// sending it; nothing is saved until then.
    @State var composerSchedule: ComposerSchedule?
    /// What the open hint is editing.
    @State var scheduleDraft = ComposerSchedule()
    @State var isSchedulePopoverPresented = false
    @State var isSavingSchedule = false
    @FocusState var isScheduleTitleFocused: Bool
    @State var providerBoundaries: [ConversationProviderBoundary] = []
    @State var isSwitchingProvider = false
    @State var providerNotice: String?
    @State var messages: [ConversationMessage] = []
    // Oldest message currently rendered in the transcript. The transcript keeps a
    // window that starts here and runs to the newest message; opening a
    // conversation starts the window at the latest user turn.
    @State var oldestRenderedMessageID: String?
    /// An older page of history is being read to reveal above the window.
    @State var isLoadingEarlierConversationMessages = false
    /// Messages older than `messages` that the daemon still holds. History is
    /// read a page at a time, and the next page loads once the reader scrolls
    /// past the oldest message already here.
    @State var earlierStoredMessageCount = 0
    /// The newest question the transcript has presented, which tells one just sent from it.
    @State var lastScrolledUserMessageID: String?
    @State var annotations: [ConversationAnnotation] = []
    /// Pending comments handed to the turn now running; they leave the saved draft until it ends.
    @State var inFlightAnnotationIDs: Set<UUID> = []
    @State var annotationSelection: AnnotationSelection?
    @State var currentTextSelection: AnnotationSelection?
    /// The side chats saved on the task; ones with a source highlight their text purple.
    @State var sideChats: [SavedSideChat] = []
    @State var activities: [ConversationActivity] = []
    /// Tool calls from every loaded turn, each shown in the timeline after the
    /// message it followed.
    @State var timelineActivities: [ConversationActivity] = []
    /// A live turn shows its work: the disclosure opens as the turn starts and
    /// folds back into Worked for once the turn settles. A collapse the reader
    /// performs mid-turn stays collapsed until the next turn starts.
    @State var isActivityExpanded = false
    @State var responseStartedAt: Date?
    @State var completedResponseDuration: Int?
    @State var collapsedProgressTurnIDs = Set<String>()
    /// Automatic messages the reader expanded past their preview, by their full text: a
    /// streamed message gets a new id once history reloads, and its text stays the same.
    @State var expandedAutomaticMessageTexts = Set<String>()
    @State var selectedSubagent: ConversationActivity?
    @State var subagentHistory: ConversationHistory?
    @State var isLoadingSubagent = false
    @State var subagentError: String?
    @State var changeInventory = WorkspaceChangeInventory(unviewed: [], viewed: [], mergingRepositories: [])
    @State var isViewedSectionExpanded = false
    @AppStorage(WorkspaceSettings.taskSidebarCollapsedKey, store: WorkspaceSettings.preferencesStore) var isTaskSidebarCollapsed = false
    /// Add Plugin mode shows the sidebar expanded, so its placements are visible, without
    /// changing the saved collapsed preference it returns to.
    @AppStorage(WorkspaceSettings.pluginAddModeKey, store: WorkspaceSettings.preferencesStore) var isPluginAddModeOn = false
    @AppStorage(WorkspaceSettings.appearanceKey, store: WorkspaceSettings.preferencesStore) var pluginAppearance = "dark"
    @Environment(PluginRegistry.self) var pluginRegistry
    /// A modal, sidebar or page plugin opened from this conversation's placements.
    @State var openConversationPlugin: PluginRecord?
    @State var isStartingPluginTask = false
    var isTaskSidebarShownCollapsed: Bool { isTaskSidebarCollapsed && !isPluginAddModeOn }
    @AppStorage(WorkspaceSettings.workspaceChangesSectionCollapsedKey, store: WorkspaceSettings.preferencesStore) var isChangesSectionCollapsed = false
    /// The loading placeholder is for the first read only; later watcher refreshes keep the
    /// current list (or empty state) on screen instead of flashing the spinner.
    @State var hasLoadedChanges = false
    @State var isLoadingChanges = false
    @State var changesNeedRefresh = false
    @State var changeWatcher: WorkspaceChangeWatcher?
    @State var isTerminalPresented = false
    @AppStorage(TerminalPanelLayout.widthKey, store: WorkspaceSettings.preferencesStore)
    var terminalPanelWidth = Double(TerminalPanelLayout.defaultWidth)
    @State var terminalResizeStartWidth: CGFloat?
    @StateObject var terminalSession = TaskTerminalSession()
    @State var changesError: String?
    @State var selectedChange: WorkspaceChangeEntry?
    @State var selectedDiff: WorkspaceFileDiff?
    @State var isDiffPresented = false
    @State var isLoadingDiff = false
    @State var diffError: String?
    @State var isMonacoReady = false
    @State var monacoPresentation: MonacoDiffPresentation?
    @State var monacoError: String?
    @State var diffChangeCount: Int?
    @State var isLoadingHistory = false
    /// False until this window's first history read finishes (messages, pending
    /// question and restored draft are in place). Before that the transcript's
    /// accessibility value says it is loading rather than reporting zero messages.
    @State var hasLoadedConversation = false
    @State var isApplyingSavedRepositories = false
    @State var isResponding = false
    @State var isPreparingSubmittedMessage = false
    @State var conflictResolutionAttempt = 0
    @State var hasPausedResponse = false
    @State var isPausingResponse = false
    @State var queuedMessages: [QueuedConversationMessage] = []
    /// A `.dispatching` follow-up is claimed for delivery: either reserved for a
    /// steer, or sent as its own turn and kept in the store until that whole turn
    /// ends. Only the others are still waiting for the user.
    var waitingFollowUps: [QueuedConversationMessage] { queuedMessages.filter { $0.state != .dispatching } }
    @State var isSubmittingLiveMessage = false
    @State var userInputRequest: ConversationUserInputRequest?
    // The live snapshot can still carry a request this window just answered.
    @State var answeredUserInputRequestIDs: Set<String> = []
    // Safe replies this window streamed for secret recovery turns, which history hides.
    @State var streamedRecoveryReplies: [String: String] = [:]
    // Text deltas waiting to be applied to `messages`; see `bufferStreamedTextDelta`.
    @State var pendingTextDeltas = PendingStreamedTextDeltas()
    @State var userInputAnswers: [String: [String]] = [:]
    @State var userInputOther: [String: String] = [:]
    @State var userInputOtherSelected: Set<String> = []
    @State var asyncQuestionAnswers: [String: String] = [:]
    @State var answeredAsyncQuestionIDs: Set<String> = []
    @State var errorMessage: String?
    @State var pluginBridgeRecoveryError: String?
    @State var actionNotice: String?
    @State var isShowingWorkspaceEditor = false
    @State var isShowingRepositoryPicker = false
    @State var isChoosingRepositoryParent = false
    @State var repositorySearch = ""
    @State var repositorySuggestionIndex = 0
    @State var lastSelectedRepositoryPaths: [String] = []
    @State var didOverrideRepositoryDefault = false
    @State var suggestedRepositories: [URL] = []
    @State var expandedRepositoryPath: String?
    @State var repositoryBeingEdited: RepositoryWorktreeRecord?
    @State var editedBranch = ""
    @State var editedBranchFrom = ""
    @State var editedMergeTarget = ""
    @State var editingRepositoryField: String?
    @State var recentRepositoryPaths: [String] = []
    @FocusState var focusedRepositoryField: String?
    @FocusState var isComposerFocused: Bool

    var isSendDisabled: Bool {
        !isRepositoryRootConfigured || isApplyingSavedRepositories || (draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pendingImages.isEmpty && !annotations.contains(where: \.pending) && !isEnteringGoal) || isDisplayingActiveResponse || isLoadingHistory || !hasLoadedConversation || userInputRequest != nil
    }

    /// A new task can use either schedule; an existing conversation can schedule a one-time message.
    var canSchedule: Bool {
        guard let boardTask = task as? BoardTask, !isReadOnly, !boardTask.isRecurringScheduleTemplate else { return false }
        return true
    }

    var isExistingConversation: Bool {
        guard let boardTask = task as? BoardTask else { return false }
        return boardTask.activeConversationID != nil || boardTask.pendingSubmittedPrompt != nil
            || !(boardTask.status == .backlog || boardTask.status == .blocked)
    }

    var isScheduleSendDisabled: Bool {
        !isRepositoryRootConfigured || isApplyingSavedRepositories || isSavingSchedule || isLoadingHistory
            || (draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pendingImages.isEmpty)
    }

    var isRepositoryRootConfigured: Bool {
        // Standalone chat has no repository/worktree of its own, so it must never require the
        // app's global repository-root setting to be configured before sending.
        task.isStandaloneChat || task.authoringPluginID != nil || WorkspaceSettings.validDirectoryURL(for: defaultParentFolderPath) != nil
    }

    var conversationRuntime: ConversationRuntimeModel {
        guard let runtimeModel else { preconditionFailure("The conversation runtime model is not in the environment.") }
        return runtimeModel
    }

    var canPauseResponse: Bool {
        guard let threadID = task.activeConversationID else { return false }
        return conversationRuntime.canInterruptActiveTurn(threadID: threadID)
    }

    var provider: ConversationProvider { task.conversationProvider }

    /// Observed so the view refreshes when this task's turn starts or ends.
    /// Claude runs conversations in parallel, so a client-wide flag would miss
    /// this task's edge while another conversation keeps running.
    var providerTurnIsActive: Bool {
        guard let threadID = task.activeConversationID else { return false }
        return conversationRuntime.isTurnActive(threadID: threadID)
    }

    /// Claude can hold a pending question in several conversations at once, so
    /// this task reads the question from its own session rather than from the
    /// client-wide value.
    var providerPendingUserInputRequest: ConversationUserInputRequest? {
        conversationRuntime.pendingUserInputRequest(forThread: task.activeConversationID ?? "")
    }

    /// The plan exists only once a first message was sent and the agent is not
    /// waiting on the user's answer to its questions.
    var canShowStartImplementing: Bool {
        conversationMode == .plan && !isResponding && !isReadOnly
            && messages.contains(where: { $0.role == .user })
            && userInputRequest == nil && providerPendingUserInputRequest == nil
    }

    /// Why a task's plan can't be handed off to an implementation turn yet; transient loading
    /// states also disable the button but need no explanation. A chat never has a workspace
    /// root or a repository picker, so it keeps its disabled button without this reason.
    var startImplementingUnavailableReason: String? {
        guard !task.isStandaloneChat else { return nil }
        return PlanImplementationHandoff.unavailableReason(workspaceRootPaths: task.workspaceRootPaths)
    }

    var isConversationTurnActive: Bool {
        conversationRuntime.isTurnActive(threadID: task.activeConversationID ?? "")
    }

    var archivedFollowUpHint: String {
        let target = task.repositoryWorktrees.compactMap(\.mergeTarget).first
        return "Archived · a follow-up reopens this task in a fresh worktree from \(target ?? "the merge target")"
    }

    /// Provider switches wait for active turns and queued follow-ups to settle.
    var canSwitchProvider: Bool {
        !isReadOnly && !isResponding && !isLoadingHistory && !isPreparingSubmittedMessage && !isSwitchingProvider
            && userInputRequest == nil && queuedMessages.isEmpty && task.status != .done
    }

    var approvalNotice: String {
        "\(provider.displayName) requested an approval. Playhouse denied it because approval prompts are disabled."
    }

    var diffHighlightStatus: String {
        guard let diffChangeCount else { return "Calculating changes…" }
        guard diffChangeCount > 0 else { return "No text changes" }
        return "\(diffChangeCount) change\(diffChangeCount == 1 ? "" : "s") highlighted"
    }

    /// Describes the editor the diff is actually rendered in: Monaco is loaded once per
    /// session, so a later diff reports the same editor it reused.
    var monacoStartupDescription: String {
        guard isMonacoReady, let monacoPresentation else { return "Starting editor" }
        let reuse = monacoPresentation.reusedWarmEditor ? "reused" : "loaded"
        return "Editor \(monacoPresentation.editorTag) \(reuse), showing \(monacoPresentation.path)"
    }

    /// The turn is the latest one the user started: status nudges Playhouse sends after it
    /// continue that turn rather than start a new one.
    static func latestUserTurnStart(in messages: [ConversationMessage]) -> Int? {
        messages.lastIndex { $0.role == .user && !$0.isPlayhouseSent }
    }

    var latestConversationTurnID: String? {
        if let latestUserIndex = Self.latestUserTurnStart(in: messages) {
            return messages.dropFirst(latestUserIndex + 1).first(where: {
                $0.role == .assistant && $0.turnID != nil
            })?.turnID ?? messages[latestUserIndex].turnID
        }
        return messages.last(where: { $0.turnID != nil })?.turnID
    }

    var progressMessageIDs: Set<String> {
        guard let latestConversationTurnID,
              collapsedProgressTurnIDs.contains(latestConversationTurnID) else { return [] }
        return Set(messages.lazy.filter {
            $0.role == .assistant && $0.phase == "commentary" && $0.turnID == latestConversationTurnID
        }.map(\.id))
    }

    var progressMessages: [ConversationMessage] {
        // Computed once: reading the property inside the filter rebuilt the set for every message.
        let ids = progressMessageIDs
        guard !ids.isEmpty else { return [] }
        return messages.filter { ids.contains($0.id) }
    }

    var conversationMessages: [ConversationMessage] {
        let completedProgressIDs = progressMessageIDs
        // Read on every layout pass and every scroll sample, so the common case
        // of nothing collapsed must not copy the transcript.
        guard !completedProgressIDs.isEmpty else { return messages }
        return messages.filter { !completedProgressIDs.contains($0.id) }
    }

    /// Messages a conversation that established no window keeps rendered while it follows.
    static let followedConversationMessageCount = 40
    /// Older messages revealed at a time as the reader nears the oldest rendered one. Each is
    /// rendered to be measured, so a few at a time keep scrolling up from stalling on a batch.
    static let olderConversationMessageBatchSize = 2
    /// Loaded messages left above the rendered window when the next older page is read.
    static let olderConversationMessagePrefetchCount = 20
    /// Messages read per history request: the newest page on open, then one
    /// more page each time the rendered window reaches the oldest loaded one.
    static let historyPageSize = 80
    /// Above this many changed files the sidebar shows a notice instead of the list, which would stall layout.
    static let maxRenderedChangeCount = 1000

    /// First message of the newest user turn. Opening a conversation renders
    /// this message and everything after it, so the latest question sits at the
    /// top of the viewport with its answer below.
    var latestConversationTurnStartID: String? {
        let allMessages = conversationMessages
        // Prompts Playhouse sends on its own are not a turn the user started: anchoring the
        // window there would hide the conversation the recovery is continuing.
        // When redaction has replaced every user message, the placeholders are all there is to anchor on.
        return allMessages.last(where: { $0.role == .user && !PrivatePromptPlaceholder.matches($0.text) && !$0.isPlayhouseSent })?.id
            ?? allMessages.last(where: { $0.role == .user })?.id
            ?? allMessages.last?.id
    }

    /// The window runs from `oldestRenderedMessageID` to the newest message.
    /// A conversation that was empty when it loaded establishes no window of
    /// its own, so it keeps the newest batch rendered as messages arrive.
    var renderedConversationMessages: [ConversationMessage] {
        let allMessages = conversationMessages
        guard let oldestRenderedMessageID,
              let startIndex = allMessages.firstIndex(where: { $0.id == oldestRenderedMessageID }) else {
            return Array(allMessages.suffix(Self.followedConversationMessageCount))
        }
        return Array(allMessages[startIndex...])
    }

    var hasOlderConversationMessages: Bool {
        // Answered from indices rather than by building the rendered window:
        // every scroll sample asks this question.
        if earlierStoredMessageCount > 0 { return true }
        let allMessages = conversationMessages
        guard let oldestRenderedMessageID,
              let startIndex = allMessages.firstIndex(where: { $0.id == oldestRenderedMessageID }) else {
            return allMessages.count > Self.followedConversationMessageCount
        }
        return startIndex > allMessages.startIndex
    }

    var activityDisclosureAnchorID: String? {
        if let latestUserIndex = Self.latestUserTurnStart(in: conversationMessages) {
            return conversationMessages.dropFirst(latestUserIndex + 1).first(where: { $0.role == .assistant })?.id
        }
        return conversationMessages.first(where: { $0.role == .assistant })?.id
    }

    var shouldShowActivityDisclosure: Bool {
        !activities.isEmpty || !progressMessageIDs.isEmpty || isResponding || completedResponseDuration != nil || hasCompletedAssistantResponse
    }

    var hasCompletedAssistantResponse: Bool {
        guard let latestUserIndex = Self.latestUserTurnStart(in: messages) else {
            return messages.contains { $0.role == .assistant && $0.phase == "final_answer" }
        }
        let messagesAfterLatestUser = messages.dropFirst(latestUserIndex + 1)
        if messagesAfterLatestUser.contains(where: {
            $0.role == .assistant && $0.phase == "final_answer"
        }) {
            return true
        }
        guard !providerTurnIsActive else { return false }
        return messagesAfterLatestUser.contains {
            $0.role == .assistant && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var isDisplayingActiveResponse: Bool {
        isResponding && !hasCompletedAssistantResponse
    }

    var responseStartedAtDefaultsKey: String {
        TaskPreferenceKeys.responseStartedAt(taskID: task.id)
    }

    var completedResponseDurationDefaultsKey: String {
        TaskPreferenceKeys.completedResponseDuration(taskID: task.id)
    }

    var goalAchievementTimelineDefaultsKey: String {
        TaskPreferenceKeys.goalAchievementTimeline(taskID: task.id)
    }

    var goalGenerationDefaultsKey: String {
        CodexGoalGenerationStore.generationIDKey(taskID: task.id)
    }

    var goalGenerationObjectiveDefaultsKey: String {
        CodexGoalGenerationStore.objectiveKey(taskID: task.id)
    }

    var goalGenerationTimeBaselineDefaultsKey: String {
        CodexGoalGenerationStore.timeBaselineKey(taskID: task.id)
    }

    var body: some View {
        Group {
            if task.isStandaloneChat || task.authoringPluginID != nil {
                // The standalone chat sidebar reuses only the conversation transcript/composer,
                // not the repo-specific "Changes" sidebar a real task's worktree needs.
                conversationPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    taskSidebar

                    Rectangle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(width: 1)

                    conversationPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                // The terminal floats over the conversation's right edge rather than taking
                // its width, so opening it never reflows the transcript or the composer.
                .overlay(alignment: .trailing) {
                    if isTerminalPresented {
                        GeometryReader { geometry in
                            let available = conversationWidth(in: geometry.size.width)
                            let width = TerminalPanelLayout.clampedWidth(CGFloat(terminalPanelWidth), available: available)
                            HStack(spacing: 0) {
                                terminalResizeHandle(width: width, available: available)
                                TaskTerminalPanel(
                                    session: terminalSession,
                                    onRestart: { terminalSession.restart(workspaceManager: workspaceManager) },
                                    onClose: { setTerminalPresented(false) }
                                )
                            }
                            .frame(width: width)
                            .shadow(color: .black.opacity(0.22), radius: 12, x: -4, y: 0)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                        }
                        .transition(.move(edge: .trailing))
                    }
                }
                .clipped()
            }
        }
        .background(WorkspaceTheme.windowBackground)
        .pluginPresentation($openConversationPlugin, props: pluginProps, actions: pluginActions)
        .onChange(of: task.id, initial: true) {
            runtimeSlice.observe(conversationRuntime, taskID: task.id.uuidString) { [task] in
                Set([task.codexThreadID, task.claudeSessionID].compactMap { $0 })
            }
        }
        .onAppear {
            if !isReadOnly,
               let savedMode = WorkspaceSettings.preferencesStore.string(forKey: conversationModeDefaultsKey),
               let mode = ConversationMode(rawValue: savedMode) {
                conversationMode = mode
            }
            if let boardTask = task as? BoardTask, let schedule = ComposerSchedule(task: boardTask) {
                composerSchedule = schedule
                scheduleDraft = schedule
            }
            if let kind = presentScheduleOnAppear, !isReadOnly {
                scheduleDraft = composerSchedule ?? defaultScheduleDraft(kind: kind)
                Task { @MainActor in
                    // Let the composer lay out first, so the hint opens anchored to its button.
                    try? await Task.sleep(for: .milliseconds(300))
                    isSchedulePopoverPresented = true
                }
            }
            guard isNewTask else { return }
            isShowingRepositoryPicker = false
            lastSelectedRepositoryPaths = WorkspaceSettingsManager().lastSelectedRepositories
            isComposerFocused = true
            loadSuggestedRepositories()
            let savedRepositories = validLastSelectedRepositoryURLs
            if !savedRepositories.isEmpty {
                selectRepositories(savedRepositories, reopenPickerOnError: false, isApplyingDefault: true)
            }
        }
        .sheet(isPresented: $isShowingWorkspaceEditor) {
            WorkspaceRootsEditor(
                parentFolderURL: WorkspaceSettings.validDirectoryURL(for: defaultParentFolderPath),
                initialRoots: workspaceRootURLs,
                repositoryWorktrees: task.repositoryWorktrees,
                onSave: updateWorkspaceRoots
            )
        }
        .sheet(isPresented: Binding(
            get: { selectedChatImage != nil },
            set: { if !$0 { selectedChatImage = nil } }
        )) {
            if let selectedChatImage {
                VStack(alignment: .trailing, spacing: 8) {
                    Button("Close") { self.selectedChatImage = nil }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("close-chat-image-viewer")
                        .buttonHoverPointer()
                        .nativeHelp("Close the full-size image")
                    Image(nsImage: selectedChatImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityLabel("Full-size attached image")
                        .accessibilityIdentifier("chat-image-full-size")
                }
                .padding(16)
                // Stay within the window's own 980x640 content minimum so the sheet
                // can never outgrow its host window and push Close out of reach.
                .frame(minWidth: 900, minHeight: 600)
            }
        }
        .overlay(alignment: .topLeading) { skillsPage }
        .task {
            // Synchronous, so the picker shows the cached model name on the
            // first frame instead of "Default" while the conversation and a
            // fresh model list are still round-tripping through the bridge.
            if !isReadOnly { primeModelOptionsFromCache() }
            if !isReadOnly { refreshQueuedMessages() }
            if !isReadOnly {
                _ = try? await conversationManager.reconcileLifecycleStatusOnOpen(taskID: task.id)
            }
            if !isReadOnly, let request = providerPendingUserInputRequest, request.threadID == task.activeConversationID {
                userInputRequest = request
            }
            await loadConversation()
            if !isReadOnly {
                refreshQueuedMessages()
                await loadModels()
            }
            if task.isStandaloneChat { refreshChatPageStatus() }
            if isNewTask {
                await Task.yield()
                isComposerFocused = true
            }
            if conflictResolutionRequested && !isReadOnly && !isResponding {
                conflictResolutionAttempt = 1
                sendMessage(overrideText: PlayhouseSentMessage.pullRequestConflicts)
            } else if let initialDraft, !initialDraft.isEmpty, draft.isEmpty, !isReadOnly,
                      !isResponding, messages.isEmpty, task.pendingSubmittedPrompt == nil {
                draft = initialDraft
            } else if let skillFixPrompt, !isReadOnly, !isResponding, messages.isEmpty, task.pendingSubmittedPrompt == nil {
                // Sent as the composer's own draft, so the composer clears as for any send.
                draft = skillFixPrompt
                sendMessage()
            }
        }
        .onChange(of: providerPendingUserInputRequest) { previous, request in
            // Once the snapshot drops it, a later question may reuse an answered request's ID.
            if request == nil { answeredUserInputRequestIDs.removeAll() }
            // A live question can end without an answer here (a rejected // question, or another window's answer); keep it only if it was saved.
            if request == nil, let previous, userInputRequest?.id == previous.id {
                Task { @MainActor in
                    guard let history = try? await conversationManager.history(taskID: task.id, messageLimit: 1),
                          userInputRequest?.id == previous.id else { return }
                    let saved = history.pendingUserInputRequest
                    userInputRequest = saved?.threadID == task.activeConversationID ? saved : nil
                }
            }
            guard let request, request.threadID == task.activeConversationID, request != userInputRequest,
                  !answeredUserInputRequestIDs.contains(request.id) else { return }
            showUserInputRequest(request)
        }
        // Compared only while a streamed recovery reply is waiting: comparing the whole
        // transcript on every update was a large share of streaming a long conversation.
        // Showing the replies again is idempotent, so the comparison starting is harmless.
        .onChange(of: streamedRecoveryReplies.isEmpty ? nil : messages) { _, _ in
            // History reloads bring back the hidden text for replies this window streamed.
            if !streamedRecoveryReplies.isEmpty { showStreamedRecoveryReplies() }
        }
        .onChange(of: providerTurnIsActive) { _, isTurnActive in
            if isTurnActive { watchRunningTurnIfNeeded() }
            if !isTurnActive, task.isStandaloneChat { refreshChatPageStatus() }
            if !isTurnActive, !isReadOnly {
                refreshQueuedMessages()
            }
            let submittedTurnIsPending = task.pendingSubmittedPrompt != nil
                && (task.status == .inProgress || task.status == .waitingResponse)
            guard let taskThreadID = task.activeConversationID else {
                isResponding = submittedTurnIsPending
                return
            }
            let completedTurnIsVisible = hasCompletedAssistantResponse && !isTurnActive
            isResponding = completedTurnIsVisible
                ? false
                : submittedTurnIsPending || (isTurnActive && conversationRuntime.isTurnActive(threadID: taskThreadID))
            // A turn stopped while this window followed it (not sent from it) can still be continued.
            if !isTurnActive, !isResponding, conversationRuntime.wasLastTurnInterrupted(threadID: taskThreadID) {
                hasPausedResponse = true
            }
        }
        .onChange(of: task.pendingSubmittedPrompt == nil) { _, cleared in
            // The daemon clears the submitted prompt after the turn ends, which can be after
            // this window saw it end. A turn parked on a question is not over, even while the
            // runtime snapshot lags, so leave the answer flow to settle it.
            if cleared, isResponding, !providerTurnIsActive,
               userInputRequest == nil, providerPendingUserInputRequest == nil,
               !conversationRuntime.isTurnActive(threadID: task.activeConversationID ?? "") {
                isResponding = false
            }
        }
        .onChange(of: conversationRuntime.wasLastTurnInterrupted(threadID: task.activeConversationID ?? "")) { _, interrupted in
            // The daemon can report the stop after this window loaded the settled turn.
            if interrupted, !isResponding, !providerTurnIsActive { hasPausedResponse = true }
        }
        .onChange(of: conversationRuntime.snapshot.conversationRevisions[task.id.uuidString]) { _, _ in
            // Another caller's turn (a queued follow-up, a CLI send or steer, or
            // a turn this window started before it was reopened) reaches this
            // window only through history.
            guard !isReadOnly else { return }
            refreshQueuedMessages()
            // A page decision can land after the turn ended; only a revision announces it.
            // Mid-turn revisions are progress, and turn end refreshes pages anyway, so the
            // store is only reread while no turn runs.
            if task.isStandaloneChat, !providerTurnIsActive { refreshChatPageStatus() }
            // History lags what this window's own stream has already shown.
            guard followedTurnStreams == 0 else { return }
            followHistory()
        }
        .onChange(of: conversationRuntime.snapshot.goal.stateRevision) { _, _ in
            guard conversationRuntime.snapshot.goal.stateThreadID == task.codexThreadID else { return }
            Task { @MainActor in
                activeGoal = try? await conversationManager.goal(taskID: task.id)
                if let activeGoal { reconcileGoalGeneration(with: activeGoal) }
                goalStatusUpdatedAt = .now
            }
        }
        .onChange(of: conversationRuntime.snapshot.goal.turnRevision) { _, _ in
            guard let threadID = task.codexThreadID, conversationRuntime.isObservingGoal(threadID: threadID) else { return }
            Task { @MainActor in await refreshGoalConversation() }
        }
        .onChange(of: conversationRuntime.snapshot.goal.turnCompletedRevision) { _, _ in
            guard let threadID = task.codexThreadID, conversationRuntime.isObservingGoal(threadID: threadID) else { return }
            let completedTurnID = conversationRuntime.snapshot.goal.turnCompletedTurnID
            Task { @MainActor in
                activeGoal = try? await conversationManager.goal(taskID: task.id)
                goalStatusUpdatedAt = .now
                await refreshGoalConversation()
                guard let activeGoal, activeGoal.status == "complete" else { return }
                reconcileGoalGeneration(with: activeGoal)
                guard let generationID = currentGoalGenerationID,
                      !goalAchievementTimelineEntries.contains(where: { $0.id == generationID }) else { return }
                let completionMessage = completedTurnID.flatMap { turnID in
                    conversationMessages.last(where: { $0.turnID == turnID })
                } ?? conversationMessages.last
                let anchorID = completionMessage?.id ?? GoalAchievementTimelineEntry.beforeFirstMessageID
                goalAchievementTimelineEntries.append(GoalAchievementTimelineEntry(
                    id: generationID,
                    summary: goalAchievementSummary(activeGoal),
                    afterMessageID: anchorID
                ))
                persistGoalAchievementTimeline()
            }
        }
        .task(id: task.workspaceRootPaths) {
            let watchPaths = await WorkspaceChangeWatcher.watchPaths(workspaceRoots: task.workspaceRootPaths)
            guard !Task.isCancelled else { return }
            changeWatcher?.stop()
            changeWatcher = WorkspaceChangeWatcher(paths: watchPaths) {
                Task { await refreshWorkspaceChanges() }
            }
            changeWatcher?.start()
            await refreshWorkspaceChanges()
        }
        .onDisappear {
            changeWatcher?.stop()
            changeWatcher = nil
            terminalSession.terminate()
            // Switching tasks replaces this view without going back first.
            if !isReadOnly, isDraftUnsaved { persistDraft(reportingErrors: false) }
        }
    }


    /// A narrow rail that keeps the pending count visible while the sidebar is hidden.

    /// What every row of one transcript pass shares, worked out once for the pass.


    /// The composer box's display model, derived from this conversation's state.


    /// The conversation's history when a send that reported failure still added its prompt after
    /// `anchorID`, the newest message shown before the send; nil when it didn't. When the anchor
    /// isn't in the fetched page the answer is nil, so the prompt returns to the composer rather
    /// than risk dropping text that never reached the conversation.
    func historyIfSendReachedConversation(_ text: String, after anchorID: String?) async -> ConversationHistory? {
        guard let history = try? await conversationManager.history(taskID: task.id, messageLimit: Self.historyPageSize) else { return nil }
        let later: ArraySlice<ConversationMessage>
        if let anchorID {
            guard let anchorIndex = history.messages.firstIndex(where: { $0.id == anchorID }) else { return nil }
            later = history.messages[history.messages.index(after: anchorIndex)...]
        } else {
            later = history.messages[...]
        }
        return later.contains { $0.role == .user && MentionText.sameUserText($0.text, text) } ? history : nil
    }


    func standaloneChatPageSeparator(before message: ConversationMessage) -> StandaloneChatPage? {
        guard task.isStandaloneChat,
              let turnID = message.turnID,
              let page = chatPagesByTurnID[turnID],
              let messageIndex = messages.firstIndex(where: { $0.id == message.id }) else { return nil }
        let previousTurnID = messages[..<messageIndex].last(where: { $0.turnID != nil })?.turnID
        guard previousTurnID.flatMap({ chatPagesByTurnID[$0]?.id }) != page.id else { return nil }
        return page
    }

    /// Pages that the pending annotations quote from, excluding the page this turn already runs
    /// in. Only standalone chat has pages, so task conversations always send an empty list.
    func standaloneChatPageIDs(for pendingAnnotations: [ConversationAnnotation]) -> [String] {
        guard task.isStandaloneChat, !pendingAnnotations.isEmpty else { return [] }
        let activePageID = messages.last(where: { $0.turnID != nil })?.turnID.flatMap { chatPagesByTurnID[$0]?.id }
        var pageIDs: [String] = []
        for annotation in pendingAnnotations {
            guard let turnID = messages.first(where: { $0.id == annotation.messageID })?.turnID,
                  let pageID = chatPagesByTurnID[turnID]?.id,
                  pageID != activePageID, !pageIDs.contains(pageID) else { continue }
            pageIDs.append(pageID)
        }
        return pageIDs
    }

    /// Composed only of plugin atoms (Plugins/Atoms).
    func standaloneChatPageSeparator(_ page: StandaloneChatPage) -> some View {
        AtomStack(props: StackProps(axis: "h", spacing: 12, group: true), common: AtomCommon(paddingY: 5)) {
            transcriptRule(opacity: 0.13)
            AtomText(props: TextProps(text: page.title, size: 11, weight: "semibold", color: "secondary", lineLimit: 1), common: AtomCommon(testID: "chat-page-separator"))
                .fixedSize(horizontal: true, vertical: false)
            transcriptRule(opacity: 0.13)
        }
    }


    static func thumbnailBitmap(from data: Data) -> NSBitmapImageRep? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1600
                ] as CFDictionary
              ) else {
            return nil
        }
        return NSBitmapImageRep(cgImage: image)
    }

    func addImage(_ bitmap: NSBitmapImageRep, preferJPEG: Bool = false) throws {
        guard pendingImages.count < 8 else {
            throw BridgeCommandError(code: "invalid_argument", message: "Choose up to 8 valid images that fit within 10 MB after encoding.")
        }
        guard let encoded = Self.encodedImage(bitmap, preferJPEG: preferJPEG), encoded.data.count <= 10_000_000 else {
            throw BridgeCommandError(code: "invalid_argument", message: "Choose up to 8 valid images that fit within 10 MB after encoding.")
        }
        let previewData = preferJPEG
            ? bitmap.representation(using: .png, properties: [:])
            : encoded.data
        guard let previewData, let previewImage = NSImage(data: previewData) else {
            throw BridgeCommandError(code: "invalid_argument", message: "Choose up to 8 valid images that fit within 10 MB after encoding.")
        }
        pendingImages.append(PendingImage(dataURL: "data:\(encoded.mimeType);base64,\(encoded.data.base64EncodedString())", image: previewImage))
        persistDraft()
    }

    /// Text and images handed to the active turn or the queue leave the saved draft
    /// at once, so reopening the task doesn't restore them to the composer.
    func clearHandedOffDraft() {
        composerDraft.settledText = ""
        draft = ""
        pendingImages.removeAll()
        persistDraft()
    }


}

extension View {
    /// One accessibility element that reads as `label`. On macOS an atom Text,
    /// Label or combined stack reports its text as a value, which hides an
    /// explicit label, so these rows replace their children instead.
    func accessibilitySummary(_ label: String, id: String) -> some View {
        accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityIdentifier(id)
    }
}
