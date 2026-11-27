import Foundation
import PlayhouseAtoms
import PlayhouseCore
import PlayhouseUI

/// Answers `sizeThatFits` for `CodeBlockTextView` and `SelectableAnnotationText`. One layout pass
/// proposes several widths, so heights are kept per width until the text changes. The height is
/// measured with the text view's own layout manager: a separate copy of the text laid out the
/// whole reply a second time at every new width, as on each frame of a chat resize, before the
/// view laid out its own copy again to draw it. Measured this way, the view's frame then takes
/// the width its text was just laid out for, and drawing reuses that layout.

package struct TaskConversationView: PHView {
    package struct PendingImage: Identifiable {
        package let id = UUID()
        package let dataURL: String
        package let image: PHPlatformImage

        package init(dataURL: String, image: PHPlatformImage) {
            self.dataURL = dataURL
            self.image = image
        }
    }

    /// A steer the window shows before the provider has confirmed it.
    package struct PendingLocalSteer: Identifiable {
        package let id = UUID().uuidString
        package let text: String
        package let imageDataURLs: [String]

        package init(text: String, imageDataURLs: [String]) {
            self.text = text
            self.imageDataURLs = imageDataURLs
        }
    }

    /// An outlined pencil with a wide body, drawn on a 24-point grid. The SF Symbol pencil
    /// stays a thin stick at small sizes, which does not read as an edit button.
    package struct EditPencilShape: PHShape {
        package func path(in rect: CGRect) -> PHPath {
            let scale = min(rect.width, rect.height) / 24
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: rect.minX + x * scale, y: rect.minY + y * scale)
            }
            var path = PHPath()
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

        package init() {}
    }

    package struct GoalAchievementTimelineEntry: Codable, Identifiable, Equatable {
        package let id: String
        package let summary: String
        package let afterMessageID: String

        package static let beforeFirstMessageID = "__before_first_message__"

        package init(id: String, summary: String, afterMessageID: String) {
            self.id = id
            self.summary = summary
            self.afterMessageID = afterMessageID
        }
    }

    @PHEnvironment(\.modelContext) package var modelContext
    @PHEnvironment(\.showTokenStats) package var showTokenStats
    /// Read untracked; `runtimeSlice` re-renders this view for its own task's changes.
    @PHEnvironment(ConversationRuntimeModel.self) package var runtimeModel
    @PHState package var runtimeSlice = ConversationRuntimeSliceObserver()
    @PHEnvironment(\.colorScheme) package var colorScheme
    @PHAppStorage(WorkspaceSettings.defaultParentFolderKey, store: WorkspaceSettings.preferencesStore) package var defaultParentFolderPath = ""

    package let task: any ConversationSubject
    package var isNewTask = false
    package var isReadOnly = false
    /// The prompt a task opened from the Skills page's Fix with Agent sends on arrival.
    package var skillFixPrompt: String? = nil
    /// Text prefilled into the composer without starting a turn.
    package var initialDraft: String? = nil
    /// Shows another task's conversation, sending it the prompt once it opens.
    package var onOpenTask: (UUID, String) -> Void = { _, _ in }
    /// Opens with the schedule hint showing, set to this kind (the Scheduled Tasks popover's New Task).
    package var presentScheduleOnAppear: TaskScheduleKind? = nil
    package let onBack: () -> Void

    /// The draft lives in an observable model, so a keystroke re-renders only views that read it
    /// (the composer inside `ComposerDraftScope`), not the whole transcript. Read `draft` (or
    /// `isSendDisabled`) during body evaluation only inside that scope; handlers may read it freely.
    @PHState package var composerDraft = ComposerDraftModel()
    @PHState package var toolCallExpansion = ToolCallExpansionState()
    /// Owns the transcript's scroll position; see `TranscriptScrollController`.
    @PHState package var transcriptScroll = TranscriptScrollController()
    package var draft: String {
        get { composerDraft.text }
        nonmutating set { composerDraft.text = newValue }
    }
    /// Steers this window has shown but the turn's stream hasn't echoed yet, and
    /// the reverse. The turn streams every steer, including this window's own,
    /// but a reopened window no longer reads that stream, so it shows its own.
    @PHState package var unechoedLocalSteers: [String] = []
    @PHState package var unconfirmedStreamedSteers: [String] = []
    /// Steer bubbles shown before history gives them their turn's ID. They join the running
    /// turn, so they never start a turn of their own in the transcript.
    @PHState package var liveSteerMessageIDs: Set<String> = []
    /// Each turn stream this window reads, by its reply placeholder's ID, to the message its
    /// text goes to now. A steer moves what the turn writes after it below the steer.
    @PHState package var streamedReplyTargets: [String: String] = [:]
    /// Each turn stream's earlier messages that a steer closed with text still in them. The
    /// provider's item for that text settles there, above the steer, rather than below it.
    @PHState package var streamedRepliesAboveSteers: [String: [String]] = [:]
    /// This window's own sends whose turn stream it is reading right now.
    @PHState package var followedTurnStreams = 0
    /// A history reload for another caller's turn is running, and whether a
    /// newer revision arrived since it started.
    @PHState package var isFollowingHistory = false
    @PHState package var isWatchingRunningTurn = false
    @PHState package var followedHistoryIsStale = false
    @PHState package var composerHeight: CGFloat = 28
    package var draftAutosaveTask: Task<Void, Never>? {
        get { composerDraft.autosaveTask }
        nonmutating set { composerDraft.autosaveTask = newValue }
    }
    package var isDraftUnsaved: Bool { draft != composerDraft.settledText }
    @PHState package var pendingImages: [PendingImage] = []
    /// The task's skill gallery covers the conversation, which keeps its draft underneath.
    @PHState package var isShowingSkills = false
    /// Counts Skills page openings. Each opening gets its own page identity, so reopening while
    /// the previous page is still sliding out builds a fresh page that reloads the catalog
    /// instead of reviving the closing one with what it read before.
    @PHState package var skillsPresentation = 0
    /// What the composer's `@` menu can mention, read from the daemon when a mention starts.
    @PHState package var mentionCatalog: MentionCatalog?
    /// The catalog's handles, kept beside it so the composer and each message don't rebuild them on every render.
    @PHState package var mentionHandles: Set<String> = []
    /// What the open menu lists, refreshed when the typed mention or the catalog changes rather than on every render.
    @PHState package var mentionSuggestions: [MentionItem] = []
    @PHState package var isLoadingMentions = false
    /// The highlighted row of the open mention menu.
    @PHState package var mentionSelection = 0
    /// The last chosen mention, which the editor inserts once.
    @PHState package var mentionEdit: ChatEditorEdit?
    /// The `@` whose menu Escape closed; it stays closed until another mention starts.
    @PHState package var dismissedMentionLocation: Int?
    /// The plugins' `/` commands, read again as each new `/` is typed.
    @PHState package var slashEntries: [SlashCommandEntry]?
    /// The list of the command the `/` menu lists, from its plugin when that list opens.
    @PHState package var slashList: PluginCommandList?
    @PHState package var slashListCommand: String?
    /// A chosen command's handler is running; the menu stays closed meanwhile.
    @PHState package var isRunningSlashCommand = false
    /// The highlighted row of the open `/` menu.
    @PHState package var slashSelection = 0
    /// The `/` whose menu Escape closed; it stays closed until another command starts.
    @PHState package var dismissedSlashLocation: Int?
    /// What the next Skills page opening shows first, set by a `/mcp` or `/skill` row's buttons.
    @PHState package var skillsFocus: SkillsPageFocus?
    /// Whether the composer's editor has the keyboard, as the editor itself reports it.
    @PHState package var isComposerEditing = false
    @PHState package var selectedChatImage: PHPlatformImage?
    @PHState package var isGeneratingTitle = false
    @PHState package var chatPagesByTurnID: [String: StandaloneChatPage] = [:]
    /// The standalone chat's open parallel bubbles, whose placeholders the transcript shows
    /// after the turn each one returns after.
    @PHState package var parallelChatPlaceholders: [ParallelChatPlaceholder] = []
    /// The message at the top of the transcript's viewport, as last reported.
    @PHState package var topTranscriptRowID: String?
    @PHState package var conversationMode: ConversationMode = .code
    /// The task's saved context mode, read on appear and set by the composer's toggle.
    @PHState package var conversationContextMode: ConversationContextMode = .full
    @PHState package var isEnteringGoal = false
    @PHState package var activeGoal: CodexThreadGoal?
    @PHState package var goalAchievementTimelineEntries: [GoalAchievementTimelineEntry] = []
    @PHState package var currentGoalGenerationID: String?
    @PHState package var currentGoalObjective: String?
    @PHState package var currentGoalTimeBaselineSeconds: Double?
    @PHState package var isGoalExpanded = false
    @PHState package var goalStatusUpdatedAt = Date.now
    @PHState package var modelOptions: [ConversationModelOption] = []
    @PHState package var selectedModelID = ""
    @PHState package var selectedEffort: ConversationEffort = .medium
    @PHState package var pickerModelID = ""
    @PHState package var pickerEffort: ConversationEffort = .medium
    @PHState package var isModelPickerPresented = false
    /// The schedule confirmed in the hint. While set, Send schedules the task instead of
    /// sending it; nothing is saved until then.
    @PHState package var composerSchedule: ComposerSchedule?
    /// What the open hint is editing.
    @PHState package var scheduleDraft = ComposerSchedule()
    @PHState package var isSchedulePopoverPresented = false
    @PHState package var isSavingSchedule = false
    @PHFocusState package var isScheduleTitleFocused: Bool
    @PHState package var providerBoundaries: [ConversationProviderBoundary] = []
    /// True while a switch this window showed is being saved.
    @PHState package var isSwitchingProvider = false
    /// The provider a switch shows before the task model has it: from the click
    /// until the daemon's write reaches this window's task.
    @PHState package var switchedProvider: ConversationProvider?
    /// The save of that switch, which a send waits for so it runs with the new provider.
    @PHState package var providerSwitch: Task<Void, Never>?
    @PHState package var providerNotice: String?
    /// Which providers' CLIs are installed; empty until the daemon has answered.
    @PHState package var providerInstallStatuses: [ConversationProviderInstallStatus] = []
    /// The provider whose installer is running from the provider menu.
    @PHState package var installingProvider: ConversationProvider?
    @PHState package var messages: [ConversationMessage] = []
    // Oldest message currently rendered in the transcript. The transcript keeps a
    // window that starts here and runs to the newest message; opening a
    // conversation starts the window at the latest user turn.
    @PHState package var oldestRenderedMessageID: String?
    /// Images of messages whose history page left them out, by `deferredImageKey`,
    /// read as their rows come up. An empty entry is a message that turned out to have none.
    @PHState package var deferredMessageImages: [String: [String]] = [:]
    @PHState package var deferredImageRequests: Set<String> = []
    @PHState package var deferredImageLoads: Set<String> = []
    /// An older page of history is being read to reveal above the window.
    @PHState package var isLoadingEarlierConversationMessages = false
    /// Messages older than `messages` that the daemon still holds. History is
    /// read a page at a time, and the next page loads once the reader scrolls
    /// past the oldest message already here.
    @PHState package var earlierStoredMessageCount = 0
    /// The newest message rendered while the reader browses an earlier chat page. The window
    /// then ends there instead of at the newest message, and grows downward as they scroll.
    @PHState package var renderedWindowEndID: String?
    /// Messages left unloaded between a chat page the reader jumped to and the newest ones.
    @PHState package var historyGap: ConversationHistoryGap?
    @PHState package var isLoadingNewerConversationMessages = false
    /// Counts chat page jumps, so a page read that a later jump overtook is dropped.
    @PHState package var chatPageJumpCount = 0
    /// The standalone chat's page labels. Only the labels read it, so the page the reader is on
    /// changes as they scroll without re-rendering the transcript.
    @PHState package var chatPageAnchors = ChatPageAnchorsModel()
    @PHAppStorage(WorkspaceSettings.chatPageAnchorsPinnedKey, store: WorkspaceSettings.preferencesStore)
    package var pinsChatPageAnchors = false
    /// Whether hovering the handle slid the unlocked page labels out.
    @PHState package var revealsChatPageAnchors = false
    /// Folds the hovered-out labels back in after a short grace, so the pointer can cross from
    /// the handle to the labels without them closing.
    @PHState package var chatPageAnchorsCollapse: Task<Void, Never>?
    /// Which of the handle and the slid-out labels the pointer is over.
    @PHState package var hoveredChatPageAnchorsParts: Set<ChatPageAnchorsHoverPart> = []
    /// Earlier chat pages the next message recalls into the agent's context.
    @PHState package var recalledChatPages: [StandaloneChatPage] = []
    /// The user started a new page from the composer: the next message runs without the last
    /// page's context. Until then the transcript ends on that page's separator.
    @PHState package var startsNewChatPage = false
    /// A send that started a new page is running; its separator stays above the turn until the
    /// turn is filed on that page.
    @PHState package var sendsNewChatPage = false
    /// The newest question the transcript has presented, which tells one just sent from it.
    @PHState package var lastScrolledUserMessageID: String?
    @PHState package var annotations: [ConversationAnnotation] = []
    /// Pending comments handed to the turn now running; they leave the saved draft until it ends.
    @PHState package var inFlightAnnotationIDs: Set<UUID> = []
    /// The selection whose comment popover or side chat bubble is open, which `selectionAction` names.
    @PHState package var annotationSelection: AnnotationSelection?
    @PHState package var selectionAction: SelectionAction = .sideChat
    @PHState package var currentTextSelection: AnnotationSelection?
    /// The task's side chats, saved or still answering their first question; ones with a source
    /// highlight their text purple. `SideChatStore` owns them, so they outlive this view.
    package var sideChats: [SavedSideChat] { SideChatStore.shared.sideChats(taskID: task.id) }
    @PHState package var activities: [ConversationActivity] = []
    /// Tool calls from every loaded turn, each shown in the timeline after the
    /// message it followed.
    @PHState package var timelineActivities: [ConversationActivity] = []
    /// A live turn shows its work: the disclosure opens as the turn starts and
    /// folds back into Worked for once the turn settles. A collapse the reader
    /// performs mid-turn stays collapsed until the next turn starts.
    @PHState package var isActivityExpanded = false
    /// The live operation that has run long enough for its own row; see `activeProcess`.
    @PHState package var settledActiveProcessID: String?
    @PHState package var responseStartedAt: Date?
    @PHState package var completedResponseDuration: Int?
    @PHState package var collapsedProgressTurnIDs = Set<String>()
    /// Automatic messages the reader expanded past their preview, by their full text: a
    /// streamed message gets a new id once history reloads, and its text stays the same.
    @PHState package var expandedAutomaticMessageTexts = Set<String>()
    /// Activity rows the reader expanded past their one-line header, by activity id.
    @PHState package var expandedActivityIDs = Set<String>()
    @PHState package var selectedSubagent: ConversationActivity?
    @PHState package var subagentHistory: ConversationHistory?
    /// Re-reads the open agent while it is still working.
    @PHState package var subagentRefresh: Task<Void, Never>?
    @PHState package var isLoadingSubagent = false
    @PHState package var subagentError: String?
    /// `props.workspace.revision` for the conversation sidebar's plugins (Changes is one),
    /// bumped whenever the task's folders may have changed.
    @PHState package var workspaceRevision = 0
    @PHAppStorage(WorkspaceSettings.taskSidebarCollapsedKey, store: WorkspaceSettings.preferencesStore) package var isTaskSidebarCollapsed = false
    /// Add Plugin mode shows the sidebar expanded, so its placements are visible, without
    /// changing the saved collapsed preference it returns to.
    @PHAppStorage(WorkspaceSettings.pluginAddModeKey, store: WorkspaceSettings.preferencesStore) package var isPluginAddModeOn = false
    @PHAppStorage(WorkspaceSettings.appearanceKey, store: WorkspaceSettings.preferencesStore) package var pluginAppearance = "dark"
    @PHEnvironment(PluginRegistry.self) package var pluginRegistry
    /// How far the chat sidebar has widened for the open page labels.
    @PHEnvironment(\.chatPageAnchorsPush) package var chatPageAnchorsPush
    /// A modal, sidebar or page plugin opened from this conversation's placements.
    @PHState package var openConversationPlugin: PluginRecord?
    @PHState package var isStartingPluginTask = false
    package var isTaskSidebarShownCollapsed: Bool { isTaskSidebarCollapsed && !isPluginAddModeOn }
    /// A real task shows its sidebar (Changes, terminal and Skills buttons); a standalone
    /// chat or a plugin's authoring chat shows only the conversation.
    package var hasTaskSidebar: Bool { !task.isStandaloneChat && task.authoringPluginID == nil }
    /// The open diff is rechecked one refresh at a time; a refresh asked for meanwhile runs once after.
    @PHState package var isRefreshingOpenDiff = false
    @PHState package var openDiffNeedsRefresh = false
    @PHState package var changeWatcher: WorkspaceChangeWatcher?
    @PHState package var isTerminalPresented = false
    @PHAppStorage(TerminalPanelLayout.widthKey, store: WorkspaceSettings.preferencesStore)
    package var terminalPanelWidth = Double(TerminalPanelLayout.defaultWidth)
    @PHState package var terminalResizeStartWidth: CGFloat?
    @PHState package var terminalSession = NativeViews.factory.makeTerminalSession()
    @PHState package var selectedChange: WorkspaceChangeEntry?
    @PHState package var selectedDiff: WorkspaceFileDiff?
    @PHState package var isDiffPresented = false
    @PHState package var isLoadingDiff = false
    @PHState package var diffError: String?
    @PHState package var isMonacoReady = false
    @PHState package var monacoPresentation: DiffEditorPresentation?
    @PHState package var monacoError: String?
    @PHState package var diffChangeCount: Int?
    @PHState package var isLoadingHistory = false
    /// False until this window's first history read finishes (messages, pending
    /// question and restored draft are in place). Before that the transcript's
    /// accessibility value says it is loading rather than reporting zero messages.
    @PHState package var hasLoadedConversation = false
    @PHState package var isApplyingSavedRepositories = false
    @PHState package var isResponding = false
    @PHState package var isPreparingSubmittedMessage = false
    @PHState package var hasPausedResponse = false
    /// The user stopped the response. The window shows the stop at once and keeps showing it
    /// while the provider winds the turn down (or finishes launching it, only to stop it), so
    /// until that turn is really over its activity doesn't bring the Stop button back.
    @PHState package var isPausingResponse = false
    @PHState package var confirmsStoppingBackgroundWork = false
    @PHState package var backgroundStopConfirmationID: String?
    @PHState package var interruptsInFlight = 0
    /// Identifies this window's newest send. An older send still unwinding after a stop leaves
    /// the composer state to the newer one.
    @PHState package var sendGeneration = 0
    @PHState package var sendsInFlight = 0
    /// Sends of this window still saving their prompt, before the daemon has them.
    @PHState package var sendsAwaitingDispatch = 0
    @PHState package var queuedMessages: [QueuedConversationMessage] = []
    /// A `.dispatching` follow-up is claimed for delivery: either reserved for a
    /// steer, or sent as its own turn and kept in the store until that whole turn
    /// ends. Only the others are still waiting for the user.
    package var waitingFollowUps: [QueuedConversationMessage] {
        queuedMessages.filter { $0.state != .dispatching && !steeringQueuedMessageIDs.contains($0.id) }
    }
    /// Steers shown in the transcript that the provider hasn't confirmed yet. They are
    /// delivered in the background, one at a time and in order.
    @PHState package var pendingLocalSteers: [PendingLocalSteer] = []
    @PHState package var steeringQueuedMessageIDs: Set<UUID> = []
    @PHState package var steerDeliveryTail: Task<Void, Never>?
    @PHState package var isSubmittingLiveMessage = false
    @PHState package var userInputRequest: ConversationUserInputRequest?
    // The live snapshot can still carry a request this window just answered.
    @PHState package var answeredUserInputRequestIDs: Set<String> = []
    // Safe replies this window streamed for secret recovery turns, which history hides.
    @PHState package var streamedRecoveryReplies: [String: String] = [:]
    // Text deltas waiting to be applied to `messages`; see `bufferStreamedTextDelta`.
    @PHState package var pendingTextDeltas = PendingStreamedTextDeltas()
    @PHState package var userInputAnswers: [String: [String]] = [:]
    @PHState package var userInputOther: [String: String] = [:]
    @PHState package var userInputOtherSelected: Set<String> = []
    @PHState package var asyncQuestionAnswers: [String: String] = [:]
    @PHState package var answeredAsyncQuestionIDs: Set<String> = []
    @PHState package var errorMessage: String?
    @PHState package var pluginBridgeRecoveryError: String?
    @PHState package var actionNotice: String?
    @PHState package var isShowingWorkspaceEditor = false
    @PHState package var isShowingRepositoryPicker = false
    /// The open suggestions folder panel; nil while none is open.
    @PHState package var repositoryParentPanel: (any FileChooserPanel)?
    @PHState package var repositorySearch = ""
    @PHState package var repositorySuggestionIndex = 0
    @PHState package var lastSelectedRepositoryPaths: [String] = []
    @PHState package var didOverrideRepositoryDefault = false
    @PHState package var suggestedRepositories: [URL] = []
    @PHState package var expandedRepositoryPath: String?
    /// The chip whose settings popover is open, by its chip key: unlike the record, the key
    /// stays the same while a pending worktree's branch is edited.
    @PHState package var repositoryBeingEditedKey: String?
    package var repositoryBeingEdited: RepositoryWorktreeRecord? {
        get { repositoryBeingEditedKey.flatMap { task.repositoryWorktrees.record(chipKey: $0) } }
        nonmutating set { repositoryBeingEditedKey = newValue.flatMap { task.repositoryWorktrees.chipKey(of: $0) } }
    }
    /// The chip settings' Add worktree branch field; empty names the branch from the task title.
    @PHState package var newWorktreeBranch = ""
    @PHState package var isAddingWorktree = false
    @PHState package var editedBranch = ""
    @PHState package var editedBranchFrom = ""
    @PHState package var editedMergeTarget = ""
    @PHState package var editingRepositoryField: String?
    @PHState package var recentRepositoryPaths: [String] = []
    @PHFocusState package var focusedRepositoryField: String?
    @PHFocusState package var isComposerFocused: Bool

    package var isSendDisabled: Bool {
        isApplyingSavedRepositories || (draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pendingImages.isEmpty && !annotations.contains(where: \.pending) && !isEnteringGoal) || isDisplayingActiveResponse || isStopLandingOnOwnSend || isLoadingHistory || !hasLoadedConversation || userInputRequest != nil
    }

    /// A new task can use either schedule, and a recurring template can be edited; an existing
    /// conversation can schedule a one-time message.
    package var canSchedule: Bool {
        task is BoardTask && !isReadOnly
    }

    /// The schedule saved on the task, which the hint edits.
    package var savedSchedule: ComposerSchedule? {
        (task as? BoardTask).flatMap(ComposerSchedule.init(task:))
    }

    package var isExistingConversation: Bool {
        guard let boardTask = task as? BoardTask else { return false }
        return boardTask.activeConversationID != nil || boardTask.pendingSubmittedPrompt != nil
            || !(boardTask.status == .backlog || boardTask.status == .blocked)
    }

    package var isScheduleSendDisabled: Bool {
        isApplyingSavedRepositories || isSavingSchedule || isLoadingHistory
            || (draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pendingImages.isEmpty)
    }

    package var isRepositoryRootConfigured: Bool {
        // Standalone chat has no repository/worktree of its own, so it must never require the
        // app's global repository-root setting to be configured before sending.
        task.isStandaloneChat || task.authoringPluginID != nil || WorkspaceSettings.validDirectoryURL(for: defaultParentFolderPath) != nil
    }

    package var conversationRuntime: ConversationRuntimeModel.Untracked { runtimeModel.untracked }

    package var provider: ConversationProvider { switchedProvider ?? task.conversationProvider }

    /// Observed so the view refreshes when this task's turn starts or ends.
    /// Claude runs conversations in parallel, so a client-wide flag would miss
    /// this task's edge while another conversation keeps running.
    package var providerTurnIsActive: Bool {
        // A new conversation whose ID this window's model hasn't picked up from the daemon yet,
        // such as a plugin editor's first turn, is followed by its task's turn instead.
        guard let threadID = task.activeConversationID else { return conversationRuntime.isTurnActive(taskID: task.id) }
        return conversationRuntime.isTurnActive(threadID: threadID)
    }

    /// Claude can hold a pending question in several conversations at once, so
    /// this task reads the question from its own session rather than from the
    /// client-wide value.
    package var providerPendingUserInputRequest: ConversationUserInputRequest? {
        conversationRuntime.pendingUserInputRequest(forThread: task.activeConversationID ?? "")
    }

    /// The plan exists only once a first message was sent and the agent is not
    /// waiting on the user's answer to its questions.
    package var canShowStartImplementing: Bool {
        conversationMode == .plan && !isResponding && !isReadOnly
            && messages.contains(where: { $0.role == .user })
            && userInputRequest == nil && providerPendingUserInputRequest == nil
    }

    /// Why a task's plan can't be handed off to an implementation turn yet; transient loading
    /// states also disable the button but need no explanation. A chat never has a workspace
    /// root or a repository picker, so it keeps its disabled button without this reason.
    package var startImplementingUnavailableReason: String? {
        guard !task.isStandaloneChat else { return nil }
        return PlanImplementationHandoff.unavailableReason(workspaceRootPaths: task.workspaceRootPaths)
    }

    package var archivedFollowUpHint: String {
        let target = task.repositoryWorktrees.compactMap(\.mergeTarget).first
        return "Archived · a follow-up reopens this task in a fresh worktree from \(target ?? "the merge target")"
    }

    /// Provider switches wait for active turns and queued follow-ups to settle.
    package var canSwitchProvider: Bool {
        !isReadOnly && !isResponding && !isLoadingHistory && !isPreparingSubmittedMessage && !isSwitchingProvider
            && userInputRequest == nil && queuedMessages.isEmpty && task.status != .done
    }

    package var approvalNotice: String {
        "\(provider.displayName) requested an approval. Playhouse denied it because approval prompts are disabled."
    }

    package var diffHighlightStatus: String {
        guard let diffChangeCount else { return "Calculating changes…" }
        guard diffChangeCount > 0 else { return "No text changes" }
        return "\(diffChangeCount) change\(diffChangeCount == 1 ? "" : "s") highlighted"
    }

    /// Describes the editor the diff is actually rendered in: Monaco is loaded once per
    /// session, so a later diff reports the same editor it reused.
    package var monacoStartupDescription: String {
        guard isMonacoReady, let monacoPresentation else { return "Starting editor" }
        let reuse = monacoPresentation.reusedWarmEditor ? "reused" : "loaded"
        return "Editor \(monacoPresentation.editorTag) \(reuse), showing \(monacoPresentation.path)"
    }

    /// The user's newest message, steers included: the provider turn answering it is the latest
    /// one. Status nudges Playhouse sends after it continue that turn rather than start a new one.
    package static func latestUserTurnStart(in messages: [ConversationMessage]) -> Int? {
        messages.lastIndex { $0.role == .user && !$0.isPlayhouseSent }
    }

    package var latestConversationTurnID: String? {
        if let latestUserIndex = Self.latestUserTurnStart(in: messages) {
            return messages.dropFirst(latestUserIndex + 1).first(where: {
                $0.role == .assistant && $0.turnID != nil
            })?.turnID ?? messages[latestUserIndex].turnID
        }
        return messages.last(where: { $0.turnID != nil })?.turnID
    }

    package var progressMessageIDs: Set<String> {
        guard let latestConversationTurnID,
              collapsedProgressTurnIDs.contains(latestConversationTurnID) else { return [] }
        return Set(messages.lazy.filter {
            $0.role == .assistant && $0.phase == "commentary" && $0.turnID == latestConversationTurnID
        }.map(\.id))
    }

    package var progressMessages: [ConversationMessage] {
        // Computed once: reading the property inside the filter rebuilt the set for every message.
        let ids = progressMessageIDs
        guard !ids.isEmpty else { return [] }
        return messages.filter { ids.contains($0.id) }
    }

    package var conversationMessages: [ConversationMessage] {
        let completedProgressIDs = progressMessageIDs
        // Read on every layout pass and every scroll sample, so the common case
        // of nothing collapsed must not copy the transcript.
        guard !completedProgressIDs.isEmpty else { return messages }
        return messages.filter { !completedProgressIDs.contains($0.id) }
    }

    /// Messages a conversation that established no window keeps rendered while it follows.
    package static let followedConversationMessageCount = 40
    /// Older messages revealed at a time as the reader nears the oldest rendered one. Each is
    /// rendered to be measured, so a few at a time keep scrolling up from stalling on a batch.
    package static let olderConversationMessageBatchSize = 2
    /// Loaded messages left above the rendered window when the next older page is read.
    package static let olderConversationMessagePrefetchCount = 20
    /// Messages read per history request: the newest page on open, then one
    /// more page each time the rendered window reaches the oldest loaded one.
    package static let historyPageSize = ConversationHistory.windowPageSize
    /// Messages a conversation renders when it opens, at most. A newest turn with more, as a
    /// long run of replies or a running turn's progress makes, opens on its newest messages;
    /// older ones render as the viewport needs them. Every row renders before it is measured,
    /// so opening on a whole long turn held the first frame up for seconds.
    package static let openedConversationMessageCount = 6

    /// Builds the Swift runtime metadata of this view's body type, which the first
    /// open of a conversation otherwise builds on the main thread before its first
    /// frame. The runtime caches it for the session and is safe from any thread.
    @discardableResult
    package nonisolated static func prepareBodyTypeMetadata() -> any PHView.Type {
        prepareBodyTypeMetadata(of: Self.self)
    }

    /// Reached generically, as SwiftUI reaches it: that path resolves the body's
    /// conformances, which naming the concrete `Body` type directly leaves for later.
    private nonisolated static func prepareBodyTypeMetadata<V: PHView>(of _: V.Type) -> any PHView.Type {
        V.Body.self
    }

    /// First message of the newest user turn. Opening a conversation renders
    /// this message and everything after it, so the latest question sits at the
    /// top of the viewport with its answer below.
    package var latestConversationTurnStartID: String? {
        let allMessages = conversationMessages
        return ConversationMessage.latestTurnStartIndex(in: allMessages, continuingIDs: liveSteerMessageIDs).map { allMessages[$0].id }
    }

    /// Where the rendered window starts when the conversation opens: the newest turn's first
    /// message when the turn has at most `openedConversationMessageCount` messages, otherwise
    /// the first of the newest that many.
    package var openingWindowStartID: String? {
        let allMessages = conversationMessages
        guard let turnStart = ConversationMessage.latestTurnStartIndex(in: allMessages, continuingIDs: liveSteerMessageIDs) else { return nil }
        return allMessages[max(turnStart, allMessages.count - Self.openedConversationMessageCount)].id
    }

    /// The window runs from `oldestRenderedMessageID` to the newest message, or to
    /// `renderedWindowEndID` while the reader browses an earlier chat page.
    /// A conversation that was empty when it loaded establishes no window of
    /// its own, so it keeps the newest batch rendered as messages arrive.
    package var renderedConversationMessages: [ConversationMessage] {
        let allMessages = conversationMessages
        guard let oldestRenderedMessageID,
              let startIndex = allMessages.firstIndex(where: { $0.id == oldestRenderedMessageID }) else {
            return Array(allMessages.suffix(Self.followedConversationMessageCount))
        }
        if let endIndex = renderedWindowEndIndex(in: allMessages, from: startIndex) {
            return Array(allMessages[startIndex...endIndex])
        }
        return Array(allMessages[startIndex...])
    }

    package var hasOlderConversationMessages: Bool {
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

    /// The turn's work sits above its first reply, or above a message steered into it before
    /// any reply. A steer continues the turn the user started, so work done before a steer
    /// never renders below it. When a later provider turn, such as one a Playhouse nudge woke,
    /// is the turn whose work the disclosure lists, the work sits where that turn's replies begin.
    package var activityDisclosureAnchorID: String? {
        let messages = conversationMessages
        if let turnStart = messages.indices.last(where: {
            ConversationMessage.startsUserTurn(at: $0, in: messages, continuingIDs: liveSteerMessageIDs)
        }) {
            let candidates = messages.dropFirst(turnStart + 1).filter {
                $0.role == .assistant || ($0.role == .user && !$0.isPlayhouseSent)
            }
            if let turnID = latestConversationTurnID,
               let first = candidates.first(where: { $0.turnID == turnID }) {
                return first.id
            }
            return candidates.first?.id
        }
        return conversationMessages.first(where: { $0.role == .assistant })?.id
    }

    package var shouldShowActivityDisclosure: Bool {
        !activities.isEmpty || !progressMessageIDs.isEmpty || isResponding || completedResponseDuration != nil || hasCompletedAssistantResponse
    }

    package var hasCompletedAssistantResponse: Bool {
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

    package var isDisplayingActiveResponse: Bool {
        isResponding && !hasCompletedAssistantResponse
    }

    package var responseStartedAtDefaultsKey: String {
        TaskPreferenceKeys.responseStartedAt(taskID: task.id)
    }

    package var completedResponseDurationDefaultsKey: String {
        TaskPreferenceKeys.completedResponseDuration(taskID: task.id)
    }

    package var goalAchievementTimelineDefaultsKey: String {
        TaskPreferenceKeys.goalAchievementTimeline(taskID: task.id)
    }

    package var goalGenerationDefaultsKey: String {
        CodexGoalGenerationStore.generationIDKey(taskID: task.id)
    }

    package var goalGenerationObjectiveDefaultsKey: String {
        CodexGoalGenerationStore.objectiveKey(taskID: task.id)
    }

    package var goalGenerationTimeBaselineDefaultsKey: String {
        CodexGoalGenerationStore.timeBaselineKey(taskID: task.id)
    }

    /// The first part of `body`'s modifier chain, split off so the type checker handles each part in time.
    private var conversationBase: some PHView {
        PHGroup {
            if !hasTaskSidebar {
                // The standalone chat sidebar reuses only the conversation transcript/composer,
                // not the repo-specific "Changes" sidebar a real task's worktree needs.
                conversationPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                PHHStack(spacing: 0) {
                    taskSidebar

                    PHRectangle()
                        .fill(PHColor.primary.opacity(0.08))
                        .frame(width: 1)

                    conversationPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                // The terminal floats over the conversation's right edge rather than taking
                // its width, so opening it never reflows the transcript or the composer.
                .overlay(alignment: .trailing) {
                    if isTerminalPresented {
                        PHGeometryReader { geometry in
                            let available = conversationWidth(in: geometry.size.width)
                            let width = TerminalPanelLayout.clampedWidth(CGFloat(terminalPanelWidth), available: available)
                            PHHStack(spacing: 0) {
                                terminalResizeHandle(width: width, available: available)
                                PHNativeTerminalPanel(
                                    session: terminalSession,
                                    workspaceManager: workspaceManager,
                                    onClose: { setTerminalPresented(false) }
                                )
                            }
                            .frame(width: width)
                            .phShadow(color: .black.opacity(0.22), radius: 12, x: -4, y: 0)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                        }
                        .transition(.move(edge: .trailing))
                    }
                }
                .clipped()
            }
        }
        .background(WorkspaceTheme.windowBackground)
        .alert("Stop background work?", isPresented: $confirmsStoppingBackgroundWork, presenting: backgroundStopConfirmationID) { confirmationID in
            PHButton("Keep Running", role: .cancel) {}
                .buttonHoverPointer()
                .nativeHelp("Leave the turn and its background work running")
            PHButton("Stop All", role: .destructive) { pauseResponse(confirmationID: confirmationID) }
                .buttonHoverPointer()
                .nativeHelp("Stop the turn and end its background work")
        } message: { _ in
            PHText("This conversation has running background work. Stopping will end that work.")
        }
        .pluginPresentation($openConversationPlugin, props: pluginProps, actions: pluginActions)
        .onChange(of: task.id, initial: true) {
            runtimeSlice.observe(runtimeModel, taskID: task.id.uuidString) { [task] in
                task.allConversationIDs
            }
        }
        .onAppear {
            if !isReadOnly,
               let savedMode = WorkspaceSettings.preferencesStore.string(forKey: conversationModeDefaultsKey),
               let mode = ConversationMode(rawValue: savedMode) {
                conversationMode = mode
            }
            conversationContextMode = (try? conversationManager.contextMode(taskID: task.id)) ?? .full
            // A task that hasn't started reopens with Send in schedule mode. An existing
            // conversation's scheduled message waits in the composer, and Send sends it now.
            if let schedule = savedSchedule, !isExistingConversation {
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
        .sheet(isPresented: PHBinding(
            get: { selectedChatImage != nil },
            set: { if !$0 { selectedChatImage = nil } }
        )) {
            if let selectedChatImage {
                PHVStack(alignment: .trailing, spacing: 8) {
                    PHButton("Close") { self.selectedChatImage = nil }
                        .accessibilityIdentifier("close-chat-image-viewer")
                        .buttonHoverPointer()
                        .shortcutHelp("Close the full-size image", shortcut: "cancel")
                    PHImage(platformImage: selectedChatImage)
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
                .background(PHSheetOutsideClickDismissal { self.selectedChatImage = nil })
            }
        }
        .overlay(alignment: .topLeading) { skillsPage }
        .task {
            // Synchronous, so the picker shows the cached model name on the
            // first frame instead of "Default" while the conversation and a
            // fresh model list are still round-tripping through the bridge.
            if !isReadOnly { primeModelOptionsFromCache() }
            if !isReadOnly { refreshQueuedMessages() }
            // One request reconciles the task's status and reads the transcript; its draft and
            // pending prompt are restored from the record the daemon returns with it. The
            // request leaves now rather than once the main actor is free: building a
            // conversation's first frame keeps it busy, longest on the first open of a
            // session, and the daemon reads meanwhile.
            let historyRead = if #available(macOS 26.0, *) {
                Task.immediate { try await readHistoryOnOpen() }
            } else {
                Task { try await readHistoryOnOpen() }
            }
            // The chat's pages are a quick local read, so the labels and the transcript's page
            // separators are ready for its first frame rather than waiting on the provider's
            // model list below, which can take seconds on a cold start.
            if task.isStandaloneChat { refreshChatPageStatus() }
            await withTaskCancellationHandler {
                if !isReadOnly, let request = providerPendingUserInputRequest, request.threadID == task.activeConversationID {
                    userInputRequest = request
                }
                await loadConversation(pendingRead: historyRead)
            } onCancel: {
                historyRead.cancel()
            }
            if !isReadOnly {
                refreshQueuedMessages()
                await loadProviderInstallStatuses(adoptInstalledProvider: true)
                await loadModels()
            }
            if isNewTask {
                await Task.yield()
                isComposerFocused = true
            }
            if let initialDraft, !initialDraft.isEmpty, draft.isEmpty, !isReadOnly,
                      !isResponding, messages.isEmpty, task.pendingSubmittedPrompt == nil {
                draft = initialDraft
            } else if let skillFixPrompt, !isReadOnly, !isResponding, messages.isEmpty, task.pendingSubmittedPrompt == nil {
                // Sent as the composer's own draft, so the composer clears as for any send.
                draft = skillFixPrompt
                sendMessage()
            }
        }
    }

    package var body: some PHView {
        // Transcript rows read the side chats inside row and layout closures; reading them here
        // too re-renders the rows' purple highlights whenever one is saved or starts answering,
        // however those closures are tracked. Streaming deltas are not read, so they don't.
        let _ = sideChats
        // This task's slice of the runtime snapshot; the model itself is read untracked.
        let _ = runtimeSlice.changeCount
        conversationBase
        .onChange(of: task.conversationProvider) { _, saved in
            // The saved switch reached this window's task, or another client switched it since.
            if !isSwitchingProvider || saved == switchedProvider { switchedProvider = nil }
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
        // The suggestion folder can change from the repository picker or from Settings; the
        // picker must never list the previous folder's repositories under the new one.
        .onChange(of: defaultParentFolderPath) { _, _ in
            suggestedRepositories = []
            loadSuggestedRepositories()
        }
        .onChange(of: providerTurnIsActive) { _, isTurnActive in
            if isTurnActive { watchRunningTurnIfNeeded() }
            if !isTurnActive, task.isStandaloneChat { refreshChatPageStatus() }
            if !isTurnActive, !isReadOnly {
                refreshQueuedMessages()
                // A reload while the turn still read as active keeps what this window shows, so a
                // turn that failed to start would leave its dropped prompt here. Reload once it ends.
                followHistory()
            }
            // A stop already shows. The stopped turn winding down, or starting late only to
            // be stopped, changes nothing until it is over.
            if isPausingResponse {
                settleLocalStopIfDone()
                return
            }
            // A send made right after a stop owns the responding state while the stopped
            // turn's send is still unwinding.
            if sendsInFlight > 1 { return }
            let submittedTurnIsPending = task.pendingSubmittedPrompt != nil
                && (task.status == .inProgress || task.status == .waitingResponse)
            guard let taskThreadID = task.activeConversationID else {
                isResponding = submittedTurnIsPending || isTurnActive
                return
            }
            let completedTurnIsVisible = hasCompletedAssistantResponse && !isTurnActive
            isResponding = completedTurnIsVisible
                ? false
                : submittedTurnIsPending || isTurnActive
            // A turn stopped while this window followed it (not sent from it) can still be continued.
            if !isTurnActive, !isResponding, conversationRuntime.wasLastTurnInterrupted(threadID: taskThreadID) {
                hasPausedResponse = true
            }
        }
        .onChange(of: task.pendingSubmittedPrompt == nil) { _, cleared in
            // The daemon clears the submitted prompt after the turn ends, which can be after
            // this window saw it end. A turn parked on a question is not over, even while the
            // runtime snapshot lags, so leave the answer flow to settle it.
            if cleared { settleLocalStopIfDone() }
            if cleared, isResponding, !providerTurnIsActive, sendsInFlight == 0,
               userInputRequest == nil, providerPendingUserInputRequest == nil,
               !conversationRuntime.isTurnActive(threadID: task.activeConversationID ?? "") {
                isResponding = false
            }
        }
        .onChange(of: task.hasUnsentDraft) { wasUnsent, isUnsent in
            // A scheduled message waits in the composer as its draft. When the scheduler sends
            // it, the saved draft becomes the sent prompt, and the composer still showing that
            // message clears; a draft the user changed meanwhile stays.
            guard wasUnsent, !isUnsent, !isReadOnly else { return }
            let shown = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !shown.isEmpty || !pendingImages.isEmpty,
                  shown == (task.savedPrompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            draftAutosaveTask?.cancel()
            draft = ""
            composerDraft.settledText = ""
            pendingImages = []
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
            // A bubble sent or closed while the chat answers moves its placeholder at once.
            if task.isStandaloneChat { refreshParallelChatPlaceholders() }
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
        .task(id: WorkspaceWatchKey(roots: task.workspaceRootPaths, isWatched: !pluginRegistry.inlinePlugins(for: .conversationSidebar).isEmpty)) {
            // Only a sidebar plugin reads the folders, so with none (Changes disabled) nothing watches them.
            guard !pluginRegistry.inlinePlugins(for: .conversationSidebar).isEmpty else {
                changeWatcher?.stop()
                changeWatcher = nil
                return
            }
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
            subagentRefresh?.cancel()
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
    package func historyIfSendReachedConversation(_ text: String, after anchorID: String?) async -> ConversationHistory? {
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


    package func standaloneChatPageSeparator(before message: ConversationMessage) -> StandaloneChatPage? {
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
    package func standaloneChatPageIDs(for pendingAnnotations: [ConversationAnnotation]) -> [String] {
        guard task.isStandaloneChat, !pendingAnnotations.isEmpty else { return [] }
        let activePageID = activeChatPageID
        var pageIDs: [String] = []
        for annotation in pendingAnnotations {
            guard let turnID = messages.first(where: { $0.id == annotation.messageID })?.turnID,
                  let pageID = chatPagesByTurnID[turnID]?.id,
                  pageID != activePageID, !pageIDs.contains(pageID) else { continue }
            pageIDs.append(pageID)
        }
        return pageIDs
    }

    /// A page's title between two rules. An earlier page also offers to be recalled: the next
    /// message then carries that page's conversation to the agent.
    package func standaloneChatPageSeparator(_ page: StandaloneChatPage, canRecall: Bool) -> some PHView {
        AtomStack(props: StackProps(axis: "h", spacing: 12, group: true), common: AtomCommon(paddingY: 5)) {
            transcriptRule(opacity: 0.13)
            // The title gives way to the button in a narrow chat.
            AtomText(props: TextProps(text: page.title, size: 11, weight: "semibold", color: "secondary", lineLimit: 1), common: AtomCommon(testID: "chat-page-separator"))
                .layoutPriority(1)
            if canRecall {
                ChatPageRecallButton(pageID: page.id) { recallChatPage(page) }
            }
            transcriptRule(opacity: 0.13)
        }
    }


    /// Text and images handed to the active turn or the queue leave the saved draft
    /// at once, so reopening the task doesn't restore them to the composer.
    package func clearHandedOffDraft() {
        composerDraft.settledText = ""
        draft = ""
        pendingImages.removeAll()
        persistDraft()
    }


}

extension PHView {
    /// One accessibility element that reads as `label`. On macOS an atom Text,
    /// Label or combined stack reports its text as a value, which hides an
    /// explicit label, so these rows replace their children instead.
    package func accessibilitySummary(_ label: String, id: String) -> some PHView {
        accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityIdentifier(id)
    }
}

/// What the task's folder watcher watches: the task's folders, and only while a conversation
/// sidebar plugin reads them.
package struct WorkspaceWatchKey: Hashable {
    package let roots: [String]
    package let isWatched: Bool

    package init(roots: [String], isWatched: Bool) {
        self.roots = roots
        self.isWatched = isWatched
    }
}
