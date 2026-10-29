import AppKit
import ImageIO
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Shared by `CodeBlockTextView` and `SelectableAnnotationText`'s `sizeThatFits`: lays the given
/// attributed string out in a throwaway text container at `width` and returns its used height.
private func measuredTextHeight(for attributedText: NSAttributedString, width: CGFloat) -> CGFloat {
    let storage = NSTextStorage(attributedString: attributedText)
    let layoutManager = NSLayoutManager()
    let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
    container.lineFragmentPadding = 0
    layoutManager.addTextContainer(container)
    storage.addLayoutManager(layoutManager)
    layoutManager.ensureLayout(for: container)
    return layoutManager.usedRect(for: container).height
}

private struct AssistantMarkdownBlock: Identifiable {
    enum Kind {
        case heading(Int)
        case listItem
        case orderedListItem(number: Int)
        case codeBlock(language: String?)
        case paragraph
    }

    let id: Int
    let kind: Kind
    let text: String

    var font: NSFont {
        switch kind {
        case .heading(let level): NSFont.systemFont(ofSize: level == 1 ? 19 : level == 2 ? 17 : 15, weight: .semibold)
        case .listItem, .orderedListItem, .paragraph: NSFont.systemFont(ofSize: 16)
        case .codeBlock: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        }
    }
}

private struct CodeBlockCardView: View {
    let blockID: Int
    let code: String
    let language: String?
    let font: NSFont

    @State private var didCopy = false
    @State private var copyFeedbackToken = UUID()

    private var languageDisplayName: String {
        guard let language, !language.isEmpty else { return "Code" }
        return language.prefix(1).uppercased() + language.dropFirst()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                Text(languageDisplayName)
                    .font(.system(size: 12, weight: .medium))
                    .accessibilityIdentifier("assistant-markdown-code-block-language-\(blockID)")
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    didCopy = true
                    let token = UUID()
                    copyFeedbackToken = token
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        if copyFeedbackToken == token { didCopy = false }
                    }
                } label: {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .buttonHoverPointer()
                .help("Copy code")
                .accessibilityLabel("Copy code")
                .accessibilityIdentifier("assistant-markdown-code-block-copy-\(blockID)")
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider().opacity(0.15)

            CodeBlockTextView(attributedText: CodeSyntaxHighlighter.highlight(code, language: language, font: font))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
        .background(WorkspaceTheme.inputBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct CodeBlockTextView: NSViewRepresentable {
    let attributedText: NSAttributedString

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textStorage?.setAttributedString(attributedText)
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        guard view.textStorage?.string != attributedText.string else { return }
        view.textStorage?.setAttributedString(attributedText)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        let width = max(40, proposal.width ?? 500)
        guard let renderedText = nsView.textStorage else { return nil }
        let contentHeight = measuredTextHeight(for: renderedText, width: width)
        return CGSize(width: width, height: ceil(contentHeight) + 2)
    }
}

private struct ConversationAnnotation: Identifiable, Codable {
    let id: UUID
    let messageID: String
    let blockID: Int
    let startOffset: Int
    let endOffset: Int
    let text: String
    let comment: String
    var pending = true
}

private struct ResponseAnnotationReference {
    let text: String
    let comment: String
}

private struct ResponseCommentHoverCard: View {
    let selectedText: String
    let comment: String
    @State private var isVisible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Highlighted text")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(selectedText)
                    .font(.system(size: 12))
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .accessibilityIdentifier("response-comment-highlighted-text")
                    .accessibilityLabel(selectedText)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Comment")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(comment)
                    .font(.system(size: 12))
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .accessibilityIdentifier("response-comment-content")
                    .accessibilityLabel(comment)
            }
        }
        .padding(12)
        .frame(width: 320, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .opacity(isVisible ? 1 : 0)
        .onAppear {
            withAnimation(.easeIn(duration: 0.12)) {
                isVisible = true
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("response-comment-hover-card")
        .accessibilityLabel("Highlighted text: \(selectedText). Comment: \(comment)")
    }
}

private final class CommentTrackingTextView: NSTextView {
    var hoverTrackingOwner: AnyObject?
    private var hoverTrackingArea: NSTrackingArea?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard hoverTrackingArea == nil, let hoverTrackingOwner else { return }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: hoverTrackingOwner,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }
}

private struct AnnotationSelection: Identifiable {
    let id = UUID()
    let messageID: String
    let blockID: Int
    let range: NSRange
    let text: String
    let bounds: CGRect
}

struct TaskConversationView: View {
    private struct PendingImage: Identifiable {
        let id = UUID()
        let dataURL: String
        let image: NSImage
    }
    private struct RepositoryBadgeEditID: Identifiable, Equatable {
        let path: String
        var id: String { path }
    }

    private struct ChangeRepositoryGroup: Identifiable {
        let repository: String
        let entries: [WorkspaceChangeEntry]
        var id: String { repository }
    }

    private struct GoalAchievementTimelineEntry: Codable, Identifiable, Equatable {
        let id: String
        let summary: String
        let afterMessageID: String

        static let beforeFirstMessageID = "__before_first_message__"
    }

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var codexClient: CodexAppServerClient
    @EnvironmentObject private var claudeClient: ClaudeCodeClient
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(WorkspaceSettings.defaultParentFolderKey, store: WorkspaceSettings.preferencesStore) private var defaultParentFolderPath = ""

    let task: BoardTask
    var isNewTask = false
    var isReadOnly = false
    var conflictResolutionRequested = false
    var onConflictResolutionChecked: (Bool) -> Void = { _ in }
    let onBack: () -> Void

    @State private var draft = ""
    @State private var composerHeight: CGFloat = 28
    @State private var draftAutosaveTask: Task<Void, Never>?
    @State private var draftNeedsAutosave = false
    @State private var pendingImages: [PendingImage] = []
    @State private var isShowingImagePicker = false
    @State private var selectedChatImage: NSImage?
    @State private var isGeneratingTitle = false
    @State private var conversationMode: ConversationMode = .code
    @State private var isEnteringGoal = false
    @State private var activeGoal: CodexThreadGoal?
    @State private var goalAchievementTimelineEntries: [GoalAchievementTimelineEntry] = []
    @State private var currentGoalGenerationID: String?
    @State private var currentGoalObjective: String?
    @State private var currentGoalTimeBaselineSeconds: Double?
    @State private var isGoalExpanded = false
    @State private var goalStatusUpdatedAt = Date.now
    @State private var modelOptions: [ConversationModelOption] = []
    @State private var selectedModelID = ""
    @State private var selectedEffort: ConversationEffort = .medium
    @State private var pickerModelID = ""
    @State private var pickerEffort: ConversationEffort = .medium
    @State private var isModelPickerPresented = false
    @State private var providerBoundaries: [ConversationProviderBoundary] = []
    @State private var isSwitchingProvider = false
    @State private var providerNotice: String?
    @State private var messages: [ConversationMessage] = []
    // Oldest message currently rendered in the transcript. The transcript keeps a
    // window that starts here and runs to the newest message; opening a
    // conversation starts the window at the latest user turn.
    @State private var oldestRenderedMessageID: String?
    @State private var isRevealingOlderConversationMessages = false
    /// Set once the transcript has settled at or above the top of its rendered
    /// window, which is what makes the next upward scroll reveal older
    /// messages. Position has to be observed, never assumed, or a layout pass
    /// taken before the newest turn is pinned reveals a batch on open.
    @State private var isOlderConversationRevealArmed = false
    /// True from the start of a history load until the newest turn has been
    /// pinned, so load-time scroll requests cannot follow the bottom past it.
    @State private var isLatestConversationTurnPinPending = true
    @State private var hasPresentedLatestConversation = false
    /// Natural height of the rendered transcript, before the filler that keeps
    /// the newest turn pinnable to the top of the viewport.
    @State private var conversationContentHeight: CGFloat = 0
    @State private var lastScrolledUserMessageID: String?
    @State private var annotations: [ConversationAnnotation] = []
    @State private var annotationSelection: AnnotationSelection?
    @State private var currentTextSelection: AnnotationSelection?
    @State private var annotationComment = ""
    @State private var activities: [ConversationActivity] = []
    @State private var isActivityExpanded = false
    @State private var responseStartedAt: Date?
    @State private var completedResponseDuration: Int?
    @State private var collapsedProgressTurnIDs = Set<String>()
    @State private var selectedSubagent: ConversationActivity?
    @State private var subagentHistory: ConversationHistory?
    @State private var isLoadingSubagent = false
    @State private var subagentError: String?
    @State private var changeInventory = WorkspaceChangeInventory(unviewed: [], viewed: [])
    @State private var isViewedSectionExpanded = false
    @State private var isLoadingChanges = false
    @State private var changesNeedRefresh = false
    @State private var changeWatcher: WorkspaceChangeWatcher?
    @State private var changesError: String?
    @State private var selectedChange: WorkspaceChangeEntry?
    @State private var selectedDiff: WorkspaceFileDiff?
    @State private var isDiffPresented = false
    @State private var isLoadingDiff = false
    @State private var diffError: String?
    @State private var isMonacoReady = false
    @State private var monacoError: String?
    @State private var diffChangeCount: Int?
    @State private var isLoadingHistory = false
    @State private var isApplyingSavedRepositories = false
    @State private var isResponding = false
    @State private var isPreparingSubmittedMessage = false
    @State private var conflictResolutionAttempt = 0
    @State private var hasPausedResponse = false
    @State private var isPausingResponse = false
    @State private var queuedMessages: [QueuedConversationMessage] = []
    @State private var isSubmittingLiveMessage = false
    @State private var userInputRequest: ConversationUserInputRequest?
    @State private var userInputAnswers: [String: [String]] = [:]
    @State private var userInputOther: [String: String] = [:]
    @State private var userInputOtherSelected: Set<String> = []
    @State private var asyncQuestionAnswers: [String: String] = [:]
    @State private var answeredAsyncQuestionIDs: Set<String> = []
    @State private var errorMessage: String?
    @State private var actionNotice: String?
    @State private var isShowingWorkspaceEditor = false
    @State private var isShowingRepositoryPicker = false
    @State private var isChoosingRepositoryParent = false
    @State private var repositorySearch = ""
    @State private var repositorySuggestionIndex = 0
    @State private var lastSelectedRepositoryPaths: [String] = []
    @State private var didOverrideRepositoryDefault = false
    @State private var suggestedRepositories: [URL] = []
    @State private var expandedRepositoryPath: String?
    @State private var repositoryBeingEdited: RepositoryWorktreeRecord?
    @State private var editedBranch = ""
    @State private var editedBranchFrom = ""
    @State private var editedMergeTarget = ""
    @State private var editingRepositoryField: String?
    @FocusState private var isComposerFocused: Bool
    @FocusState private var isRepositorySearchFocused: Bool

    private var isSendDisabled: Bool {
        !isRepositoryRootConfigured || isApplyingSavedRepositories || (draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pendingImages.isEmpty && !annotations.contains(where: \.pending) && !isEnteringGoal) || isDisplayingActiveResponse || isLoadingHistory || userInputRequest != nil
    }

    private var isRepositoryRootConfigured: Bool {
        WorkspaceSettings.validDirectoryURL(for: defaultParentFolderPath) != nil
    }

    private var canPauseResponse: Bool {
        guard let threadID = task.activeConversationID else { return false }
        return providerClient.canInterruptActiveTurn(threadID: threadID)
    }

    private var provider: ConversationProvider { task.conversationProvider }

    private var conversationClients: ConversationClients {
        ConversationClients(codex: codexClient, claude: claudeClient)
    }

    /// The runtime that runs this task's turns.
    private var providerClient: ConversationProviderClient {
        conversationClients.client(for: provider)
    }

    /// Observed so the view refreshes when this task's turn starts or ends.
    /// Claude runs conversations in parallel, so a client-wide flag would miss
    /// this task's edge while another conversation keeps running.
    private var providerTurnIsActive: Bool {
        guard provider == .claude else { return codexClient.isTurnActive(threadID: task.activeConversationID ?? "") }
        guard let threadID = task.activeConversationID else { return claudeClient.isTurnActive }
        return claudeClient.activeThreadIDs.contains(threadID)
    }

    /// Claude can hold a pending question in several conversations at once, so
    /// this task reads the question from its own session rather than from the
    /// client-wide value.
    private var providerPendingUserInputRequest: ConversationUserInputRequest? {
        provider == .claude
            ? claudeClient.pendingUserInputRequest(forThread: task.activeConversationID ?? "")
            : codexClient.pendingUserInputRequest(forThread: task.activeConversationID ?? "")
    }

    private var isConversationTurnActive: Bool {
        providerClient.isTurnActive(threadID: task.activeConversationID ?? "")
    }

    /// Provider switches wait for active turns and queued follow-ups to settle.
    private var canSwitchProvider: Bool {
        !isReadOnly && !isResponding && !isLoadingHistory && !isPreparingSubmittedMessage && !isSwitchingProvider
            && userInputRequest == nil && queuedMessages.isEmpty && task.status != .done
    }

    private var approvalNotice: String {
        "\(provider.displayName) requested an approval. StationAI denied it because approval prompts are disabled."
    }

    private var diffHighlightStatus: String {
        guard let diffChangeCount else { return "Calculating changes…" }
        guard diffChangeCount > 0 else { return "No text changes" }
        return "\(diffChangeCount) change\(diffChangeCount == 1 ? "" : "s") highlighted"
    }

    private var latestConversationTurnID: String? {
        if let latestUserIndex = messages.lastIndex(where: { $0.role == .user }) {
            return messages.dropFirst(latestUserIndex + 1).first(where: {
                $0.role == .assistant && $0.turnID != nil
            })?.turnID ?? messages[latestUserIndex].turnID
        }
        return messages.last(where: { $0.turnID != nil })?.turnID
    }

    private var progressMessageIDs: Set<String> {
        guard let latestConversationTurnID,
              collapsedProgressTurnIDs.contains(latestConversationTurnID) else { return [] }
        return Set(messages.lazy.filter {
            $0.role == .assistant && $0.phase == "commentary" && $0.turnID == latestConversationTurnID
        }.map(\.id))
    }

    private var progressMessages: [ConversationMessage] {
        messages.filter { progressMessageIDs.contains($0.id) }
    }

    private var conversationMessages: [ConversationMessage] {
        let completedProgressIDs = progressMessageIDs
        // Read on every layout pass and every scroll sample, so the common case
        // of nothing collapsed must not copy the transcript.
        guard !completedProgressIDs.isEmpty else { return messages }
        return messages.filter { !completedProgressIDs.contains($0.id) }
    }

    private static let olderConversationMessageBatchSize = 40
    /// How far the transcript must be dragged past the oldest rendered message
    /// before the next older batch is revealed.
    private static let olderConversationRevealThreshold: CGFloat = 24
    /// Corrective scroll passes after the first one, in nanoseconds. A
    /// `LazyVStack` row that was not realized when the scroll began is placed
    /// from an estimate, so the position has to be reapplied once it exists.
    private static let scrollSettleDelays: [UInt64] = [50_000_000]

    /// First message of the newest user turn. Opening a conversation renders
    /// this message and everything after it, so the latest question sits at the
    /// top of the viewport with its answer below.
    private var latestConversationTurnStartID: String? {
        let allMessages = conversationMessages
        return allMessages.last(where: { $0.role == .user })?.id ?? allMessages.last?.id
    }

    /// The window runs from `oldestRenderedMessageID` to the newest message.
    /// A conversation that was empty when it loaded establishes no window of
    /// its own, so it keeps the newest batch rendered as messages arrive.
    private var renderedConversationMessages: [ConversationMessage] {
        let allMessages = conversationMessages
        guard let oldestRenderedMessageID,
              let startIndex = allMessages.firstIndex(where: { $0.id == oldestRenderedMessageID }) else {
            return Array(allMessages.suffix(Self.olderConversationMessageBatchSize))
        }
        return Array(allMessages[startIndex...])
    }

    private var hasOlderConversationMessages: Bool {
        // Answered from indices rather than by building the rendered window:
        // every scroll sample asks this question.
        let allMessages = conversationMessages
        guard let oldestRenderedMessageID,
              let startIndex = allMessages.firstIndex(where: { $0.id == oldestRenderedMessageID }) else {
            return allMessages.count > Self.olderConversationMessageBatchSize
        }
        return startIndex > allMessages.startIndex
    }

    /// Reveals the next older batch, keeping the message that was at the top of
    /// the viewport in place so the transcript does not jump under the pointer.
    private func revealOlderConversationMessages(using proxy: ScrollViewProxy) {
        guard hasOlderConversationMessages, !isRevealingOlderConversationMessages else { return }
        let allMessages = conversationMessages
        guard let currentTopID = renderedConversationMessages.first?.id,
              let currentStartIndex = allMessages.firstIndex(where: { $0.id == currentTopID }) else { return }
        let newStartIndex = max(0, currentStartIndex - Self.olderConversationMessageBatchSize)
        guard newStartIndex < currentStartIndex else { return }
        isRevealingOlderConversationMessages = true
        isOlderConversationRevealArmed = false
        oldestRenderedMessageID = allMessages[newStartIndex].id
        Task { @MainActor in
            await Task.yield()
            var transaction = Transaction()
            transaction.disablesAnimations = true
            let restoreAnchor = { proxy.scrollTo(currentTopID, anchor: .top) }
            withTransaction(transaction, restoreAnchor)
            // The batch that was just inserted above the anchor is positioned
            // from estimates until its rows are realized, so the anchor has to
            // be restored again once they are.
            for delay in Self.scrollSettleDelays {
                try? await Task.sleep(nanoseconds: delay)
                withTransaction(transaction, restoreAnchor)
            }
            isRevealingOlderConversationMessages = false
        }
    }

    /// Handles a new position for the top of the rendered window, measured from
    /// the top of the viewport. Dragging it below the threshold means the user
    /// scrolled past the oldest rendered message, which reveals the next batch.
    private func handleConversationWindowTop(_ windowTopY: CGFloat, using proxy: ScrollViewProxy) {
        // This runs for every scroll sample, and publishing state re-renders the
        // whole transcript, so the armed flag is only ever written when it
        // actually changes.
        guard hasOlderConversationMessages, !isRevealingOlderConversationMessages else {
            if isOlderConversationRevealArmed { isOlderConversationRevealArmed = false }
            return
        }
        let isWithinWindowTop = windowTopY <= Self.olderConversationRevealThreshold
        guard isOlderConversationRevealArmed else {
            // Arm only once the window top has settled at or above the top of
            // the viewport. Position has to be observed, never assumed, or the
            // layout pass taken before the newest turn is pinned reveals a
            // batch on open.
            if isWithinWindowTop { isOlderConversationRevealArmed = true }
            return
        }
        guard !isWithinWindowTop else { return }
        revealOlderConversationMessages(using: proxy)
    }

    /// Collapses the transcript to the newest user turn and pins that question
    /// to the top of the viewport.
    private func presentLatestConversationTurn(using proxy: ScrollViewProxy) {
        guard let turnStartID = latestConversationTurnStartID else {
            // Nothing to pin: an empty conversation renders everything it
            // receives while it stays open.
            isLatestConversationTurnPinPending = false
            return
        }
        oldestRenderedMessageID = turnStartID
        isOlderConversationRevealArmed = false
        // This pin already puts the newest question at the top, so record it as
        // the one in view; otherwise the next message count change scrolls to it
        // a second time as though it had just been sent.
        lastScrolledUserMessageID = conversationMessages.last(where: { $0.role == .user })?.id
        Task { @MainActor in
            await Task.yield()
            var transaction = Transaction()
            transaction.disablesAnimations = true
            let pin = { proxy.scrollTo(turnStartID, anchor: .top) }
            withTransaction(transaction, pin)
            // The rows below the pin are realized by that first scroll; pinning
            // again lands on their real positions instead of estimates.
            for delay in Self.scrollSettleDelays {
                try? await Task.sleep(nanoseconds: delay)
                withTransaction(transaction, pin)
            }
            hasPresentedLatestConversation = true
            isLatestConversationTurnPinPending = false
        }
    }

    /// Timeline anchors resolve against the whole transcript, while the
    /// transcript renders a window that starts at the newest turn. Clamp an
    /// anchor that falls above the window to its first rendered message so the
    /// row still appears instead of disappearing with the messages it follows.
    ///
    /// Provider boundaries and goal achievements are state transitions that
    /// stay meaningful wherever they are shown, so they are clamped. Context
    /// compaction rows are not: they are positional markers whose meaning comes
    /// from the two messages they sit between, and they reappear with those
    /// messages as older batches are revealed.
    private func renderedAnchorMessageID(for anchorID: String?) -> String? {
        guard let anchorID else { return nil }
        let rendered = renderedConversationMessages
        if rendered.contains(where: { $0.id == anchorID }) { return anchorID }
        return rendered.first?.id ?? anchorID
    }

    private func goalAchievementAnchorMessageID(for entry: GoalAchievementTimelineEntry) -> String? {
        if entry.afterMessageID == GoalAchievementTimelineEntry.beforeFirstMessageID { return nil }
        if conversationMessages.contains(where: { $0.id == entry.afterMessageID }) {
            return entry.afterMessageID
        }
        return conversationMessages.last?.id
    }

    private var activityDisclosureAnchorID: String? {
        if let latestUserIndex = conversationMessages.lastIndex(where: { $0.role == .user }) {
            return conversationMessages.dropFirst(latestUserIndex + 1).first(where: { $0.role == .assistant })?.id
        }
        return conversationMessages.first(where: { $0.role == .assistant })?.id
    }

    private var shouldShowActivityDisclosure: Bool {
        !activities.isEmpty || !progressMessages.isEmpty || isResponding || completedResponseDuration != nil || hasCompletedAssistantResponse
    }

    private var hasCompletedAssistantResponse: Bool {
        guard let latestUserIndex = messages.lastIndex(where: { $0.role == .user }) else {
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

    private var isDisplayingActiveResponse: Bool {
        isResponding && !hasCompletedAssistantResponse
    }

    private var responseStartedAtDefaultsKey: String {
        "stationai.codex.response-started-at.\(task.id.uuidString)"
    }

    private var completedResponseDurationDefaultsKey: String {
        "stationai.codex.completed-response-duration.\(task.id.uuidString)"
    }

    private var goalAchievementTimelineDefaultsKey: String {
        "stationai.codex.goal-achievement-timeline.\(task.id.uuidString)"
    }

    private var goalGenerationDefaultsKey: String {
        CodexGoalGenerationStore.generationIDKey(taskID: task.id)
    }

    private var goalGenerationObjectiveDefaultsKey: String {
        CodexGoalGenerationStore.objectiveKey(taskID: task.id)
    }

    private var goalGenerationTimeBaselineDefaultsKey: String {
        CodexGoalGenerationStore.timeBaselineKey(taskID: task.id)
    }

    var body: some View {
        HStack(spacing: 0) {
            taskSidebar

            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(width: 1)

            conversationPanel
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(WorkspaceTheme.windowBackground)
        .onAppear {
            if !isReadOnly,
               let savedMode = UserDefaults.standard.string(forKey: conversationModeDefaultsKey),
               let mode = ConversationMode(rawValue: savedMode) {
                conversationMode = mode
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
                        .help("Close the full-size image")
                    Image(nsImage: selectedChatImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityLabel("Full-size attached image")
                        .accessibilityIdentifier("chat-image-full-size")
                }
                .padding(16)
                .frame(minWidth: 600, minHeight: 420)
            }
        }
        .fileImporter(isPresented: $isShowingImagePicker, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            do {
                for url in try result.get() { try addImageData(Data(contentsOf: url)) }
            } catch { errorMessage = "Couldn't load image: \(error.localizedDescription)" }
        }
        .task {
            if !isReadOnly { refreshQueuedMessages() }
            if !isReadOnly {
                _ = try? await BoardTaskManager(modelContext: modelContext)
                    .reconcileLifecycleStatusOnOpen(task.id, clients: conversationClients)
            }
            if !isReadOnly, let request = providerPendingUserInputRequest, request.threadID == task.activeConversationID {
                userInputRequest = request
            }
            await loadConversation()
            if !isReadOnly {
                refreshQueuedMessages()
                await loadModels()
            }
            if isNewTask {
                await Task.yield()
                isComposerFocused = true
            }
            if conflictResolutionRequested && !isReadOnly && !isResponding {
                conflictResolutionAttempt = 1
                sendMessage(overrideText: "The PR has conflicts. Fix them, commit, and push.")
            }
        }
        .onChange(of: providerPendingUserInputRequest) { _, request in
            guard let request, request.threadID == task.activeConversationID, request != userInputRequest else { return }
            userInputRequest = request
            userInputAnswers = [:]
            userInputOther = [:]
            userInputOtherSelected = []
        }
        .onChange(of: providerTurnIsActive) { _, isTurnActive in
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
                : submittedTurnIsPending || (isTurnActive && providerClient.isTurnActive(threadID: taskThreadID))
        }
        .onChange(of: codexClient.goalStateRevision) { _, _ in
            guard codexClient.goalStateThreadID == task.codexThreadID else { return }
            Task { @MainActor in
                activeGoal = try? await conversationManager.goal(taskID: task.id)
                if let activeGoal { reconcileGoalGeneration(with: activeGoal) }
                goalStatusUpdatedAt = .now
            }
        }
        .onChange(of: codexClient.goalTurnRevision) { _, _ in
            guard let threadID = task.codexThreadID, codexClient.isObservingGoal(threadID: threadID) else { return }
            Task { @MainActor in await refreshGoalConversation() }
        }
        .onChange(of: codexClient.goalTurnCompletedRevision) { _, _ in
            guard let threadID = task.codexThreadID, codexClient.isObservingGoal(threadID: threadID) else { return }
            let completedTurnID = codexClient.goalTurnCompletedTurnID
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
        }
    }

    private var taskSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Changes")
                    .font(.system(size: 13, weight: .semibold))
                    .accessibilityIdentifier("workspace-changes-title")
                Spacer(minLength: 0)
                Button {
                    Task { await refreshWorkspaceChanges() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 24, height: 24)
                }
                .buttonHoverPointer()
                .buttonStyle(.plain)
                .help("Refresh workspace changes")
                .accessibilityLabel("Refresh workspace changes")
                .accessibilityIdentifier("refresh-workspace-changes-button")
                .disabled(isLoadingChanges)
            }
            .padding(.horizontal, 14)
            .padding(.top, 16)
            .padding(.bottom, 10)

            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 1)

            if let changesError {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Couldn't read Git changes", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.red)
                    Text(changesError)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Retry") {
                        Task { await refreshWorkspaceChanges() }
                    }
                    .buttonHoverPointer()
                    .help("Retry")
                    .font(.system(size: 11, weight: .medium))
                    .accessibilityIdentifier("retry-workspace-changes-button")
                }
                .padding(12)
                .accessibilityIdentifier("workspace-changes-error")
            } else if isLoadingChanges && changeInventory.isEmpty {
                ProgressView("Checking folders…")
                    .controlSize(.small)
                    .font(.system(size: 11))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("workspace-changes-loading")
            } else if changeInventory.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                    Text("No changes")
                        .font(.system(size: 12, weight: .medium))
                    Text("Changes in Git repositories under this task's folders will appear here.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(15)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("workspace-changes-empty")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 15) {
                        changeSection(title: "Viewed", entries: changeInventory.viewed)
                        changeSection(title: "Changes", entries: changeInventory.unviewed)
                    }
                    .padding(.vertical, 12)
                }
                .scrollIndicators(.visible)
                .accessibilityIdentifier("workspace-changes-list")
            }
        }
        .frame(width: 232)
        .frame(maxHeight: .infinity)
        .background(WorkspaceTheme.panelBackground.opacity(0.62))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("task-sidebar")
    }

    /// A Viewed row always shows the reviewed work from the branch base; only a change made
    /// after that review is measured from the saved snapshot.
    private func diffBaselineLabel(_ entry: WorkspaceChangeEntry) -> String {
        entry.group == .unviewed && entry.hasViewedSnapshot ? "Since last viewed" : "Since branch base"
    }

    private func changeSection(title: String, entries: [WorkspaceChangeEntry]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Image(systemName: title == "Viewed" ? "checkmark.circle.fill" : "circle.dashed")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(title == "Viewed" ? .green : .secondary)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .accessibilityIdentifier(title == "Viewed" ? "viewed-changes-title" : "unviewed-changes-title")
                Text("\(entries.count)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if title == "Viewed" {
                    Image(systemName: isViewedSectionExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .contentShape(Rectangle())
            .onTapGesture {
                if title == "Viewed" { isViewedSectionExpanded.toggle() }
            }
            .accessibilityIdentifier(title == "Viewed" ? "viewed-changes-section" : "unviewed-changes-section")

            if title == "Viewed" && !isViewedSectionExpanded {
                EmptyView()
            } else if entries.isEmpty {
                Text("No files")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 31)
                    .padding(.vertical, 3)
            } else {
                let groups = repositoryGroups(entries)
                ForEach(groups, id: \.repository) { repositoryGroup in
                    if Set(changeInventory.unviewed.map(\.repository) + changeInventory.viewed.map(\.repository)).count > 1 {
                        Text(repositoryLabel(repositoryGroup.repository))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.leading, 17)
                            .padding(.top, 4)
                            .accessibilityIdentifier("workspace-repository-\(repositoryGroup.repository.hashValue)")
                    }
                    ForEach(repositoryGroup.entries) { entry in
                        HStack(spacing: 2) {
                            Button {
                                openDiff(entry)
                            } label: {
                                HStack(spacing: 7) {
                                Image(systemName: changeSymbol(for: entry.status))
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(changeColor(for: entry.status))
                                    .frame(width: 12)
                                Text(entry.path)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(entry.isUncommitted ? Color.green : Color.primary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .accessibilityIdentifier("workspace-change-name-\(entry.group.rawValue)-\(entry.path)")
                                    .accessibilityValue(entry.isUncommitted ? "Uncommitted, green" : "Committed, primary")
                                Spacer(minLength: 0)
                                Text(statusBadge(for: entry))
                                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                                    .foregroundStyle(changeColor(for: entry.status))
                            }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                                .background(selectedChange?.id == entry.id ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                            }
                            .buttonHoverPointer()
                            .buttonStyle(.plain)
                            .help("View \(entry.group.displayName) diff for \(entry.path)")
                            .accessibilityLabel("\(entry.path), \(entry.status), \(entry.group.displayName)")
                            .accessibilityIdentifier("workspace-change-\(entry.group.rawValue)-\(entry.path)")
                            if entry.group == .unviewed {
                                Button {
                                    Task { await markViewed(entry) }
                                } label: {
                                    Image(systemName: "checkmark.circle")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 20, height: 22)
                                }
                                .buttonStyle(.plain)
                                .buttonHoverPointer()
                                .help("Mark as viewed")
                                .accessibilityLabel("Mark \(entry.path) as viewed")
                                .accessibilityIdentifier("mark-viewed-\(entry.path)")
                            }
                        }
                        .padding(.horizontal, 7)
                    }
                }
            }
        }
    }

    private func repositoryGroups(_ entries: [WorkspaceChangeEntry]) -> [ChangeRepositoryGroup] {
        Dictionary(grouping: entries, by: \.repository)
            .keys
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { repository in
                ChangeRepositoryGroup(repository: repository, entries: entries.filter { $0.repository == repository })
            }
    }

    private func repositoryLabel(_ path: String) -> String {
        let components = URL(fileURLWithPath: path).pathComponents
        return components.suffix(2).joined(separator: "/")
    }

    private func statusBadge(for entry: WorkspaceChangeEntry) -> String {
        if entry.statusCode == "??" { return "U" }
        if entry.statusCode.contains("R") { return "R" }
        if entry.statusCode.contains("A") { return "A" }
        if entry.statusCode.contains("D") { return "D" }
        if entry.status == "conflict" { return "!" }
        return "M"
    }

    private func changeSymbol(for status: String) -> String {
        switch status {
        case "added", "untracked": "plus.square.fill"
        case "deleted": "minus.square.fill"
        case "renamed", "copied": "arrow.turn.up.right"
        case "conflict": "exclamationmark.triangle.fill"
        default: "doc.text"
        }
    }

    private func changeColor(for status: String) -> Color {
        switch status {
        case "added", "untracked": .green
        case "deleted", "conflict": .red
        case "renamed", "copied": .orange
        default: .secondary
        }
    }

    private var conversationPanel: some View {
        ZStack(alignment: .leading) {
            VStack(spacing: 0) {
                conversationHeader

                Rectangle()
                    .fill(Color.primary.opacity(0.07))
                    .frame(height: 1)

                safetyNotice

                conversation

                Rectangle()
                    .fill(Color.primary.opacity(0.07))
                    .frame(height: 1)

                if isReadOnly {
                    Label("Archived conversation · read only", systemImage: "lock.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .accessibilityIdentifier("archived-conversation-read-only")
                } else {
                    composer
                }
            }
            .accessibilityHidden(selectedSubagent != nil)

            if isDiffPresented {
                fileDiffOverlay
                    .transition(.move(edge: .leading))
                    .zIndex(1)
            }

            if let selectedSubagent {
                subagentConversation(selectedSubagent)
                    .transition(.move(edge: .trailing))
                    .zIndex(2)
            }
        }
        .clipped()
        .animation(.easeInOut(duration: 0.24), value: isDiffPresented)
        .onExitCommand {
            if isDiffPresented { closeDiff() }
        }
    }

    private var fileDiffOverlay: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                Button(action: closeDiff) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonHoverPointer()
                .buttonStyle(.plain)
                .help("Close diff")
                .accessibilityLabel("Close diff")
                .accessibilityIdentifier("close-workspace-diff-button")

                if let selectedChange {
                    Image(systemName: changeSymbol(for: selectedChange.status))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(changeColor(for: selectedChange.status))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(selectedChange.path)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .accessibilityIdentifier("workspace-diff-title")
                        Text("\(repositoryLabel(selectedChange.repository)) · \(diffBaselineLabel(selectedChange))")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("workspace-diff-source")
                    }
                } else {
                    Text("File diff")
                        .font(.system(size: 12, weight: .semibold))
                }

                Spacer(minLength: 0)
                if selectedDiff?.isText == true {
                    Text(isMonacoReady ? "Side-by-side" : "Starting editor")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("workspace-diff-editor-status")
                    if isMonacoReady {
                        Text(diffHighlightStatus)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(diffChangeCount.map { $0 > 0 ? Color.green : Color.secondary } ?? Color.secondary)
                            .accessibilityIdentifier("workspace-diff-highlight-status")
                    }
                }
                Text("READ ONLY")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.06), in: Capsule())
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WorkspaceTheme.windowBackground)

            Rectangle()
                .fill(Color.primary.opacity(0.09))
                .frame(height: 1)

            Group {
                if isLoadingDiff {
                    ProgressView("Loading file diff…")
                        .controlSize(.small)
                        .accessibilityIdentifier("workspace-diff-loading")
                } else if let diffError {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(diffError)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(24)
                    .accessibilityIdentifier("workspace-diff-error")
                } else if let selectedDiff, selectedDiff.isText {
                    if let monacoError {
                        VStack(spacing: 9) {
                            Text(monacoError)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            Button("Reload editor") {
                                isMonacoReady = false
                                diffChangeCount = nil
                                self.monacoError = nil
                                self.selectedDiff = nil
                                if let selectedChange { openDiff(selectedChange) }
                            }
                            .buttonHoverPointer()
                            .help("Reload editor")
                            .font(.system(size: 11, weight: .medium))
                        }
                        .padding(24)
                    } else {
                        ZStack {
                            MonacoDiffEditor(
                                diff: selectedDiff,
                                theme: colorScheme == .dark ? "vs-dark" : "vs",
                                isReady: $isMonacoReady,
                                loadError: $monacoError,
                                diffChangeCount: $diffChangeCount
                            )
                            .accessibilityIdentifier("workspace-diff-editor")

                            if !isMonacoReady {
                                ProgressView("Starting Monaco…")
                                    .controlSize(.small)
                                    .padding(12)
                                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                                    .accessibilityIdentifier("workspace-diff-editor-loading")
                            }
                        }
                    }
                } else if let selectedDiff {
                    VStack(spacing: 9) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 22))
                            .foregroundStyle(.secondary)
                        Text(selectedDiff.message ?? "This file can't be shown as a text diff.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier("workspace-diff-unsupported")
                    }
                    .padding(24)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(WorkspaceTheme.inputBackground)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WorkspaceTheme.windowBackground)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace-diff-overlay")
        .background(EscapeKeyMonitor(onEscape: closeDiff).frame(width: 0, height: 0))
    }

    private func openDiff(_ entry: WorkspaceChangeEntry) {
        selectedChange = entry
        selectedDiff = nil
        isLoadingDiff = true
        diffError = nil
        monacoError = nil
        isMonacoReady = false
        diffChangeCount = nil
        withAnimation(.easeInOut(duration: 0.24)) {
            isDiffPresented = true
        }

        Task {
            do {
                let diff = try await workspaceManager.diff(
                    for: task.id,
                    repository: entry.repository,
                    path: entry.path,
                    group: entry.group.rawValue
                )
                guard selectedChange?.id == entry.id else { return }
                selectedDiff = diff
            } catch {
                guard selectedChange?.id == entry.id else { return }
                diffError = error.localizedDescription
            }
            if selectedChange?.id == entry.id { isLoadingDiff = false }
        }
    }

    private func closeDiff() {
        withAnimation(.easeInOut(duration: 0.24)) {
            isDiffPresented = false
        }
    }

    private func markViewed(_ entry: WorkspaceChangeEntry) async {
        do {
            try await workspaceManager.markViewed(for: task.id, repository: entry.repository, path: entry.path)
            await refreshWorkspaceChanges()
        } catch {
            changesError = error.localizedDescription
        }
    }

    private func refreshWorkspaceChanges() async {
        guard !isLoadingChanges else {
            changesNeedRefresh = true
            return
        }
        isLoadingChanges = true
        defer { isLoadingChanges = false }

        repeat {
            changesNeedRefresh = false
            do {
                let inventory = try await workspaceManager.changes(for: task.id)
                changeInventory = inventory
                changesError = nil
                if let selectedChange {
                    if let current = (inventory.unviewed + inventory.viewed).first(where: { $0.id == selectedChange.id }) {
                        self.selectedChange = current
                        if isDiffPresented {
                            do {
                                let diff = try await workspaceManager.diff(
                                    for: task.id,
                                    repository: current.repository,
                                    path: current.path,
                                    group: current.group.rawValue
                                )
                                if self.selectedChange?.id == current.id {
                                    selectedDiff = diff
                                    diffError = nil
                                }
                            } catch {
                                if self.selectedChange?.id == current.id {
                                    selectedDiff = nil
                                    diffError = error.localizedDescription
                                }
                            }
                        }
                    } else {
                        self.selectedChange = nil
                        selectedDiff = nil
                        diffError = "This file no longer has a Git change."
                    }
                }
            } catch {
                changesError = error.localizedDescription
            }
        } while changesNeedRefresh
    }

    private var conversationHeader: some View {
        HStack(spacing: 12) {
            Button(action: saveAndBack) {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonHoverPointer()
            .buttonStyle(.plain)
            .help("Back to Kanban")
            .accessibilityLabel("Back to Kanban board")
            .accessibilityIdentifier("back-to-board-button")

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if isGeneratingTitle || task.title == "Generating title…" {
                        HStack(spacing: 7) {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityIdentifier("task-title-generating-loader")
                            Text("Generating title…")
                        }
                        .accessibilityIdentifier("task-title-generating")
                    } else {
                        Text(task.title)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                            .accessibilityIdentifier("task-view-title")
                    }

                    Spacer(minLength: 8)

                    repositoryBadges
                }

                HStack(spacing: 6) {
                    Circle()
                        .fill(task.status.accent)
                        .frame(width: 6, height: 6)
                    Text(task.status.rawValue)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                if let statusMessage = task.statusMessage, !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(.system(size: 10))
                        .foregroundStyle(task.status == .blocked ? Color.red : Color.secondary)
                        .lineLimit(3)
                        .accessibilityIdentifier("task-status-message")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WorkspaceTheme.windowBackground.opacity(0.96))
    }

    private var repositoryBadges: some View {
        HStack(spacing: 5) {
            ForEach(task.repositoryWorktrees, id: \.repositoryPath) { repository in
                let name = URL(fileURLWithPath: repository.repositoryPath).lastPathComponent
                Button {
                    repositoryBeingEdited = repository
                    editedBranch = repository.branch
                    editedBranchFrom = repository.branchFrom
                    editedMergeTarget = repository.mergeTarget ?? ""
                    editingRepositoryField = nil
                } label: {
                    Text(name).font(.system(size: 10, weight: .medium)).lineLimit(1)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(Color.accentColor.opacity(0.1), in: Capsule())
                }
                .buttonHoverPointer()
                .help("Edit repository settings for \(name)")
                .buttonStyle(.plain)
                .disabled(isReadOnly)
                .popover(item: Binding(
                    get: { repositoryBeingEdited?.repositoryPath == repository.repositoryPath ? RepositoryBadgeEditID(path: repository.repositoryPath) : nil },
                    set: { if $0 == nil { repositoryBeingEdited = nil } }
                )) { _ in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(name).font(.system(size: 12, weight: .semibold))
                        repositoryDetailRow("Branch name", value: $editedBranch, field: "branch", placeholder: "auto", identifier: "conversation-repository-branch", editable: repository.isPending)
                        repositoryDetailRow("Branch from", value: $editedBranchFrom, field: "from", placeholder: "default", identifier: "conversation-repository-branch-from", editable: repository.isPending)
                        repositoryDetailRow("Merge to", value: $editedMergeTarget, field: "to", placeholder: "default", identifier: "conversation-repository-merge-target", editable: repository.isPending)
                        HStack {
                            Button("Remove Repository", role: .destructive) { removeConversationRepository(repository) }
                            .buttonHoverPointer()
                            .help("Remove Repository")
                                .accessibilityIdentifier("remove-conversation-repository-button")
                            Spacer()
                            if repository.isPending {
                                Button("Save") { saveConversationRepository(repository) }
                                    .buttonHoverPointer()
                                    .help("Save repository settings")
                                    .buttonStyle(.borderedProminent)
                                    .accessibilityIdentifier("save-conversation-repository-button")
                            } else {
                                Text("Settings are locked after the task starts.")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .accessibilityIdentifier("conversation-repository-settings-locked")
                            }
                        }
                    }
                    .font(.system(size: 11)).padding(12).frame(minWidth: 270, alignment: .leading)
                }
                .accessibilityIdentifier("conversation-repository-badge-\(name)")
            }
            Button {
                isShowingRepositoryPicker.toggle()
                if suggestedRepositories.isEmpty { loadSuggestedRepositories() }
            } label: {
                Image(systemName: "plus").font(.system(size: 10, weight: .semibold))
                    .frame(width: 22, height: 22).background(Color.primary.opacity(0.07), in: Circle())
            }
            .buttonHoverPointer()
            .buttonStyle(.plain).help("Add a repository").accessibilityLabel("Add repository")
            .accessibilityIdentifier("add-conversation-repository-button")
            .popover(isPresented: $isShowingRepositoryPicker, arrowEdge: .bottom) { repositoryPicker }
            .disabled(isReadOnly)
        }
    }

    private var repositoryPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let parentFolderURL = WorkspaceSettings.validDirectoryURL(for: defaultParentFolderPath) {
                HStack(spacing: 5) {
                    Text("Suggestions from \(parentFolderURL.path)")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(parentFolderURL.path)
                    Spacer(minLength: 0)
                    Button("Change…") { chooseRepositoryParentFolder() }
                        .buttonHoverPointer()
                        .help("Choose a different repository suggestion folder")
                        .disabled(isChoosingRepositoryParent)
                        .accessibilityIdentifier("choose-repository-suggestion-parent-button")
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            } else {
                Text("Choose a parent folder to find Git repositories.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Button("Choose suggestion folder…") { chooseRepositoryParentFolder() }
                    .buttonHoverPointer()
                    .help("Choose a folder to find repository suggestions")
                    .disabled(isChoosingRepositoryParent)
                    .accessibilityIdentifier("choose-repository-suggestion-parent-button")
            }
            TextField(repositorySearchPlaceholder, text: $repositorySearch)
                .textFieldStyle(.roundedBorder)
                .focused($isRepositorySearchFocused)
                .onChange(of: repositorySearch) { _, value in
                    repositorySuggestionIndex = 0
                    if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        didOverrideRepositoryDefault = true
                    }
                }
                .onKeyPress { press in
                    let available = availableRepositorySuggestions
                    switch press.key {
                    case .downArrow:
                        guard !available.isEmpty else { return .ignored }
                        didOverrideRepositoryDefault = true
                        repositorySuggestionIndex = min(repositorySuggestionIndex + 1, available.count - 1)
                        return .handled
                    case .upArrow:
                        guard !available.isEmpty else { return .ignored }
                        didOverrideRepositoryDefault = true
                        repositorySuggestionIndex = max(repositorySuggestionIndex - 1, 0)
                        return .handled
                    case .return:
                        if isUsingSavedRepositoryDefault {
                            let savedRepositories = validLastSelectedRepositoryURLs
                            guard !savedRepositories.isEmpty else { return .handled }
                            selectRepositories(savedRepositories)
                        } else if available.indices.contains(repositorySuggestionIndex) {
                            selectRepositorySuggestion(available[repositorySuggestionIndex])
                        } else {
                            return .ignored
                        }
                        return .handled
                    default:
                        return .ignored
                    }
                }
                .accessibilityIdentifier("conversation-repository-search")
            let available = availableRepositorySuggestions
            if WorkspaceSettings.validDirectoryURL(for: defaultParentFolderPath) == nil {
                EmptyView()
            } else if available.isEmpty {
                Text("No matching repositories.").font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(available.enumerated()), id: \.element.path) { index, repository in
                            Button {
                                selectRepositorySuggestion(repository)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(repository.lastPathComponent).font(.system(size: 11, weight: .medium))
                                    Text(repository.path).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(7).contentShape(Rectangle())
                            }
                            .buttonHoverPointer()
                            .help("Select repository")
                            .buttonStyle(.plain)
                            .background(index == repositorySuggestionIndex ? Color.accentColor.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                            .accessibilityIdentifier("conversation-repository-suggestion-\(repository.lastPathComponent)")
                        }
                    }
                }.frame(width: 280, height: min(CGFloat(available.count * 42), 180))
            }
        }
        .padding(12)
        .frame(width: 304)
        .defaultFocus($isRepositorySearchFocused, isNewTask)
    }

    private var repositorySearchPlaceholder: String {
        guard isNewTask, !lastSelectedRepositoryPaths.isEmpty else { return "Search repositories…" }
        let names = lastSelectedRepositoryPaths.map { URL(fileURLWithPath: $0).lastPathComponent }
        return "\(names.joined(separator: ", ")) ↵"
    }

    private var isUsingSavedRepositoryDefault: Bool {
        isNewTask && task.repositoryWorktrees.isEmpty &&
        repositorySearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !didOverrideRepositoryDefault && !lastSelectedRepositoryPaths.isEmpty
    }

    private var validLastSelectedRepositoryURLs: [URL] {
        lastSelectedRepositoryPaths.compactMap { path in
            let repository = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            let gitMarker = repository.appendingPathComponent(".git")
            return FileManager.default.fileExists(atPath: gitMarker.path) ? repository : nil
        }
    }

    private var availableRepositorySuggestions: [URL] {
        suggestedRepositories.filter { candidate in
            !task.repositoryWorktrees.contains(where: { URL(fileURLWithPath: $0.repositoryPath).standardizedFileURL.path == candidate.standardizedFileURL.path }) &&
            (repositorySearch.isEmpty || candidate.lastPathComponent.localizedCaseInsensitiveContains(repositorySearch) || candidate.path.localizedCaseInsensitiveContains(repositorySearch))
        }
    }

    private func selectRepositorySuggestion(_ repository: URL) {
        didOverrideRepositoryDefault = true
        selectRepositories([repository])
    }

    private func selectRepositories(
        _ repositories: [URL],
        reopenPickerOnError: Bool = true,
        isApplyingDefault: Bool = false
    ) {
        isShowingRepositoryPicker = false
        repositorySearch = ""
        if isApplyingDefault { isApplyingSavedRepositories = true }
        Task { @MainActor in
            defer {
                if isApplyingDefault { isApplyingSavedRepositories = false }
            }
            do {
                var selectedPaths = task.repositoryWorktrees.map { $0.repositoryPath }
                var repositoriesToAdd: [String] = []
                let manager = BoardTaskManager(modelContext: modelContext)
                for repository in repositories {
                    let path = repository.standardizedFileURL.path
                    guard !selectedPaths.contains(path) else { continue }
                    selectedPaths.append(path)
                    repositoriesToAdd.append(path)
                }
                if !repositoriesToAdd.isEmpty {
                    _ = try await manager.addRepositories(task.id, repositoryPaths: repositoriesToAdd)
                }
                let availablePaths = selectedPaths.filter { path in
                    FileManager.default.fileExists(atPath: URL(fileURLWithPath: path).appendingPathComponent(".git").path)
                }
                try WorkspaceSettingsManager().setLastSelectedRepositories(availablePaths)
                await refreshWorkspaceChanges()
            } catch {
                errorMessage = "Couldn't add repository: \(error.localizedDescription)"
                isShowingRepositoryPicker = reopenPickerOnError
            }
        }
    }

    private func loadSuggestedRepositories() {
        guard let parent = WorkspaceSettings.validDirectoryURL(for: defaultParentFolderPath) else { return }
        Task {
            suggestedRepositories = (try? await WorkspaceManager().suggestedRepositories(parentPath: parent.path).map {
                URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL
            }) ?? []
        }
    }

    private func chooseRepositoryParentFolder(showRepositoryPickerWhenFinished: Bool = true) {
        guard !isChoosingRepositoryParent else { return }
        isShowingRepositoryPicker = false
        let panel = NSOpenPanel()
        panel.title = "Choose repository root folder"
        panel.message = "StationAI will search below this folder for repositories. A root folder is required before sending conversations."
        panel.prompt = "Use This Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        isChoosingRepositoryParent = true
        panel.begin { response in
            DispatchQueue.main.async {
                isChoosingRepositoryParent = false
                guard response == .OK, let selected = panel.url else {
                    isShowingRepositoryPicker = showRepositoryPickerWhenFinished
                    return
                }
                let path = selected.standardizedFileURL.path
                do {
                    try WorkspaceSettingsManager().setDefaultParentFolder(path)
                    defaultParentFolderPath = path
                    loadSuggestedRepositories()
                    isShowingRepositoryPicker = showRepositoryPickerWhenFinished
                } catch {
                    errorMessage = "Couldn't set the repository suggestion folder: \(error.localizedDescription)"
                    isShowingRepositoryPicker = showRepositoryPickerWhenFinished
                }
            }
        }
    }

    private var safetyNotice: some View {
        let additionalFolders = workspaceRootURLs.filter { url in
            !task.repositoryWorktrees.contains {
                URL(fileURLWithPath: $0.worktreePath).standardizedFileURL.path == url.path
            }
        }
        return Group {
            if !additionalFolders.isEmpty {
                let folderLabels = additionalFolders.map(\.lastPathComponent)
                let folderSummary = "Working in: " + folderLabels.joined(separator: " · ")
                let fullFolderSummary = "Working in: " + additionalFolders.map(\.path).joined(separator: " · ")
                Text(folderSummary)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(fullFolderSummary)
                    .accessibilityIdentifier("working-folders-summary")
                    .frame(maxWidth: 820, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 28)
                    .padding(.top, 12)
            }
        }
    }

    private var conversation: some View {
        GeometryReader { viewport in
            ScrollViewReader { scrollProxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Scroll runway above the rendered window. It keeps an
                    // upward drag available even when the latest turn alone is
                    // shorter than the viewport, and it is replaced by the
                    // earlier messages as soon as they are revealed.
                    if hasOlderConversationMessages {
                        Color.clear
                            .frame(height: viewport.size.height)
                            .accessibilityHidden(true)
                        // Scroll position is only observable from macOS 15 on,
                        // so older systems keep an explicit control rather than
                        // an upward drag that cannot be detected.
                        if #unavailable(macOS 15) {
                            Button("Load earlier messages") {
                                revealOlderConversationMessages(using: scrollProxy)
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .buttonHoverPointer()
                            .help("Load 40 earlier messages.")
                            .accessibilityIdentifier("conversation-load-older-button")
                        }
                    }
                    // Tracks how far the top of the rendered window sits below
                    // the top of the viewport, which is how an upward scroll is
                    // detected.
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: ConversationTopMarkerPositionKey.self,
                            value: geometry.frame(in: .named(Self.conversationScrollCoordinateSpace)).minY
                        )
                    }
                    .frame(height: 0)

                VStack(alignment: .leading, spacing: 16) {
                    if messages.isEmpty && activeGoal?.status != "complete" && !isLoadingHistory {
                        VStack(spacing: 0) {
                            Text(emptyConversationRepositoryTitle)
                                .font(.system(size: 30, weight: .bold))
                                .foregroundStyle(emptyConversationRepositoryTitleColor)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .accessibilityLabel(emptyConversationRepositoryTitle)
                                .accessibilityIdentifier("empty-conversation-repository-title")
                            Spacer(minLength: 58)
                            VStack(spacing: 14) {
                                Image(systemName: "bubble.left.and.bubble.right")
                                    .font(.system(size: 29, weight: .regular))
                                    .foregroundStyle(Color.accentColor.opacity(0.8))
                                    .accessibilityLabel("Conversation")
                                Text("Send a message to \(provider.assistantLabel(modelName: selectedModelName)).")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel("Send a message to \(provider.assistantLabel).")
                                    .accessibilityIdentifier("model-prompt")
                            }
                            Spacer(minLength: 28)
                        }
                        .frame(maxWidth: .infinity, minHeight: 280)
                        .padding(.horizontal, 30)
                        .padding(.vertical, 38)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("empty-conversation")
                    } else if !messages.isEmpty {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            ForEach(goalAchievementTimelineEntries.filter {
                                goalAchievementAnchorMessageID(for: $0) == nil
                            }) { entry in
                                goalAchievementTimelineRow(entry)
                                    .id(entry.id)
                            }
                            ForEach(providerBoundaries.filter { $0.afterMessageID == nil }) { boundary in
                                providerBoundaryRow(boundary)
                            }
                            ForEach(renderedConversationMessages) { message in
                                if shouldShowActivityDisclosure, message.id == activityDisclosureAnchorID {
                                    activityList
                                }
                                messageBubble(message)
                                    .id(message.id)
                                ForEach(providerBoundaries.filter {
                                    renderedAnchorMessageID(for: boundaryAnchorID(for: $0)) == message.id
                                }) { boundary in
                                    providerBoundaryRow(boundary)
                                }
                                ForEach(goalAchievementTimelineEntries.filter {
                                    renderedAnchorMessageID(for: goalAchievementAnchorMessageID(for: $0)) == message.id
                                }) { entry in
                                    goalAchievementTimelineRow(entry)
                                        .id(entry.id)
                                }
                                let nextOrder = conversationMessages.first(where: {
                                    guard let current = message.timelineOrder, let candidate = $0.timelineOrder else { return false }
                                    return candidate > current
                                })?.timelineOrder
                                ForEach(activities.filter {
                                    guard $0.isContextCompaction, let eventOrder = $0.timelineOrder,
                                          let messageOrder = message.timelineOrder, eventOrder > messageOrder else { return false }
                                    return nextOrder.map { eventOrder < $0 } ?? true
                                }) { activity in
                                    contextCompactionTimelineRow(activity)
                                }
                            }
                            if shouldShowActivityDisclosure, activityDisclosureAnchorID == nil {
                                activityList
                            }
                        }
                    }

                    if messages.isEmpty && shouldShowActivityDisclosure {
                        activityList
                    }
                    if messages.isEmpty {
                        ForEach(providerBoundaries) { boundary in
                            providerBoundaryRow(boundary)
                        }
                    }
                    if messages.isEmpty {
                        ForEach(goalAchievementTimelineEntries.filter {
                            goalAchievementAnchorMessageID(for: $0) == nil
                        }) { entry in
                            goalAchievementTimelineRow(entry)
                                .id(entry.id)
                        }
                    }
                    if let request = userInputRequest, request.threadID == task.activeConversationID {
                        userInputForm(request)
                            .frame(maxWidth: 620, alignment: .leading)
                            .accessibilityIdentifier("conversation-user-input-request")
                    }

                    if let activeProcess {
                        activityRow(activeProcess, compact: true)
                    }
                    ForEach(activeSubagents) { activity in
                        subagentTimelineRow(activity)
                    }
                    ForEach(activities.filter { $0.isContextCompaction && $0.timelineOrder == nil }) { activity in
                        contextCompactionTimelineRow(activity)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("conversation-latest-anchor")
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: ConversationScrollContentHeightKey.self,
                            value: geometry.size.height
                        )
                    }
                }

                // Filler below the rendered window. Together with the runway
                // above it, this is what lets a turn that is shorter than the
                // viewport still be scrolled to the top.
                if hasOlderConversationMessages {
                    Color.clear
                        .frame(height: max(0, viewport.size.height - conversationContentHeight))
                        .accessibilityHidden(true)
                }
                }
            }
            .coordinateSpace(name: Self.conversationScrollCoordinateSpace)
            .scrollIndicators(.visible)
            .accessibilityIdentifier("conversation-scroll-view")
            .accessibilityValue("Showing latest \(renderedConversationMessages.count) of \(conversationMessages.count) messages")
            .onPreferenceChange(ConversationTopMarkerPositionKey.self) { markerY in
                // Exactly one source drives the reveal: the scroll observer
                // where it exists, this marker where it does not.
                if #unavailable(macOS 15) {
                    handleConversationWindowTop(markerY, using: scrollProxy)
                }
            }
            .modifier(ConversationScrollOffsetObserver { offsetY in
                // The runway occupies everything above the rendered window, so
                // the distance from the viewport top to the window top is what
                // is left of it.
                handleConversationWindowTop(
                    hasOlderConversationMessages ? viewport.size.height - offsetY : -offsetY,
                    using: scrollProxy
                )
            })
            .onPreferenceChange(ConversationScrollContentHeightKey.self) { height in
                // Only "shorter than the viewport?" is ever asked of this value,
                // and a LazyVStack keeps revising its measured height as rows
                // realize while scrolling. Publishing each revision re-renders
                // the whole transcript, so cap it once the content overflows.
                let clamped = min(height, viewport.size.height + 1)
                if clamped != conversationContentHeight { conversationContentHeight = clamped }
            }
            .onChange(of: isLoadingHistory) { _, isLoading in
                // Every completed history load reopens on the newest turn,
                // including reloads that leave the messages unchanged.
                guard !isLoading else { return }
                presentLatestConversationTurn(using: scrollProxy)
            }
            .onChange(of: messages.count) { _, _ in
                scrollToLatestUserMessage(using: scrollProxy, viewportHeight: viewport.size.height)
            }
            .onChange(of: messages.map(\.text)) { _, _ in
                if !hasPresentedLatestConversation {
                    scrollToLatest(using: scrollProxy, viewportHeight: viewport.size.height)
                }
            }
            .onChange(of: hasCompletedAssistantResponse) { _, hasCompletedResponse in
                if hasCompletedResponse && activities.isEmpty {
                    isActivityExpanded = false
                }
            }
            .onChange(of: activities) { _, _ in
                if isResponding && !hasPresentedLatestConversation {
                    scrollToLatest(using: scrollProxy, viewportHeight: viewport.size.height)
                }
            }
            .onChange(of: isResponding) { _, _ in
                if !hasPresentedLatestConversation {
                    scrollToLatest(using: scrollProxy, viewportHeight: viewport.size.height)
                }
            }
            .onChange(of: activeGoal?.status) { _, status in
                if status == "complete" && !hasPresentedLatestConversation {
                    scrollToLatest(using: scrollProxy, viewportHeight: viewport.size.height)
                }
            }
            .onChange(of: goalAchievementTimelineEntries.count) { _, _ in
                if !hasPresentedLatestConversation {
                    scrollToLatest(using: scrollProxy, viewportHeight: viewport.size.height)
                }
            }
            }
        }
    }

    private static let conversationScrollCoordinateSpace = "conversation-transcript-scroll"

    private var emptyConversationRepositoryTitle: String {
        var repositoryNames = task.repositoryWorktrees.map {
            URL(fileURLWithPath: $0.repositoryPath).lastPathComponent
        }
        if repositoryNames.isEmpty {
            repositoryNames = task.workspaceRootPaths.compactMap { path in
                let repositoryURL = URL(fileURLWithPath: path, isDirectory: true)
                let gitMarker = repositoryURL.appendingPathComponent(".git")
                guard FileManager.default.fileExists(atPath: gitMarker.path) else { return nil }
                return repositoryURL.lastPathComponent
            }
        }
        return repositoryNames.isEmpty ? "No repository selected" : repositoryNames.joined(separator: " · ")
    }

    private var emptyConversationRepositoryTitleColor: Color {
        colorScheme == .dark
            ? .orange
            : Color(red: 0.18, green: 0.31, blue: 0.68)
    }

    private var activeSubagents: [ConversationActivity] {
        activities.filter { $0.isSubagent && $0.isActive }
    }

    /// Keep the latest live non-agent operation in the conversation timeline.
    /// Earlier live operations remain available in the expanded activity list.
    private var activeProcess: ConversationActivity? {
        activities
            .filter { !$0.isSubagent && !$0.isContextCompaction && $0.isActive }
            .enumerated()
            .max { left, right in
                let leftOrder = left.element.timelineOrder ?? left.offset
                let rightOrder = right.element.timelineOrder ?? right.offset
                return leftOrder < rightOrder
            }?
            .element
    }

    private var activityList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    isActivityExpanded.toggle()
                }
            } label: {
                activityDisclosureButtonLabel
            }
            .buttonHoverPointer()
            .help("Show or hide Codex activity details")
            .buttonStyle(.plain)
            .accessibilityValue(isActivityExpanded ? "Expanded, down chevron" : "Collapsed, right chevron")
            .accessibilityHint("Shows Codex progress messages and completed activity details.")
            .accessibilityIdentifier("codex-activity-disclosure")

            // Keep active child rows in the materialized activity container so
            // accessibility can discover them even when the conversation
            // timeline is still settling its scroll position.
            if isDisplayingActiveResponse || !activeSubagents.isEmpty {
                ForEach(activities.filter(\.isSubagent)) { activity in
                    subagentTimelineRow(activity)
                }
            }

            Divider()
                .opacity(0.32)
                .accessibilityElement()
                .accessibilityLabel("Separator between work duration and response")

            if isActivityExpanded {
                VStack(alignment: .leading, spacing: 7) {
                    if !progressMessages.isEmpty {
                        Text("Progress")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                        ForEach(progressMessages) { message in
                            assistantMarkdownContent(Self.displayableAssistantText(message.text))
                                .font(.system(size: 12))
                                .foregroundStyle(WorkspaceTheme.conversationText)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(9)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(WorkspaceTheme.panelBackground, in: RoundedRectangle(cornerRadius: 8))
                                .accessibilityIdentifier("codex-progress-message-\(message.id)")
                        }
                    }
                    let activeIDsOutside = Set(activeSubagents.map(\.id) + [activeProcess?.id].compactMap { $0 })
                    ForEach(activities.filter {
                        !$0.isSubagent && !$0.isContextCompaction && !activeIDsOutside.contains($0.id)
                    }) { activity in
                        activityRow(activity)
                    }
                    let agentActivities = activities.filter(\.isSubagent)
                    let completedAgentActivities = agentActivities.filter { !$0.isActive }
                    if !completedAgentActivities.isEmpty {
                        Text("Agents used")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                        ForEach(completedAgentActivities) { activity in
                            subagentTimelineRow(activity)
                        }
                    }
                }
                .padding(.top, 6)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("codex-activity-details")
            }
        }
    }

    private func goalAchievementTimelineRow(_ entry: GoalAchievementTimelineEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(.secondary)
            Text(entry.summary)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("goal-achieved-banner")
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("goal-achievement-timeline-row")
    }

    private func subagentTimelineRow(_ activity: ConversationActivity) -> some View {
        Button {
            openSubagent(activity)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image("SubagentIcon")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 20, height: 20)
                    .accessibilityElement()
                    .accessibilityLabel("\(activity.title) agent icon")
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(activity.title) \(activity.timelineStatus)")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    let metadata = [activity.agentPath, activity.model, activity.reasoningEffort]
                        .compactMap { $0 }
                        .filter { !$0.isEmpty }
                    if let duration = activity.durationLabel() {
                        Text(duration)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    if !metadata.isEmpty {
                        Text(metadata.joined(separator: " · "))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 5)
        }
        .buttonHoverPointer()
        .help("Open the read-only conversation for this agent")
        .buttonStyle(.plain)
        .accessibilityLabel("\(activity.title) \(activity.timelineStatus)")
        .accessibilityValue([activity.detail, activity.durationLabel()].compactMap { $0 }.joined(separator: "\n"))
        .accessibilityIdentifier("codex-subagent-row-\(activity.childThreadID ?? activity.id)")
    }

    @ViewBuilder
    private func activityRow(_ activity: ConversationActivity, compact: Bool = false) -> some View {
        let displayDetail = [activity.detail]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        if compact {
            HStack(spacing: 7) {
                Image(systemName: activity.status == "completed" ? "checkmark.circle.fill" : ["interrupted", "stopped"].contains(activity.status) ? "pause.circle.fill" : "gearshape.2.fill")
                    .foregroundStyle(activity.status == "completed" ? .green : ["interrupted", "stopped"].contains(activity.status) ? .orange : .accentColor)
                Text(activity.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
                if !displayDetail.isEmpty {
                    Text(displayDetail)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("codex-activity-detail-\(activity.id)")
                        .accessibilityLabel(displayDetail)
                } else {
                    Spacer(minLength: 0)
                }
                Text(activity.statusLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                if activity.isActive, activity.startedAt != nil {
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        let duration = activity.durationLabel(at: timeline.date) ?? ""
                        Text(duration)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .accessibilityValue(duration)
                            .accessibilityIdentifier("codex-activity-duration-\(activity.id)")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(9)
            .background(WorkspaceTheme.panelBackground, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(activity.title), \(activity.statusLabel)")
            .accessibilityValue([displayDetail, activity.durationLabel()].compactMap { $0 }.joined(separator: "\n"))
            .accessibilityIdentifier("codex-activity-row-\(activity.id)")
        } else {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Image(systemName: activity.status == "completed" ? "checkmark.circle.fill" : ["interrupted", "stopped"].contains(activity.status) ? "pause.circle.fill" : "gearshape.2.fill")
                    .foregroundStyle(activity.status == "completed" ? .green : ["interrupted", "stopped"].contains(activity.status) ? .orange : .accentColor)
                Text(activity.title)
                    .font(.system(size: 11, weight: .medium))
                    .textSelection(.enabled)
                Spacer(minLength: 4)
                Text(activity.statusLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            if !displayDetail.isEmpty {
                Text(displayDetail)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(4)
                    .accessibilityIdentifier("codex-activity-detail-\(activity.id)")
                    .accessibilityLabel(displayDetail)
            }
            if activity.isActive, activity.startedAt != nil {
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    let duration = activity.durationLabel(at: timeline.date) ?? ""
                    Text(duration)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .accessibilityValue(duration)
                        .accessibilityIdentifier("codex-activity-duration-\(activity.id)")
                }
            } else if let duration = activity.durationLabel() {
                Text(duration)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .accessibilityValue(duration)
                    .accessibilityIdentifier("codex-activity-duration-\(activity.id)")
            } else {
                Text("Duration unavailable")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .accessibilityValue("Duration unavailable")
                    .accessibilityIdentifier("codex-activity-duration-\(activity.id)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(WorkspaceTheme.panelBackground, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(activity.title), \(activity.statusLabel)")
        .accessibilityValue([displayDetail, activity.durationLabel()].compactMap { $0 }.joined(separator: "\n"))
        .accessibilityIdentifier(activity.isSubagent ? "codex-subagent-row-\(activity.childThreadID ?? activity.id)" : "codex-activity-row-\(activity.id)")
        }
    }

    private func contextCompactionTimelineRow(_ activity: ConversationActivity) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(activity.status == "inProgress" ? "Compacting context…" : "Context compacted")
                    .font(.system(size: 12, weight: .medium))
                if !activity.detail.isEmpty {
                    Text(activity.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .accessibilityIdentifier("context-compaction-summary-\(activity.id)")
                }
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Context compaction, \(activity.statusLabel)")
        .accessibilityValue(activity.statusLabel)
        .accessibilityIdentifier("context-compaction-row-\(activity.id)")
    }

    /// A boundary after a message that later folded into the activity list
    /// anchors to the nearest visible message instead.
    private func boundaryAnchorID(for boundary: ConversationProviderBoundary) -> String? {
        guard let afterMessageID = boundary.afterMessageID else { return nil }
        if conversationMessages.contains(where: { $0.id == afterMessageID }) { return afterMessageID }
        guard let index = messages.firstIndex(where: { $0.id == afterMessageID }) else { return conversationMessages.last?.id }
        let visible = Set(conversationMessages.map(\.id))
        return messages[...index].last(where: { visible.contains($0.id) })?.id
    }

    private func providerBoundaryRow(_ boundary: ConversationProviderBoundary) -> some View {
        HStack(spacing: 10) {
            Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1)
            Text("Conversation switched to \(boundary.provider.displayName)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .fixedSize()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Conversation switched to \(boundary.provider.displayName)")
                .accessibilityIdentifier("provider-boundary-\(boundary.provider.rawValue)")
            Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1)
        }
        .padding(.vertical, 4)
        .id(boundary.id)
    }

    private func openSubagent(_ activity: ConversationActivity) {
        selectedSubagent = activity
        subagentHistory = nil
        subagentError = nil
        isLoadingSubagent = true
        guard activity.childThreadID != nil else { return }
        Task { @MainActor in
            do {
                subagentHistory = try await conversationManager.subagentHistory(taskID: task.id, activity: activity)
            } catch {
                subagentError = "Couldn't load this agent conversation: \(error.localizedDescription)"
            }
            isLoadingSubagent = false
        }
    }

    private func subagentConversation(_ activity: ConversationActivity) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    selectedSubagent = nil
                    subagentHistory = nil
                } label: {
                    Label("Back", systemImage: "arrow.left")
                }
                .buttonHoverPointer()
                .help("Return to the parent conversation")
                .buttonStyle(.plain)
                .accessibilityIdentifier("subagent-back-button")
                Text(activity.title).font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("Read only").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
            if isLoadingSubagent {
                ProgressView("Loading agent conversation…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let subagentError {
                Text(subagentError).foregroundStyle(.secondary).padding(24)
            } else if let subagentHistory {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(subagentHistory.messages) { message in messageBubble(message) }
                        if subagentHistory.messages.isEmpty {
                            Text("No conversation content is available yet.").foregroundStyle(.secondary).padding(20)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 820)
                    .frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("subagent-conversation-scroll-view")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WorkspaceTheme.windowBackground)
        .accessibilityIdentifier("subagent-conversation-panel")
    }

    @ViewBuilder
    private var activityDisclosureButtonLabel: some View {
        if isDisplayingActiveResponse, let responseStartedAt {
            TimelineView(.periodic(from: responseStartedAt, by: 1)) { timeline in
                activityDisclosureContents(
                    workingFor: Self.durationLabel(Self.elapsedSeconds(since: responseStartedAt, now: timeline.date))
                )
            }
        } else {
            activityDisclosureContents(
                workedFor: completedResponseDuration.map(Self.durationLabel) ?? (hasCompletedAssistantResponse ? "" : nil)
            )
        }
    }

    private func activityDisclosureContents(workingFor: String? = nil, workedFor: String? = nil) -> some View {
        return HStack(spacing: 7) {
            if let workingFor {
                Text("Working for \(workingFor)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityIdentifier("codex-working-duration")
            } else if let workedFor {
                Text(workedFor.isEmpty ? "Worked for" : "Worked for \(workedFor)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("codex-worked-duration")
            } else {
                Text("Codex activity")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Image(systemName: isActivityExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .accessibilityIdentifier("codex-activity-chevron")
        }
        .contentShape(Rectangle())
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func messageBubble(_ message: ConversationMessage) -> some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .assistant {
                if message.asyncQuestions == nil &&
                    Self.displayableAssistantText(message.text).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && isResponding {
                    EmptyView()
                } else if message.asyncQuestions != nil {
                    asyncQuestionBubble(message)
                } else {
                    assistantBubble(message)
                }
                Spacer(minLength: 70)
            } else {
                Spacer(minLength: 70)
                userBubble(message)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func asyncQuestionKey(messageID: String, index: Int) -> String {
        "\(messageID):\(index)"
    }

    private func asyncQuestionWasAnswered(_ message: ConversationMessage) -> Bool {
        answeredAsyncQuestionIDs.contains(message.id)
            || queuedMessages.contains { $0.asyncQuestionItemID == message.id }
    }

    private func asyncQuestionBubble(_ message: ConversationMessage) -> some View {
        let questions = message.asyncQuestions ?? []
        let answered = asyncQuestionWasAnswered(message)
        return VStack(alignment: .leading, spacing: 12) {
            Text(assistantLabel(for: message))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
                let answerKey = asyncQuestionKey(messageID: message.id, index: index)
                VStack(alignment: .leading, spacing: 8) {
                    Text(question.title)
                        .font(.system(size: 15, weight: .semibold))
                    if let options = question.options, !options.isEmpty {
                        if !answered && !isReadOnly {
                            ForEach(Array(options.enumerated()), id: \.offset) { optionIndex, option in
                                Button {
                                    asyncQuestionAnswers[answerKey] = option
                                } label: {
                                    Label(option, systemImage: asyncQuestionAnswers[answerKey] == option ? "largecircle.fill.circle" : "circle")
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                                .buttonHoverPointer()
                                .help("Choose this answer for \(question.title)")
                                .accessibilityIdentifier("async-question-option-\(message.id)-\(index)-\(optionIndex)")
                            }
                            TextField("Other answer", text: Binding(
                                get: {
                                    let answer = asyncQuestionAnswers[answerKey] ?? ""
                                    return options.contains(answer) ? "" : answer
                                },
                                set: { asyncQuestionAnswers[answerKey] = $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("async-question-other-\(message.id)-\(index)")
                        } else {
                            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                                Text(option).font(.system(size: 13)).foregroundStyle(.secondary)
                            }
                        }
                    } else if !answered && !isReadOnly {
                        TextField("Your answer", text: Binding(
                                get: { asyncQuestionAnswers[answerKey] ?? "" },
                                set: { asyncQuestionAnswers[answerKey] = $0 }
                            ))
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("async-question-answer-\(message.id)-\(index)")
                    }
                }
            }
            if answered {
                Text(answeredAsyncQuestionIDs.contains(message.id) ? "Answered" : "Pending")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else if !isReadOnly {
                Button("Send answers") { submitAsyncQuestions(message) }
                    .buttonStyle(.borderedProminent)
                    .buttonHoverPointer()
                    .help("Send your answers to \(provider.displayName)")
                    .disabled(isSubmittingLiveMessage || isLoadingHistory || questions.enumerated().contains { index, _ in
                        let key = asyncQuestionKey(messageID: message.id, index: index)
                        return (asyncQuestionAnswers[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    })
                    .accessibilityIdentifier("submit-async-questions-\(message.id)")
            }
        }
        .padding(15)
        .frame(maxWidth: 620, alignment: .leading)
        .background(WorkspaceTheme.panelBackground, in: RoundedRectangle(cornerRadius: 17))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("async-question-\(message.id)")
    }

    private func submitAsyncQuestions(_ message: ConversationMessage) {
        guard let questions = message.asyncQuestions, !questions.isEmpty else { return }
        let answers = questions.indices.map { asyncQuestionAnswers[asyncQuestionKey(messageID: message.id, index: $0)] ?? "" }
        let priorAssistantMessages = Dictionary(
            uniqueKeysWithValues: messages
                .filter { $0.role == .assistant }
                .map { ($0.id, $0.text) }
        )
        isSubmittingLiveMessage = true
        Task { @MainActor in
            defer { isSubmittingLiveMessage = false }
            do {
                let result = try await conversationManager.answerAsyncQuestion(taskID: task.id, question: message, answers: answers)
                if !result.queued { answeredAsyncQuestionIDs.insert(message.id) }
                if let history = result.history {
                    messages = history.messages
                    activities = history.activities
                    answeredAsyncQuestionIDs = Set(history.answeredAsyncQuestionIDs)
                } else if result.queued {
                    refreshQueuedMessages()
                } else {
                    var settledHistory: ConversationHistory?
                    for _ in 0..<50 {
                        if let history = try? await conversationManager.history(taskID: task.id),
                           history.messages.contains(where: { candidate in
                               candidate.role == .assistant &&
                               candidate.asyncQuestions == nil &&
                               !candidate.text.isEmpty &&
                               priorAssistantMessages[candidate.id] != candidate.text
                           }) {
                            settledHistory = history
                            break
                        }
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                    if let settledHistory {
                        messages = settledHistory.messages
                        activities = settledHistory.activities
                        answeredAsyncQuestionIDs = Set(settledHistory.answeredAsyncQuestionIDs)
                    } else {
                        messages.append(ConversationMessage(id: UUID().uuidString, role: .user, text: result.text))
                    }
                }
                errorMessage = nil
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func assistantBubble(_ message: ConversationMessage) -> some View {
        let displayText = Self.displayableAssistantText(message.text)
        let accessibilityText = displayText.count <= 1_000 && !displayText.isEmpty
            ? displayText
            : "Response from \((message.provider ?? provider).displayName)"
        let responseAnnotations = responseAnnotationReferences(for: message)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let createdAt = message.createdAt {
                    Text(createdAt, format: .dateTime.hour().minute())
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .accessibilityIdentifier("message-time-\(message.id)")
                }
                Text(assistantLabel(for: message))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("assistant-provider-\(message.id)")
            }

            ForEach(Array(message.imageDataURLs.enumerated()), id: \.offset) { index, dataURL in
                if let image = Self.image(fromDataURL: dataURL) {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 520, maxHeight: 420)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .accessibilityIdentifier("chat-image-\(message.id)-\(index)")
                }
            }
            if !displayText.isEmpty {
                assistantMarkdownContent(displayText, messageID: message.id, responseAnnotations: responseAnnotations)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(WorkspaceTheme.conversationText)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 11)
                    .background(WorkspaceTheme.panelBackground, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(accessibilityText)
                    .accessibilityIdentifier("assistant-message-\(message.id)")
            }
        }
        .frame(maxWidth: 620, alignment: .leading)
    }

    private func userBubble(_ message: ConversationMessage) -> some View {
        let accessibleText = Self.displayableUserText(message.text)
        return ZStack(alignment: .topLeading) {
            VStack(alignment: .trailing, spacing: 8) {
                ForEach(Array(message.imageDataURLs.enumerated()), id: \.offset) { index, dataURL in
                    if let image = Self.image(fromDataURL: dataURL) {
                        Button { selectedChatImage = image } label: {
                            Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 260, maxHeight: 220)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open attached image")
                        .accessibilityIdentifier("chat-image-\(message.id)-\(index)")
                        .buttonHoverPointer()
                        .help("Open image at full size")
                    }
                }
                let visibleText = Self.displayableUserText(message.text)
                if !visibleText.isEmpty {
                    SelectableAnnotationText(
                        text: visibleText,
                        annotations: annotations.filter { $0.messageID == message.id && $0.blockID == 0 },
                        textColor: .white,
                        onSelection: { range, selectedText, bounds in
                            currentTextSelection = selectedText.isEmpty ? nil : AnnotationSelection(
                                messageID: message.id, blockID: 0, range: range, text: selectedText, bounds: bounds
                            )
                        }
                    )
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16).padding(.vertical, 11)
                        .background(WorkspaceTheme.accent, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                }
                if let createdAt = message.createdAt {
                    Text(createdAt, format: .dateTime.hour().minute())
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .accessibilityIdentifier("message-time-\(message.id)")
                }
            }
            .frame(maxWidth: 620, alignment: .trailing)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(accessibleText.isEmpty ? "Attached image" : accessibleText)
            .accessibilityIdentifier("user-message-\(message.id)")
            if currentTextSelection?.messageID == message.id,
               currentTextSelection?.blockID == 0 {
                selectionHint(messageID: message.id, blockID: 0)
                    .offset(y: -16)
            }
        }
    }

    private static func markdownAttributedText(_ markdown: String) -> AttributedString {
        (try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .full)))
            ?? AttributedString(markdown)
    }

    /// Bridges Markdown-parsed text to `NSAttributedString`, resizing inline code/bold/italic
    /// runs to `baseFont`'s point size (preserving their monospace/bold/italic traits) instead of
    /// the parser's own default-size font, so inline formatting matches the surrounding body text.
    private static func markdownNSAttributedString(_ markdown: String, baseFont: NSFont) -> NSAttributedString {
        var attributed = Self.markdownAttributedText(markdown)
        for run in attributed.runs {
            guard let intent = run.inlinePresentationIntent else { continue }
            if intent.contains(.code) {
                attributed[run.range].appKit.font = NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular)
            } else {
                var traits: NSFontTraitMask = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.boldFontMask) }
                if intent.contains(.emphasized) { traits.insert(.italicFontMask) }
                if !traits.isEmpty {
                    attributed[run.range].appKit.font = NSFontManager.shared.convert(baseFont, toHaveTrait: traits)
                }
            }
        }
        return NSAttributedString(attributed)
    }

    private static func displayableAssistantText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "<proposed_plan>", with: "")
            .replacingOccurrences(of: "</proposed_plan>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func displayableUserText(_ text: String) -> String {
        let commentEnvelopeStart = text.range(of: "<stationai-comment-context>")
            ?? text.range(of: "<stationai-annotation-context>")
        let commentEnvelopeEnd = commentEnvelopeStart.flatMap { envelope in
            text.range(of: "</stationai-comment-context>", range: envelope.upperBound..<text.endIndex)
                ?? text.range(of: "</stationai-annotation-context>", range: envelope.upperBound..<text.endIndex)
        }
        if let envelope = commentEnvelopeStart, commentEnvelopeEnd != nil,
           Self.containsSerializedAnnotations(text) {
            return String(text[..<envelope.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let legacyHeader = "# Response annotations:\nThe following JSON contains comments on selected conversation text, in array order."
        if let header = text.range(of: legacyHeader), Self.containsSerializedAnnotations(text) {
            return String(text[..<header.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let commentHeader = "# Response comments:\nThe following JSON contains comments on selected conversation text, in array order."
        if let header = text.range(of: commentHeader), Self.containsSerializedAnnotations(text) {
            return String(text[..<header.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    private static func containsSerializedAnnotations(_ text: String) -> Bool {
        let start = text.range(of: "<response-comments>") ?? text.range(of: "<response-annotations>")
        guard let start,
              let end = text.range(of: "</response-comments>", range: start.upperBound..<text.endIndex)
                ?? text.range(of: "</response-annotations>", range: start.upperBound..<text.endIndex),
              let data = String(text[start.upperBound..<end.lowerBound]).data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              !items.isEmpty else { return false }
        return items.allSatisfy { item in
            guard item["text"] is String, (item["comment"] is String || item["annotation"] is String),
                  let source = item["source"] as? [String: Any] else { return false }
            return source["messageId"] is String && source["blockID"] is Int
                && source["startOffset"] is Int && source["endOffset"] is Int
        }
    }

    private func selectionHint(messageID: String, blockID: Int) -> some View {
        Group {
            if let selection = currentTextSelection,
               selection.messageID == messageID, selection.blockID == blockID {
                GeometryReader { geometry in
                    Button {
                        annotationSelection = selection
                        annotationComment = ""
                    } label: {
                        Text("Add comment")
                            .font(.system(size: 13, weight: .medium))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(.regularMaterial, in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
                            .shadow(color: .black.opacity(0.25), radius: 5, y: 2)
                    }
                    .buttonStyle(.plain)
                    .buttonHoverPointer()
                    .help("Add comment to selected text")
                    .accessibilityIdentifier("add-comment-to-selection-button")
                    .frame(width: 112, height: 30)
                    .position(
                        x: min(max(selection.bounds.midX, 56), max(56, geometry.size.width - 56)),
                        y: geometry.size.height - selection.bounds.maxY - 22
                    )
                    .zIndex(20)
                    .popover(isPresented: Binding(
                        get: { annotationSelection?.id == selection.id },
                        set: { isPresented in
                            if !isPresented, annotationSelection?.id == selection.id {
                                annotationSelection = nil
                                annotationComment = ""
                            }
                        }
                    ), arrowEdge: .top) {
                        HStack(spacing: 10) {
                            TextField("Add an optional comment…", text: $annotationComment)
                                .textFieldStyle(.plain)
                                .onSubmit { addAnnotation(selection) }
                                .accessibilityIdentifier("comment-input-field")
                            Button { addAnnotation(selection) } label: {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color.black)
                                    .frame(width: 32, height: 32)
                                    .background(Color.white.opacity(0.78), in: Circle())
                            }
                            .buttonHoverPointer()
                            .buttonStyle(.plain)
                            .help("Add comment")
                            .accessibilityLabel("Add comment")
                            .accessibilityIdentifier("add-comment-button")
                        }
                        .padding(.leading, 15)
                        .padding(.trailing, 7)
                        .padding(.vertical, 7)
                        .frame(width: 355)
                        .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
                        .padding(5)
                    }
                }
            }
        }
    }

    private func assistantMarkdownContent(
        _ markdown: String,
        messageID: String? = nil,
        responseAnnotations: [ResponseAnnotationReference] = []
    ) -> some View {
        let blocks = Self.markdownBlocks(markdown)
        return VStack(alignment: .leading, spacing: 7) {
            ForEach(blocks) { block in
                switch block.kind {
                case .heading(let level):
                    selectableAnnotationText(block, messageID: messageID, responseAnnotations: responseAnnotations)
                        .font(.system(size: level == 1 ? 19 : level == 2 ? 17 : 15, weight: .semibold))
                        .accessibilityIdentifier("assistant-markdown-heading-\(block.id)")
                case .listItem:
                    // The marker is rendered through the same SelectableAnnotationText/NSTextView
                    // plumbing as the content (see `markerText`), not a plain SwiftUI `Text`, so
                    // both sides share identical font metrics and textContainerInset. Two
                    // different text-layout engines (SwiftUI's vs. AppKit's) never report
                    // identical line metrics for "the same" font size, so matching the engine is
                    // what actually guarantees pixel alignment instead of a guessed padding value.
                    HStack(alignment: .top, spacing: 7) {
                        markerText("•")
                        selectableAnnotationText(block, messageID: messageID, responseAnnotations: responseAnnotations)
                            .accessibilityIdentifier("assistant-markdown-list-content-\(block.id)")
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("assistant-markdown-list-item-\(block.id)")
                case .orderedListItem(let number):
                    HStack(alignment: .top, spacing: 7) {
                        markerText("\(number).")
                        selectableAnnotationText(block, messageID: messageID, responseAnnotations: responseAnnotations)
                            .accessibilityIdentifier("assistant-markdown-ordered-list-content-\(block.id)")
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("assistant-markdown-ordered-list-item-\(block.id)")
                case .codeBlock(let language):
                    CodeBlockCardView(blockID: block.id, code: block.text, language: language, font: block.font)
                        .accessibilityIdentifier("assistant-markdown-code-block-\(block.id)")
                case .paragraph:
                    selectableAnnotationText(block, messageID: messageID, responseAnnotations: responseAnnotations)
                        .accessibilityIdentifier("assistant-markdown-paragraph-\(block.id)")
                        .padding(.bottom, 5)
                }
            }
        }
    }

    @ViewBuilder
    private func selectableAnnotationText(
        _ block: AssistantMarkdownBlock,
        messageID: String?,
        responseAnnotations: [ResponseAnnotationReference] = []
    ) -> some View {
        if let messageID {
            SelectableAnnotationText(
                text: String(Self.markdownAttributedText(block.text).characters),
                annotations: annotations.filter { $0.messageID == messageID && $0.blockID == block.id },
                responseAnnotations: responseAnnotations,
                responseCommentSourcePrefix: "\(messageID):\(block.id)",
                isAssistantText: true,
                onSelection: { range, text, bounds in
                    currentTextSelection = text.isEmpty ? nil : AnnotationSelection(messageID: messageID, blockID: block.id, range: range, text: text, bounds: bounds)
                },
                formattedText: Self.markdownNSAttributedString(block.text, baseFont: block.font),
                font: block.font
            )
                .fixedSize(horizontal: false, vertical: true)
                .overlay(alignment: .topLeading) { selectionHint(messageID: messageID, blockID: block.id) }
        } else {
            let formatted = Self.markdownNSAttributedString(block.text, baseFont: block.font)
            Text((try? AttributedString(formatted, including: \.appKit)) ?? Self.markdownAttributedText(block.text))
        }
    }

    /// Renders a list marker ("•" or "1.") through the same `SelectableAnnotationText`/NSTextView
    /// plumbing as list-item content, so the marker shares identical font metrics and
    /// `textContainerInset` with its sibling content view — guaranteeing `.top`-aligned HStack
    /// rows line up exactly, rather than approximating the gap between two different text-layout
    /// engines (SwiftUI `Text` vs. AppKit `NSTextView`) with a guessed padding constant.
    private func markerText(_ marker: String) -> some View {
        let markerFont = NSFont.systemFont(ofSize: 16)
        // Measure the marker itself instead of a fixed column width, so two-digit (or longer)
        // ordered-list numbers ("10.", "100.") get enough width and never wrap/clip.
        let markerWidth = NSAttributedString(string: marker, attributes: [.font: markerFont]).size().width
        return SelectableAnnotationText(
            text: marker,
            annotations: [],
            onSelection: { _, _, _ in },
            formattedText: NSAttributedString(string: marker, attributes: [
                .font: markerFont,
                .foregroundColor: NSColor.secondaryLabelColor,
            ]),
            font: markerFont
        )
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: ceil(markerWidth) + 4, alignment: .leading)
    }

    private func addAnnotation(_ selection: AnnotationSelection) {
        annotations.append(ConversationAnnotation(
            id: UUID(), messageID: selection.messageID, blockID: selection.blockID,
            startOffset: selection.range.location, endOffset: NSMaxRange(selection.range),
            text: selection.text, comment: annotationComment.trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        annotationSelection = nil
        currentTextSelection = nil
        annotationComment = ""
    }

    private func responseAnnotationReferences(for message: ConversationMessage) -> [ResponseAnnotationReference] {
        guard let messageIndex = messages.firstIndex(where: { $0.id == message.id }),
              let userMessage = messages[..<messageIndex].last(where: { $0.role == .user }),
              let start = userMessage.text.range(of: "<response-comments>")
                ?? userMessage.text.range(of: "<response-annotations>"),
              let end = userMessage.text.range(of: "</response-comments>", range: start.upperBound..<userMessage.text.endIndex)
                ?? userMessage.text.range(of: "</response-annotations>", range: start.upperBound..<userMessage.text.endIndex),
              let data = String(userMessage.text[start.upperBound..<end.lowerBound]).data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let text = item["text"] as? String,
                  let comment = item["comment"] as? String ?? item["annotation"] as? String else { return nil }
            return ResponseAnnotationReference(text: text, comment: comment)
        }
    }

    private static func orderedListPrefix(_ line: Substring) -> (number: Int, rest: Substring)? {
        let digits = line.prefix(while: { $0.isNumber })
        guard !digits.isEmpty, let number = Int(digits) else { return nil }
        let afterDigits = line.dropFirst(digits.count)
        guard afterDigits.first == ".", afterDigits.dropFirst().first == " " else { return nil }
        return (number, afterDigits.dropFirst(2))
    }

    private static func markdownBlocks(_ markdown: String) -> [AssistantMarkdownBlock] {
        var blocks: [AssistantMarkdownBlock] = []
        var paragraphLines: [String] = []
        var paragraphStart: Int?
        // Only treat digit-dot-space prefixes as an ordered list when they form a sequence that
        // starts at 1 and increments by one; otherwise a sentence like "3. 5 billion parameters…"
        // would be mis-parsed as a list item.
        var lastOrderedNumber: Int?

        func flushParagraph() {
            guard let start = paragraphStart, !paragraphLines.isEmpty else { return }
            blocks.append(AssistantMarkdownBlock(
                id: start,
                kind: .paragraph,
                text: paragraphLines.joined(separator: " ")
            ))
            paragraphLines.removeAll()
            paragraphStart = nil
        }

        let rawLines = markdown.components(separatedBy: .newlines)
        var index = 0
        while index < rawLines.count {
            let rawLine = rawLines[index]
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else {
                // A blank line alone does not end an ordered list: Markdown allows a "loose"
                // list with blank lines between items, so `lastOrderedNumber` carries across
                // this gap and only resets once a non-list block actually interrupts it.
                flushParagraph()
                index += 1
                continue
            }
            if line.hasPrefix("```") {
                flushParagraph()
                lastOrderedNumber = nil
                let fenceStart = index
                let language = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                index += 1
                // Only a line consisting solely of backticks closes the fence, matching
                // CommonMark; a mere `hasPrefix("```")` would also match content lines inside the
                // code block itself (e.g. a code sample that demonstrates Markdown fences).
                while index < rawLines.count {
                    let candidate = rawLines[index].trimmingCharacters(in: .whitespaces)
                    if candidate.count >= 3, candidate.allSatisfy({ $0 == "`" }) { break }
                    codeLines.append(rawLines[index])
                    index += 1
                }
                if index < rawLines.count { index += 1 } // consume closing fence
                blocks.append(AssistantMarkdownBlock(
                    id: fenceStart,
                    kind: .codeBlock(language: language.isEmpty ? nil : language),
                    text: codeLines.joined(separator: "\n")
                ))
                continue
            }
            if line.range(of: #":(?:stationai-annotation|codex-annotation)\{index=\"\d+\"\}"#, options: .regularExpression) != nil {
                flushParagraph()
                lastOrderedNumber = nil
                blocks.append(AssistantMarkdownBlock(id: index, kind: .paragraph, text: line))
                index += 1
                continue
            }
            let headingPrefix = line.prefix(while: { $0 == "#" })
            if !headingPrefix.isEmpty, headingPrefix.count <= 6,
               line.dropFirst(headingPrefix.count).first == " " {
                flushParagraph()
                lastOrderedNumber = nil
                blocks.append(AssistantMarkdownBlock(
                    id: index,
                    kind: .heading(headingPrefix.count),
                    text: String(line.dropFirst(headingPrefix.count + 1))
                ))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                flushParagraph()
                lastOrderedNumber = nil
                blocks.append(AssistantMarkdownBlock(id: index, kind: .listItem, text: String(line.dropFirst(2))))
            } else if let ordered = orderedListPrefix(line[...]),
                      paragraphLines.isEmpty,
                      ordered.number == (lastOrderedNumber.map { $0 + 1 } ?? 1) {
                flushParagraph()
                lastOrderedNumber = ordered.number
                blocks.append(AssistantMarkdownBlock(id: index, kind: .orderedListItem(number: ordered.number), text: String(ordered.rest)))
            } else {
                lastOrderedNumber = nil
                paragraphStart = paragraphStart ?? index
                paragraphLines.append(line)
            }
            index += 1
        }
        flushParagraph()
        return blocks
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !pendingImages.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(pendingImages) { attachment in
                            ZStack(alignment: .topTrailing) {
                                Button { selectedChatImage = attachment.image } label: {
                                    Image(nsImage: attachment.image).resizable().scaledToFill()
                                        .frame(width: 64, height: 52)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Open attached image")
                                .accessibilityIdentifier("pending-chat-image-\(attachment.id)")
                                .buttonHoverPointer()
                                .help("Open image at full size")

                                Button {
                                    pendingImages.removeAll { $0.id == attachment.id }
                                    persistDraftImages()
                                } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .black.opacity(0.7))
                                }
                                .buttonHoverPointer()
                                .help("Remove image")
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove image")
                            }
                        }
                    }
                }.accessibilityIdentifier("pending-chat-images")
            }
            if let actionNotice {
                Label(actionNotice, systemImage: "hand.raised.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("codex-action-notice")
            }
            if let providerNotice {
                Label(providerNotice, systemImage: "arrow.triangle.swap")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("provider-capabilities-notice")
            }

            if !isRepositoryRootConfigured {
                HStack(spacing: 8) {
                    Label("Set the repository root folder before sending.", systemImage: "folder.badge.questionmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("repository-root-required-notice")
                    Spacer(minLength: 0)
                    Button("Set root folder…") {
                        chooseRepositoryParentFolder(showRepositoryPickerWhenFinished: false)
                    }
                    .buttonHoverPointer()
                    .buttonStyle(.bordered)
                    .help("Choose the folder that contains your repositories.")
                    .accessibilityIdentifier("set-conversation-repository-root-button")
                }
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(errorMessage)
                    .accessibilityIdentifier("codex-chat-error")
            }

            if !queuedMessages.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(queuedMessages) { queued in
                        HStack(spacing: 12) {
                            Image(systemName: "text.line.first.and.arrowtriangle.forward")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.secondary)
                            Text(queued.text)
                                .font(.system(size: 14))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier("queued-message-text-\(queued.id.uuidString)")
                            if queued.state == .needsAction {
                                Text("Needs action")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel("Follow-up needs your action")
                                    .accessibilityIdentifier("queued-message-needs-action-\(queued.id.uuidString)")
                                Button { retryQueuedMessage(queued) } label: {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 13, weight: .medium))
                                }
                                .buttonHoverPointer()
                                .help("Retry this follow-up")
                                .accessibilityLabel("Retry follow-up")
                                .accessibilityIdentifier("retry-queued-message-\(queued.id.uuidString)")
                            } else {
                                Button("Steer") { steerQueuedMessage(queued) }
                                    .disabled(isSubmittingLiveMessage)
                                    .buttonHoverPointer()
                                    .help("Send this follow-up to the active turn now")
                                    .accessibilityIdentifier("steer-queued-message-\(queued.id.uuidString)")
                            }
                            Button { removeQueuedMessage(queued) } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 13, weight: .medium))
                            }
                            .buttonHoverPointer()
                            .help("Remove this follow-up")
                            .accessibilityLabel("Remove follow-up")
                            .accessibilityIdentifier("remove-queued-message-\(queued.id.uuidString)")
                            Menu {
                                Button("Copy text") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(queued.text, forType: .string)
                                }
                                .buttonHoverPointer()
                                .help("Copy this follow-up")
                                Button("Remove follow-up", role: .destructive) { removeQueuedMessage(queued) }
                                    .buttonHoverPointer()
                                    .help("Remove this follow-up")
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 13, weight: .semibold))
                                    .frame(width: 24, height: 24)
                                    .contentShape(Rectangle())
                            }
                            .buttonHoverPointer()
                            .help("More follow-up actions")
                            .menuStyle(.borderlessButton)
                            .accessibilityLabel("More follow-up actions")
                            .accessibilityIdentifier("queued-message-more-\(queued.id.uuidString)")
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("queued-message-\(queued.id.uuidString)")
                    }
                }
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("queued-follow-ups")
            }

            VStack(alignment: .leading, spacing: 10) {
                let pendingCommentCount = annotations.filter(\.pending).count
                if pendingCommentCount > 0 {
                    Label("\(pendingCommentCount) comment\(pendingCommentCount == 1 ? "" : "s")", systemImage: "text.bubble")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.82))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
                        .accessibilityIdentifier("pending-comment-count")
                }

                if let activeGoal, activeGoal.status != "complete", !isReadOnly, provider.supportsGoals {
                    HStack(spacing: 10) {
                        Image(systemName: "scope").font(.system(size: 17, weight: .medium)).foregroundStyle(.secondary)
                        Text("\(activeGoal.status == "paused" ? "Paused goal" : "Pursuing goal") \(activeGoal.objective)")
                            .lineLimit(1).truncationMode(.tail).font(.system(size: 15))
                            .accessibilityIdentifier("active-goal-title")
                        Spacer(minLength: 4)
                        if let seconds = activeGoal.timeUsedSeconds {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                Text(Self.goalDuration(goalElapsedTime(for: activeGoal, reportedSeconds: seconds)
                                    + (activeGoal.status == "active" ? context.date.timeIntervalSince(goalStatusUpdatedAt) : 0)))
                                    .foregroundStyle(.secondary)
                                    .accessibilityIdentifier("goal-elapsed-time")
                            }
                        }
                        Button(role: .destructive) { Task { await mutateGoal("clear") } } label: { Image(systemName: "trash") }
                            .buttonHoverPointer().buttonStyle(.plain).help("Clear goal")
                            .accessibilityLabel("Clear goal").accessibilityIdentifier("goal-clear-button")
                        Button { Task { await mutateGoal(activeGoal.status == "paused" ? "resume" : "pause") } } label: {
                            Image(systemName: activeGoal.status == "paused" ? "play.fill" : "pause")
                        }
                            .buttonHoverPointer().buttonStyle(.plain).help(activeGoal.status == "paused" ? "Resume goal" : "Pause goal")
                            .accessibilityLabel(activeGoal.status == "paused" ? "Resume goal" : "Pause goal")
                            .accessibilityIdentifier("goal-pause-resume-button")
                        Button { isGoalExpanded.toggle() } label: { Image(systemName: isGoalExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") }
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                            .buttonHoverPointer().buttonStyle(.plain).help(isGoalExpanded ? "Collapse goal" : "Expand goal")
                            .accessibilityLabel(isGoalExpanded ? "Collapse goal" : "Expand goal")
                            .accessibilityValue(isGoalExpanded ? "Expanded" : "Collapsed")
                            .accessibilityIdentifier("goal-expand-button")
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Color.primary.opacity(0.10), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1) }
                    .accessibilityElement(children: .contain)
                    .accessibilityValue(codexClient.goalTurnStartedThreadID == task.codexThreadID ? "Work started" : (codexClient.isTurnActive(threadID: task.codexThreadID ?? "") ? "Working" : "Waiting"))
                    .accessibilityIdentifier("active-goal-progress-row")
                    if isGoalExpanded {
                        Text(activeGoal.objective).font(.system(size: 13)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14)
                            .accessibilityIdentifier("active-goal-details")
                    }
                }
                NativeChatEditor(
                    text: $draft,
                    height: $composerHeight,
                    isFocused: Binding(get: { isComposerFocused }, set: { isComposerFocused = $0 }),
                    isEnabled: !isReadOnly,
                    autofocusOnAppear: isNewTask,
                    accessibilityHelp: isReadOnly
                        ? "Archived conversation, read-only."
                         : (isResponding ? "Press Return to queue this follow-up. Press Command-Return to steer the active turn, or use a queued row's Steer action."
                            : (isLoadingHistory ? "Composer unavailable while conversation history loads." : "")),
                    onSubmit: {
                        if isResponding {
                            queueDraftForAfterTurn()
                        } else {
                            sendMessage()
                        }
                    },
                    onSteerSubmit: {
                        if isResponding, isConversationTurnActive {
                            steerCurrentTurn()
                        }
                    },
                    onPasteImage: { image in
                        do { try addImageData(image) }
                        catch { errorMessage = error.localizedDescription }
                    }
                )
                    .frame(height: composerHeight)
                    .overlay(alignment: .topLeading) {
                        if draft.isEmpty {
                            Text(isEnteringGoal ? "Set a goal to keep pursuing" : (isResponding || activeGoal != nil ? "Ask for follow-up changes" : "Message…"))
                                .font(.system(size: 15))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 5)
                                .padding(.top, 4)
                                .allowsHitTesting(false)
                                .accessibilityIdentifier("composer-placeholder")
                        }
                    }
                    .onChange(of: draft) { _, newValue in
                        if newValue.trimmingCharacters(in: .whitespacesAndNewlines) == "/plan" {
                            activatePlanMode()
                        } else if newValue.trimmingCharacters(in: .whitespacesAndNewlines) == "/goal", provider.supportsGoals {
                            isEnteringGoal = true
                            draft = ""
                        }
                        if !isReadOnly, !isResponding, !isLoadingHistory {
                            draftNeedsAutosave = true
                        }
                        scheduleDraftAutosave(newValue)
                    }
                    .disabled(isReadOnly || isPreparingSubmittedMessage)
                    .accessibilityIdentifier("message-composer-scroll-view")

                HStack(spacing: 12) {
                    Button { isShowingImagePicker = true } label: { Image(systemName: "paperclip") }
                    .buttonHoverPointer()
                    .help("Attach image")
                        .buttonStyle(.plain).accessibilityLabel("Attach image")
                        .accessibilityIdentifier("attach-chat-image-button")
                    Menu {
                        if provider.supportsGoals {
                            Button {
                                isEnteringGoal = true
                                draft = ""
                            } label: {
                                Label("Goal", systemImage: "scope")
                            }
                            .buttonHoverPointer()
                            .help("Set a goal to keep pursuing")
                            .accessibilityIdentifier("conversation-mode-goal")
                        }
                        ForEach(ConversationMode.allCases, id: \.self) { mode in
                            Button {
                                isEnteringGoal = false
                                setConversationMode(mode)
                            } label: {
                                if conversationMode == mode {
                                    Label(mode.title, systemImage: "checkmark")
                                } else {
                                    Text(mode.title)
                                }
                            }
                            .buttonHoverPointer()
                            .help("Switch to \(mode.title) mode")
                            .accessibilityIdentifier("conversation-mode-\(mode.rawValue)")
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "plus")
                                .font(.system(size: 14, weight: .semibold))
                            if isEnteringGoal {
                                Image(systemName: "scope")
                                Text("Goal")
                                    .font(.system(size: 11, weight: .semibold))
                            } else if conversationMode == .plan {
                                Text("Plan")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                        }
                        .foregroundStyle(isEnteringGoal || conversationMode == .plan ? Color.accentColor : Color.secondary)
                        .frame(minWidth: 30, minHeight: 31)
                        .contentShape(Rectangle())
                    }
                    .buttonHoverPointer()
                    .menuStyle(.borderlessButton)
                    .help("Change conversation mode or add context")
                    .accessibilityLabel(isEnteringGoal ? "Goal" : "Conversation mode: \(conversationMode.title)")
                    .accessibilityIdentifier("conversation-mode-menu")

                    if conversationMode == .plan && !isResponding && !isReadOnly {
                        Button(action: startImplementingPlan) {
                            Text("Start Implementing")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 11)
                                .frame(height: 31)
                                .background(Color.accentColor, in: Capsule())
                        }
                        .buttonHoverPointer()
                        .buttonStyle(.plain)
                        .disabled(workspaceRootURLs.isEmpty || isLoadingHistory || isPreparingSubmittedMessage)
                        .help("Switch to Code mode and start implementing this plan")
                        .accessibilityIdentifier("start-implementing-button")
                    }

                    Spacer(minLength: 0)

                    providerMenu

                    Button {
                        if isModelPickerPresented {
                            commitModelPickerSelection()
                            isModelPickerPresented = false
                        } else {
                            pickerModelID = selectedModelID
                            pickerEffort = selectedEffort
                            isModelPickerPresented = true
                        }
                    } label: {
                        HStack(spacing: 7) {
                            Text(selectedModelName)
                            Text(selectedEffort.title).foregroundStyle(.secondary)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.82))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .buttonHoverPointer()
                    .help("Choose a model and reasoning effort")
                    .accessibilityLabel("Model: \(selectedModelName), effort: \(selectedEffort.title)")
                    .accessibilityValue(selectedModelName)
                    .accessibilityIdentifier("model-picker-menu")
                    .popover(isPresented: Binding(
                        get: { isModelPickerPresented },
                        set: { isPresented in
                            if !isPresented && isModelPickerPresented {
                                commitModelPickerSelection()
                            }
                            isModelPickerPresented = isPresented
                        }
                    ), arrowEdge: .top) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(modelOptions) { model in
                                Button {
                                    selectPickerModel(model)
                                } label: {
                                    HStack {
                                        Text(model.name)
                                        Spacer()
                                        if pickerModelID == model.id || (pickerModelID.isEmpty && model.isDefault) {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 12, weight: .semibold))
                                        }
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .buttonHoverPointer()
                                .help("Select \(model.name)")
                                .accessibilityIdentifier("model-option-\(model.id)")
                            }
                            Divider().padding(.vertical, 8)
                            Text(pickerEffort.title)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                                .accessibilityIdentifier("selected-model-effort")
                            EffortStepSlider(selection: $pickerEffort, choices: pickerEffortChoices)
                                // The native slider knob is translucent on macOS 26, so it is drawn by EffortStepSlider
                                // and the native Slider serves only as the accessibility representation.
                                .accessibilityRepresentation {
                                    if pickerEffortChoices.count > 1 {
                                        Slider(value: Binding(
                                            get: { Double(pickerEffortChoices.firstIndex(of: pickerEffort) ?? 0) },
                                            set: { pickerEffort = pickerEffortChoices[min(max(Int($0.rounded()), 0), pickerEffortChoices.count - 1)] }
                                        ), in: 0...Double(pickerEffortChoices.count - 1), step: 1)
                                        .accessibilityLabel("Model effort")
                                        .accessibilityValue(pickerEffort.title)
                                        .accessibilityIdentifier("model-effort-slider")
                                        .focusEffectDisabled()
                                    } else {
                                        Text(pickerEffort.title)
                                            .accessibilityElement()
                                            .accessibilityLabel("Model effort")
                                            .accessibilityValue(pickerEffort.title)
                                            .accessibilityIdentifier("model-effort-slider")
                                    }
                                }
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 13)
                        .frame(width: 320)
                    }

                    if isDisplayingActiveResponse {
                        Button(action: pauseResponse) {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 31, height: 31)
                                .background(Color.primary.opacity(0.72), in: RoundedRectangle(cornerRadius: 9))
                        }
                        .buttonHoverPointer()
                        .help("Pause \(provider.displayName) response")
                        .buttonStyle(.plain)
                        .disabled(isPausingResponse || !canPauseResponse)
                        .accessibilityLabel("Stop response")
                        .accessibilityIdentifier("pause-response-button")
                    } else if hasPausedResponse {
                        Button(action: continueResponse) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 31, height: 31)
                                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 9))
                        }
                        .buttonHoverPointer()
                        .help("Continue \(provider.displayName) response")
                        .buttonStyle(.plain)
                        .accessibilityLabel("Continue response")
                        .accessibilityIdentifier("continue-response-button")
                    } else {
                        Button { sendMessage() } label: {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 31, height: 31)
                                .background(Color.accentColor, in: Circle())
                        }
                        .buttonHoverPointer()
                        .help("Send message")
                        .buttonStyle(.plain)
                        .disabled(isSendDisabled)
                        .opacity(isSendDisabled ? 0.45 : 1)
                        .accessibilityLabel("Send message")
                        .accessibilityIdentifier("send-message-button")
                    }
                }
            }
            .padding(13)
            .background(WorkspaceTheme.panelBackground)
            .clipShape(RoundedRectangle(cornerRadius: 21, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 21, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 14)
        .padding(.bottom, 22)
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat-composer")
    }

    private func userInputForm(_ request: ConversationUserInputRequest) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("A few questions")
                .font(.system(size: 14, weight: .semibold))
                .accessibilityIdentifier("ai-question-form-title")
            ForEach(request.questions) { question in
                VStack(alignment: .leading, spacing: 7) {
                    Text(question.question).font(.system(size: 12, weight: .medium))
                    if question.options.isEmpty {
                        Group {
                            if question.isSecret {
                                SecureField("Answer", text: Binding(
                                    get: { userInputAnswers[question.id]?.first ?? "" },
                                    set: { userInputAnswers[question.id] = [$0] }
                                ))
                            } else {
                                TextField("Your answer", text: Binding(
                                    get: { userInputAnswers[question.id]?.first ?? "" },
                                    set: { userInputAnswers[question.id] = [$0] }
                                ))
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("ai-question-answer-\(question.id)")
                    } else {
                        ForEach(question.options) { option in
                            let isSelected = (userInputAnswers[question.id] ?? []).first == option.label
                            Button {
                                userInputAnswers[question.id] = [option.label]
                                userInputOtherSelected.remove(question.id)
                            } label: {
                                Label(option.label, systemImage: isSelected ? "largecircle.fill.circle" : "circle")
                            }
                            .buttonHoverPointer()
                            .help("Select answer: \(option.label)")
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("ai-question-option-\(question.id)-\(option.label)")
                            .accessibilityValue(isSelected ? "selected" : "not selected")
                        }
                        if question.allowsOther {
                            Button {
                                userInputAnswers[question.id] = []
                                userInputOtherSelected.insert(question.id)
                            } label: {
                                Label("Other", systemImage: userInputOtherSelected.contains(question.id) ? "largecircle.fill.circle" : "circle")
                            }
                            .buttonHoverPointer()
                            .help("Select a free-text answer")
                            .buttonStyle(.plain)
                            .accessibilityValue(userInputOtherSelected.contains(question.id) ? "selected" : "not selected")
                            TextField("Other answer", text: Binding(
                                get: { userInputOther[question.id] ?? "" },
                                set: {
                                    userInputOther[question.id] = $0
                                    userInputAnswers[question.id] = []
                                    userInputOtherSelected.insert(question.id)
                                }
                            ))
                            .textFieldStyle(.roundedBorder)
                        }
                    }
                }
            }
            Button("Submit answers") {
                Task { @MainActor in await submitUserInput(request) }
            }
            .buttonHoverPointer()
            .help("Submit answers")
                .buttonStyle(.borderedProminent)
                .disabled(request.questions.contains { question in
                    let selections = userInputAnswers[question.id] ?? []
                    return selections.isEmpty && (!userInputOtherSelected.contains(question.id) || (userInputOther[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                })
                .accessibilityIdentifier("submit-ai-answers-button")
        }
        .padding(16)
        .frame(maxWidth: 720, alignment: .leading)
        .background(WorkspaceTheme.panelBackground, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
    }

    private func submitUserInput(_ request: ConversationUserInputRequest) async {
        var answers: [String: [String]] = [:]
        for question in request.questions {
            var values = userInputAnswers[question.id] ?? []
            if userInputOtherSelected.contains(question.id), let other = userInputOther[question.id]?.trimmingCharacters(in: .whitespacesAndNewlines), !other.isEmpty {
                values = [other]
            }
            answers[question.id] = values
        }
        isResponding = true
        errorMessage = nil
        do {
            let accepted = try await conversationManager.answerUserInput(
                taskID: task.id,
                request: request,
                answers: answers,
                modelID: selectedModelID.isEmpty ? nil : selectedModelID,
                onUpdate: { update in
                    guard update.type == "user_input", let nextRequest = update.userInputRequest else { return }
                    userInputRequest = nextRequest
                    userInputAnswers = [:]
                    userInputOther = [:]
                    userInputOtherSelected = []
                }
            )
            guard accepted else {
                isResponding = false
                errorMessage = "\(provider.displayName) couldn't accept those answers. Please check the responses and try again."
                return
            }
            userInputRequest = nil
            userInputAnswers = [:]
            userInputOther = [:]
            userInputOtherSelected = []
            await loadConversation()
        } catch {
            isResponding = providerClient.isTurnActive(threadID: request.threadID)
            errorMessage = error.localizedDescription
        }
    }

    private func loadConversation() async {
        isLoadingHistory = true
        hasPresentedLatestConversation = false
        isLatestConversationTurnPinPending = true
        isOlderConversationRevealArmed = false
        conversationContentHeight = 0
        oldestRenderedMessageID = nil
        errorMessage = nil
        let draftAtLoadStart = draft
        defer { isLoadingHistory = false }

        do {
            let history = try await conversationManager.history(taskID: task.id) {
                actionNotice = approvalNotice
            }
            messages = history.messages
            // Resolve the window as soon as the messages land. The assignment
            // at the end of the load repeats it once progress collapsing has
            // settled which rows the transcript renders.
            oldestRenderedMessageID = latestConversationTurnStartID
            let savedUserInputRequest = history.pendingUserInputRequest?.threadID == task.activeConversationID
                ? history.pendingUserInputRequest
                : nil
            let currentProviderRequest = providerPendingUserInputRequest
            let liveUserInputRequest = currentProviderRequest?.threadID == task.activeConversationID
                ? currentProviderRequest
                : nil
            // A history read can finish after the provider has raised a question
            // but before that request has been persisted. Keep the live request
            // visible instead of letting that older snapshot clear it.
            userInputRequest = savedUserInputRequest ?? liveUserInputRequest
            restoreAnnotations(from: history.messages)
            answeredAsyncQuestionIDs = Set(history.answeredAsyncQuestionIDs)
            activities = history.activities
            providerBoundaries = history.providerBoundaries
            activeGoal = try? await conversationManager.goal(taskID: task.id)
            let defaults = WorkspaceSettings.preferencesStore
            if let data = defaults.data(forKey: goalAchievementTimelineDefaultsKey),
               let entries = try? JSONDecoder().decode([GoalAchievementTimelineEntry].self, from: data) {
                goalAchievementTimelineEntries = entries
            }
            currentGoalGenerationID = defaults.string(forKey: goalGenerationDefaultsKey)
            currentGoalObjective = defaults.string(forKey: goalGenerationObjectiveDefaultsKey)
            currentGoalTimeBaselineSeconds = defaults.object(forKey: goalGenerationTimeBaselineDefaultsKey) as? Double
            if let activeGoal {
                reconcileGoalGeneration(with: activeGoal)
                if activeGoal.status == "complete",
                   let generationID = currentGoalGenerationID,
                   !goalAchievementTimelineEntries.contains(where: { $0.id == generationID }) {
                    let anchorID = fallbackGoalCompletionAnchorID(in: history.messages, objective: activeGoal.objective)
                    goalAchievementTimelineEntries.append(GoalAchievementTimelineEntry(
                        id: generationID,
                        summary: goalAchievementSummary(activeGoal),
                        afterMessageID: anchorID
                    ))
                    persistGoalAchievementTimeline()
                }
            }
            goalStatusUpdatedAt = .now
            let promptWasSent = task.savedPrompt.map { prompt in
                history.messages.contains { $0.role == .user && $0.text == prompt }
            } ?? false
            let hasPendingSubmittedPrompt = task.pendingSubmittedPrompt != nil
            if hasPendingSubmittedPrompt,
               !promptWasSent,
               let submittedPrompt = task.pendingSubmittedPrompt,
               !submittedPrompt.isEmpty {
                messages.append(ConversationMessage(id: UUID().uuidString, role: .user, text: submittedPrompt))
            }
            if draft == draftAtLoadStart {
                draft = promptWasSent || hasPendingSubmittedPrompt ? "" : (task.savedPrompt ?? "")
            }
            if !promptWasSent && !hasPendingSubmittedPrompt && pendingImages.isEmpty {
                pendingImages = task.draftImageDataURLs.compactMap { dataURL in
                    guard let comma = dataURL.firstIndex(of: ","),
                          let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])),
                          let image = NSImage(data: data) else { return nil }
                    return PendingImage(dataURL: dataURL, image: image)
                }
            }
            isResponding = hasPendingSubmittedPrompt
                && (task.status == .inProgress || task.status == .waitingResponse)
            if let threadID = task.activeConversationID {
                isResponding = isResponding || providerClient.isTurnActive(threadID: threadID)
            }
            if isResponding {
                responseStartedAt = defaults.object(forKey: responseStartedAtDefaultsKey) as? Date ?? Date()
                defaults.set(responseStartedAt, forKey: responseStartedAtDefaultsKey)
                completedResponseDuration = nil
            } else if let duration = defaults.object(forKey: completedResponseDurationDefaultsKey) as? Int {
                completedResponseDuration = duration
                responseStartedAt = nil
            } else if history.messages.contains(where: { $0.role == .assistant && $0.phase == "final_answer" }),
                      let startedAt = defaults.object(forKey: responseStartedAtDefaultsKey) as? Date {
                let duration = Self.elapsedSeconds(since: startedAt, now: Date())
                completedResponseDuration = duration
                defaults.set(duration, forKey: completedResponseDurationDefaultsKey)
                defaults.removeObject(forKey: responseStartedAtDefaultsKey)
                responseStartedAt = nil
            } else {
                responseStartedAt = nil
                defaults.removeObject(forKey: responseStartedAtDefaultsKey)
            }
            let activeTurnID = history.messages.last(where: { $0.turnID != nil })?.turnID
            collapsedProgressTurnIDs = Set(history.messages.lazy
                .filter {
                    $0.role == .assistant
                        && $0.phase == "final_answer"
                        && (!isResponding || $0.turnID != activeTurnID)
                }
                .compactMap(\.turnID))
            // Open on the newest turn. Progress-message collapsing above changes
            // which rows the transcript renders, so resolve the window start here.
            oldestRenderedMessageID = latestConversationTurnStartID
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func restoreAnnotations(from messages: [ConversationMessage]) {
        var restored: [ConversationAnnotation] = []
        for message in messages where message.role == .user {
            guard let start = message.text.range(of: "<response-comments>")
                    ?? message.text.range(of: "<response-annotations>"),
                  let end = message.text.range(of: "</response-comments>", range: start.upperBound..<message.text.endIndex)
                    ?? message.text.range(of: "</response-annotations>", range: start.upperBound..<message.text.endIndex),
                  let data = String(message.text[start.upperBound..<end.lowerBound]).data(using: .utf8),
                  let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { continue }
            for item in items {
                guard let selectedText = item["text"] as? String,
                      let comment = item["comment"] as? String ?? item["annotation"] as? String,
                      let source = item["source"] as? [String: Any],
                      let sourceID = source["messageId"] as? String,
                      let blockID = source["blockID"] as? Int,
                      let startOffset = source["startOffset"] as? Int,
                      let endOffset = source["endOffset"] as? Int else { continue }
                restored.append(ConversationAnnotation(
                    id: UUID(), messageID: sourceID, blockID: blockID,
                    startOffset: startOffset, endOffset: endOffset,
                    text: selectedText, comment: comment, pending: false
                ))
            }
        }
        annotations = restored
    }

    private func loadModels() async {
        selectedModelID = (try? conversationManager.modelID(taskID: task.id)) ?? ""
        selectedEffort = (try? conversationManager.effort(taskID: task.id)) ?? .medium
        if let cachedModels = try? conversationManager.cachedModels(taskID: task.id), !cachedModels.isEmpty {
            modelOptions = cachedModels.newestVersionPerFamily()
        }
        do {
            modelOptions = try await conversationManager.models(taskID: task.id)
            if !currentEffortChoices.contains(selectedEffort) {
                selectedEffort = currentEffortChoices.contains(.medium) ? .medium : currentEffortChoices[0]
                // Persist the clamp so the CLI and sends read the same effort the composer shows.
                _ = try? await conversationManager.setEffort(taskID: task.id, effort: selectedEffort)
            }
        } catch {
            // Keep the last known model available when an offline or unauthenticated app-server cannot list models.
        }
    }

    private var selectedModelName: String {
        guard !selectedModelID.isEmpty else {
            return modelOptions.first(where: \.isDefault)?.name ?? provider.defaultModelName
        }
        return modelName(for: selectedModelID)
    }

    /// The label shown above an assistant message is based on the model ID
    /// recorded for that turn, so later picker changes do not relabel history.
    private func assistantLabel(for message: ConversationMessage) -> String {
        let messageProvider = message.provider ?? provider
        let modelID = message.modelID
        let cachedModels = messageProvider == provider
            ? modelOptions
            : ((try? conversationManager.cachedModels(taskID: task.id, provider: messageProvider)) ?? [])
        let modelName = modelID.flatMap { id in cachedModels.first(where: { $0.id == id })?.name }
        return messageProvider.assistantLabel(modelName: modelName)
    }

    private var pickerEffortChoices: [ConversationEffort] {
        effortChoices(for: pickerModelID)
    }

    private var currentEffortChoices: [ConversationEffort] {
        effortChoices(for: selectedModelID)
    }

    private func effortChoices(for modelID: String) -> [ConversationEffort] {
        let model = modelID.isEmpty
            ? modelOptions.first(where: \.isDefault)
            : modelOptions.first(where: { $0.id == modelID })
        guard let supported = model?.supportedEfforts,
              !supported.isEmpty else { return ConversationEffort.allCases }
        return ConversationEffort.allCases.filter(supported.contains)
    }

    private func modelName(for modelID: String) -> String {
        modelOptions.first(where: { $0.id == modelID })?.name ?? modelID
    }

    private func selectPickerModel(_ model: ConversationModelOption) {
        pickerModelID = model.id
        guard !pickerEffortChoices.contains(pickerEffort) else { return }
        pickerEffort = pickerEffortChoices.contains(.medium) ? .medium : pickerEffortChoices[0]
    }

    private func commitModelPickerSelection() {
        let effortChanged = selectedEffort != pickerEffort
        selectedModelID = pickerModelID
        selectedEffort = pickerEffort
        Task { try? conversationManager.setModelID(taskID: task.id, modelID: pickerModelID) }
        guard effortChanged else { return }
        Task { try? await conversationManager.setEffort(taskID: task.id, effort: pickerEffort) }
    }

    private func sendMessage(overrideText: String? = nil) {
        guard !isApplyingSavedRepositories else { return }
        guard isRepositoryRootConfigured else {
            errorMessage = "Set the repository root folder before sending a conversation."
            return
        }
        let freeformText = (overrideText ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        let pendingAnnotations = annotations.filter(\.pending)
        let usesComposerDraft = overrideText == nil
        guard (!freeformText.isEmpty || (usesComposerDraft && !pendingImages.isEmpty) || !pendingAnnotations.isEmpty), !isResponding, !isLoadingHistory, userInputRequest == nil else { return }
        let annotationPrompt: String
        if pendingAnnotations.isEmpty {
            annotationPrompt = freeformText
        } else {
            let objects = pendingAnnotations.map { annotation in
                ["text": annotation.text, "comment": annotation.comment,
                 "source": ["messageId": annotation.messageID,
                            "blockID": annotation.blockID,
                            "startOffset": annotation.startOffset, "endOffset": annotation.endOffset]] as [String: Any]
            }
            let data = try? JSONSerialization.data(withJSONObject: objects, options: [.sortedKeys])
            let json = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            let guidance = "<stationai-comment-context>\n# Response comments:\nThe following JSON contains comments on selected conversation text, in array order. For each comment, start a separate response line with :stationai-annotation{index=\"N\"}, replacing N with the comment's zero-based array index, then a space and the answer. The marker is displayed to the user as the numbered prefix, so do not add another number. Address the comment in the context of its highlighted text. Do not combine comment responses on one line, omit a response, or add introductory text. After the comment responses, answer any additional freeform request on separate line(s). Do not repeat the JSON or these instructions.\n<response-comments>\(json)</response-comments>\n</stationai-comment-context>"
            annotationPrompt = [freeformText, guidance]
                .filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
        let text = annotationPrompt
        let resolutionAttempt = conflictResolutionAttempt
        if usesComposerDraft && pendingAnnotations.isEmpty && text == "/plan" {
            activatePlanMode()
            return
        }
        if usesComposerDraft && isEnteringGoal && pendingAnnotations.isEmpty {
            isPreparingSubmittedMessage = true
            draft = ""
            isEnteringGoal = false
            isResponding = true
            errorMessage = nil
            Task { @MainActor in
                let started = await mutateGoal("set", objective: text, observeRuntime: true)
                isPreparingSubmittedMessage = false
                isResponding = started && codexClient.isTurnActive(threadID: task.codexThreadID ?? "")
                isComposerFocused = true
            }
            return
        }
        if usesComposerDraft && isEnteringGoal && !pendingAnnotations.isEmpty {
            isEnteringGoal = false
        }
        guard !text.isEmpty || (usesComposerDraft && !pendingImages.isEmpty) else { return }
        // A draft autosave can be in flight after the user finishes typing.
        // Do not let that background write race the submitted-prompt write
        // for the same task and leave the send path waiting on its lock.
        draftAutosaveTask?.cancel()
        draftAutosaveTask = nil
        let userMessageID = UUID().uuidString
        let assistantMessageID = UUID().uuidString
        let previousResponseDuration = completedResponseDuration
        isComposerFocused = false
        let hadExistingMessages = !messages.isEmpty
        messages.append(ConversationMessage(id: userMessageID, role: .user, text: text,
                                         imageDataURLs: usesComposerDraft ? pendingImages.map(\.dataURL) : []))
        if !hadExistingMessages {
            messages.append(ConversationMessage(id: assistantMessageID, role: .assistant, text: ""))
        }
        isResponding = true
        let startedAt = Date()
        responseStartedAt = startedAt
        completedResponseDuration = nil
        UserDefaults.standard.set(startedAt, forKey: responseStartedAtDefaultsKey)
        UserDefaults.standard.removeObject(forKey: completedResponseDurationDefaultsKey)
        if usesComposerDraft { draft = "" }
        let imageDataURLs = usesComposerDraft ? pendingImages.map(\.dataURL) : []
        if usesComposerDraft { pendingImages = [] }
        hasPausedResponse = false
        isPausingResponse = false
        errorMessage = nil
        actionNotice = nil
        activities = []
        isPreparingSubmittedMessage = true
        let statusBeforeSubmission = task.status

        Task { @MainActor in
            let saved = await saveDraftAndGenerateTitle(
                status: .inProgress,
                prompt: text,
                generateTitle: false,
                reserveTitleForSend: true
            )
            isPreparingSubmittedMessage = false
            guard saved else {
                if resolutionAttempt > 0 {
                    conflictResolutionAttempt = 0
                    onConflictResolutionChecked(false)
                }
                messages.removeAll { $0.id == userMessageID || $0.id == assistantMessageID }
                if usesComposerDraft {
                    draft = freeformText
                    pendingImages = imageDataURLs.compactMap { dataURL in
                        guard let image = Self.image(fromDataURL: dataURL) else { return nil }
                        return PendingImage(dataURL: dataURL, image: image)
                    }
                }
                isResponding = false
                responseStartedAt = nil
                UserDefaults.standard.removeObject(forKey: responseStartedAtDefaultsKey)
                completedResponseDuration = previousResponseDuration
                if let previousResponseDuration {
                    UserDefaults.standard.set(previousResponseDuration, forKey: completedResponseDurationDefaultsKey)
                } else {
                    UserDefaults.standard.removeObject(forKey: completedResponseDurationDefaultsKey)
                }
                return
            }
            do {
                _ = try await conversationManager.setEffort(taskID: task.id, effort: selectedEffort)
                _ = try await conversationManager.send(taskID: task.id, text: text, imageDataURLs: imageDataURLs, mode: conversationMode, modelID: selectedModelID.isEmpty ? nil : selectedModelID, statusBeforeSubmission: statusBeforeSubmission, onTurnStarting: {
                    isResponding = true
                }, onUpdate: { update in
                    switch update.type {
                    case "text_delta":
                        guard let delta = update.text else { return }
                        let messageIndex: Int
                        if let existingIndex = messages.firstIndex(where: { $0.id == assistantMessageID }) {
                            messageIndex = existingIndex
                        } else {
                            messages.append(ConversationMessage(id: assistantMessageID, role: .assistant, text: ""))
                            messageIndex = messages.index(before: messages.endIndex)
                        }
                        messages[messageIndex].text += delta
                    case "assistant_final":
                        guard let text = update.text else { return }
                        if let messageIndex = messages.lastIndex(where: { $0.role == .assistant }),
                           messages[messageIndex].asyncQuestions == nil {
                            messages[messageIndex].text = text
                            messages[messageIndex].phase = "final_answer"
                        } else {
                            messages.append(ConversationMessage(
                                id: UUID().uuidString,
                                role: .assistant,
                                text: text,
                                phase: "final_answer"
                            ))
                        }
                    case "assistant_progress":
                        guard let itemID = update.itemID, let text = update.text else { return }
                        if let index = messages.firstIndex(where: { $0.id == itemID }) {
                            messages[index].text = text
                            messages[index].phase = update.phase
                            messages[index].asyncQuestions = update.asyncQuestions
                        } else if let placeholderIndex = messages.firstIndex(where: { $0.id == assistantMessageID }) {
                            messages.insert(ConversationMessage(
                                id: itemID,
                                role: .assistant,
                                text: text,
                                phase: update.phase,
                                asyncQuestions: update.asyncQuestions
                            ), at: placeholderIndex)
                        } else {
                            messages.append(ConversationMessage(
                                id: itemID,
                                role: .assistant,
                                text: text,
                                phase: update.phase,
                                asyncQuestions: update.asyncQuestions
                            ))
                        }
                        if let placeholderIndex = messages.firstIndex(where: { $0.id == assistantMessageID }) {
                            messages[placeholderIndex].text = ""
                        }
                    case "activity":
                        guard let activity = update.activity else { return }
                        if let index = activities.firstIndex(where: { $0.id == activity.id }) {
                            activities[index] = activity
                        } else {
                            activities.append(activity)
                        }
                    case "diff":
                        break
                    case "history", "completed":
                        guard let history = update.history else { return }
                        var mergedMessages = history.messages
                        if update.type == "completed" {
                            for liveMessage in messages where !liveMessage.text.isEmpty {
                                if let persistedIndex = mergedMessages.firstIndex(where: { $0.id == liveMessage.id }) {
                                    if mergedMessages[persistedIndex].text.isEmpty {
                                        mergedMessages[persistedIndex] = liveMessage
                                    }
                                    continue
                                }
                                let alreadyPersisted = mergedMessages.contains {
                                    $0.role == liveMessage.role && $0.text == liveMessage.text
                                }
                                if !alreadyPersisted {
                                    mergedMessages.append(liveMessage)
                                }
                            }
                        }
                        messages = mergedMessages
                        answeredAsyncQuestionIDs = Set(history.answeredAsyncQuestionIDs)
                        activities = history.activities
                        if update.type == "completed" {
                            let sentIDs = Set(pendingAnnotations.map(\.id))
                            for index in annotations.indices where sentIDs.contains(annotations[index].id) {
                                annotations[index].pending = false
                            }
                            if let responseStartedAt {
                                let duration = Self.elapsedSeconds(since: responseStartedAt, now: Date())
                                completedResponseDuration = duration
                                UserDefaults.standard.set(duration, forKey: completedResponseDurationDefaultsKey)
                                UserDefaults.standard.removeObject(forKey: responseStartedAtDefaultsKey)
                            }
                            if let completedTurnID = history.messages.reversed().first(where: {
                                $0.role == .assistant && $0.phase == "final_answer"
                            })?.turnID ?? history.messages.last?.turnID {
                                collapsedProgressTurnIDs.insert(completedTurnID)
                            }
                            if activities.isEmpty {
                                isActivityExpanded = false
                            }
                            Task { await refreshWorkspaceChanges() }
                        }
                    case "queue_changed":
                        refreshQueuedMessages()
                    case "steered_message":
                        messages.append(ConversationMessage(id: UUID().uuidString, role: .user, text: update.message ?? "", imageDataURLs: update.imageDataURLs ?? []))
                        if let message = update.message, draft == message { draft = "" }
                    case "action_notice":
                        actionNotice = update.message
                    default:
                        break
                    }
                }, onUserInput: { request in
                    userInputRequest = request
                    userInputAnswers = [:]
                    userInputOther = [:]
                    userInputOtherSelected = []
                })
                if messages.first(where: { $0.id == assistantMessageID })?.text.isEmpty == true {
                    messages.removeAll { $0.id == assistantMessageID }
                }
                isComposerFocused = true
                if resolutionAttempt > 0 {
                    do {
                        switch try await BoardTaskManager(modelContext: modelContext).verifyPullRequestResolution(task.id) {
                        case .resolved:
                            conflictResolutionAttempt = 0
                            onConflictResolutionChecked(true)
                        case .stillConflicted where resolutionAttempt == 1:
                            conflictResolutionAttempt = 2
                            isResponding = false
                            sendMessage(overrideText: "The PR still has conflicts or your latest commit has not reached GitHub. Resolve the remaining conflicts, commit, and push. Verify the PR's merge status before finishing.")
                            return
                        case .stillConflicted:
                            conflictResolutionAttempt = 0
                            onConflictResolutionChecked(false)
                            errorMessage = "The PR still has conflicts after two turns. Review the PR and try again."
                        case .inconclusive:
                            conflictResolutionAttempt = 0
                            onConflictResolutionChecked(false)
                            errorMessage = "GitHub hasn't confirmed that the PR is conflict-free at the pushed head. Try again after its merge check finishes."
                        }
                    } catch {
                        conflictResolutionAttempt = 0
                        onConflictResolutionChecked(false)
                        errorMessage = error.localizedDescription
                    }
                }
            } catch {
                if resolutionAttempt > 0 {
                    conflictResolutionAttempt = 0
                    onConflictResolutionChecked(false)
                }
                responseStartedAt = nil
                UserDefaults.standard.removeObject(forKey: responseStartedAtDefaultsKey)
                if providerClient.wasLastTurnInterrupted(threadID: task.activeConversationID ?? "") {
                    hasPausedResponse = true
                } else {
                    messages.removeAll { $0.id == userMessageID || $0.id == assistantMessageID }
                    if usesComposerDraft {
                        draft = freeformText
                        pendingImages = imageDataURLs.compactMap { dataURL in
                            guard let image = Self.image(fromDataURL: dataURL) else { return nil }
                            return PendingImage(dataURL: dataURL, image: image)
                        }
                    }
                    errorMessage = error.localizedDescription
                }
                isComposerFocused = true
            }

            isResponding = false
            if !usesComposerDraft, !draft.isEmpty {
                do {
                    _ = try await BoardTaskManager(modelContext: modelContext).savePrompt(task.id, prompt: draft)
                } catch { errorMessage = error.localizedDescription }
            }
        }
    }

    private func mutateGoal(_ action: String, objective: String? = nil, observeRuntime: Bool = false) async -> Bool {
        do {
            activeGoal = try await conversationManager.goal(taskID: task.id, objective: objective, action: action, observeRuntime: observeRuntime)
            if action == "set", let activeGoal { reconcileGoalGeneration(with: activeGoal) }
            goalStatusUpdatedAt = .now
            if action == "clear" { isGoalExpanded = false }
            return true
        } catch {
            errorMessage = error.localizedDescription
            if action == "set" {
                draft = objective ?? ""
                isEnteringGoal = true
                activeGoal = try? await conversationManager.goal(taskID: task.id)
            }
            return false
        }
    }

    private func reconcileGoalGeneration(with goal: CodexThreadGoal) {
        let defaults = WorkspaceSettings.preferencesStore
        let savedID = defaults.string(forKey: goalGenerationDefaultsKey) ?? currentGoalGenerationID
        let savedObjective = defaults.string(forKey: goalGenerationObjectiveDefaultsKey) ?? currentGoalObjective
        let savedTimeBaseline = defaults.object(forKey: goalGenerationTimeBaselineDefaultsKey) as? Double
            ?? currentGoalTimeBaselineSeconds
        let priorGenerationCompleted = savedID.map { id in
            goalAchievementTimelineEntries.contains { $0.id == id }
        } ?? false
        if savedID == nil || savedObjective != goal.objective || (goal.status == "active" && priorGenerationCompleted) {
            let generationID = UUID().uuidString
            let hasPreviousGoalGeneration = savedID != nil || !goalAchievementTimelineEntries.isEmpty
            let timeBaseline = hasPreviousGoalGeneration ? Double(goal.timeUsedSeconds ?? 0) : 0
            currentGoalGenerationID = generationID
            currentGoalObjective = goal.objective
            currentGoalTimeBaselineSeconds = timeBaseline
            defaults.set(generationID, forKey: goalGenerationDefaultsKey)
            defaults.set(goal.objective, forKey: goalGenerationObjectiveDefaultsKey)
            defaults.set(timeBaseline, forKey: goalGenerationTimeBaselineDefaultsKey)
        } else {
            currentGoalGenerationID = savedID
            currentGoalObjective = goal.objective
            let timeBaseline = savedTimeBaseline ?? 0
            currentGoalTimeBaselineSeconds = timeBaseline
            defaults.set(timeBaseline, forKey: goalGenerationTimeBaselineDefaultsKey)
        }
    }

    private func goalElapsedTime(for goal: CodexThreadGoal, reportedSeconds: Double? = nil) -> Double {
        let seconds = reportedSeconds ?? Double(goal.timeUsedSeconds ?? 0)
        return max(0, seconds - (currentGoalTimeBaselineSeconds ?? 0))
    }

    private func persistGoalAchievementTimeline() {
        guard let data = try? JSONEncoder().encode(goalAchievementTimelineEntries) else { return }
        WorkspaceSettings.preferencesStore.set(data, forKey: goalAchievementTimelineDefaultsKey)
    }

    private func fallbackGoalCompletionAnchorID(in historyMessages: [ConversationMessage], objective: String) -> String {
        if let goalMessage = historyMessages.last(where: { $0.role == .user && $0.text == objective }),
           let turnID = goalMessage.turnID,
           let finalMessage = historyMessages.last(where: { $0.turnID == turnID }) {
            return finalMessage.id
        }
        return historyMessages.last?.id ?? GoalAchievementTimelineEntry.beforeFirstMessageID
    }

    private func refreshGoalConversation() async {
        do {
            let history = try await conversationManager.history(taskID: task.id) {
                actionNotice = approvalNotice
            }
            messages = history.messages
            activities = history.activities
            providerBoundaries = history.providerBoundaries
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static func goalDuration(_ seconds: Double) -> String {
        if seconds < 60 { return "\(Int(seconds))s" }
        let minutes = Int(seconds / 60)
        return minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
    }

    private func goalAchievementSummary(_ goal: CodexThreadGoal) -> String {
        guard goal.timeUsedSeconds != nil else { return "Goal achieved" }
        return "Goal achieved in \(Self.goalDuration(goalElapsedTime(for: goal)))"
    }

    private static func durationLabel(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m"
    }

    private static func elapsedSeconds(since start: Date, now: Date) -> Int {
        max(0, Int(now.timeIntervalSince(start).rounded(.down)))
    }

    private func refreshQueuedMessages() {
        queuedMessages = (try? conversationManager.queuedMessages(taskID: task.id)) ?? []
        answeredAsyncQuestionIDs = Set((try? conversationManager.answeredAsyncQuestionIDs(taskID: task.id)) ?? [])
    }

    private func queueDraftForAfterTurn() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        do {
            _ = try conversationManager.queueMessage(taskID: task.id, text: text)
            draft = ""
            refreshQueuedMessages()
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func removeQueuedMessage(_ message: QueuedConversationMessage) {
        do {
            try conversationManager.removeQueuedMessage(taskID: task.id, messageID: message.id)
            refreshQueuedMessages()
        } catch { errorMessage = error.localizedDescription }
    }

    private func steerQueuedMessage(_ message: QueuedConversationMessage) {
        isSubmittingLiveMessage = true
        Task { @MainActor in
            defer { isSubmittingLiveMessage = false }
            do {
                let outcome = try await conversationManager.steerQueuedMessage(taskID: task.id, messageID: message.id)
                refreshQueuedMessages()
                guard outcome.accepted else {
                    if let history = try? await conversationManager.history(taskID: task.id) {
                        messages = history.messages
                        activities = history.activities
                        answeredAsyncQuestionIDs = Set(history.answeredAsyncQuestionIDs)
                    }
                    errorMessage = nil
                    return
                }
                messages.append(ConversationMessage(id: UUID().uuidString, role: .user, text: outcome.message))
                refreshQueuedMessages()
                errorMessage = nil
            } catch {
                refreshQueuedMessages()
                errorMessage = error.localizedDescription
            }
        }
    }

    private func steerCurrentTurn() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let imageDataURLs = pendingImages.map(\.dataURL)
        guard !text.isEmpty || !imageDataURLs.isEmpty else { return }
        isSubmittingLiveMessage = true
        Task { @MainActor in
            defer { isSubmittingLiveMessage = false }
            do {
                let accepted = try await conversationManager.steer(taskID: task.id, text: text, imageDataURLs: imageDataURLs)
                guard accepted else {
                    _ = try await conversationManager.queueMissedSteer(taskID: task.id, text: text, imageDataURLs: imageDataURLs)
                    draft = ""
                    pendingImages.removeAll()
                    refreshQueuedMessages()
                    if let history = try? await conversationManager.history(taskID: task.id) {
                        messages = history.messages
                        activities = history.activities
                    }
                    errorMessage = nil
                    return
                }
                messages.append(ConversationMessage(id: UUID().uuidString, role: .user, text: text, imageDataURLs: imageDataURLs))
                draft = ""
                pendingImages.removeAll()
                errorMessage = nil
            } catch {
                refreshQueuedMessages()
                errorMessage = error.localizedDescription
            }
        }
    }

    private func retryQueuedMessage(_ message: QueuedConversationMessage) {
        Task { @MainActor in
            do {
                let retried = try await conversationManager.retryQueuedMessage(taskID: task.id, messageID: message.id, onUserInput: { request in
                    userInputRequest = request
                    userInputAnswers = [:]
                    userInputOther = [:]
                    userInputOtherSelected = []
                })
                guard retried else {
                    throw BridgeCommandError(code: "operation_failed", message: "The queued follow-up still needs your attention.")
                }
                let history = try await conversationManager.history(taskID: task.id)
                messages = history.messages
                activities = history.activities
                answeredAsyncQuestionIDs = Set(history.answeredAsyncQuestionIDs)
                refreshQueuedMessages()
                errorMessage = nil
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func addImageData(_ data: Data) throws {
        let wasOversizedInput = data.count > 10_000_000
        let bitmap = wasOversizedInput
            ? Self.thumbnailBitmap(from: data)
            : NSBitmapImageRep(data: data)
        guard let bitmap else {
            throw BridgeCommandError(code: "invalid_argument", message: "Choose up to 8 valid images that fit within 10 MB after encoding.")
        }
        try addImage(bitmap, preferJPEG: wasOversizedInput)
    }

    private static func thumbnailBitmap(from data: Data) -> NSBitmapImageRep? {
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

    private func addImage(_ bitmap: NSBitmapImageRep, preferJPEG: Bool = false) throws {
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
        persistDraftImages()
    }

    private func persistDraftImages() {
        let images = pendingImages.map(\.dataURL)
        Task { @MainActor in
            do {
                _ = try await BoardTaskManager(modelContext: modelContext).savePrompt(task.id, prompt: draft, imageDataURLs: images)
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private static func encodedImage(_ bitmap: NSBitmapImageRep, preferJPEG: Bool = false) -> (data: Data, mimeType: String)? {
        if preferJPEG,
           let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]),
           jpeg.count <= 10_000_000 {
            return (jpeg, "image/jpeg")
        }
        if !preferJPEG,
           let png = bitmap.representation(using: .png, properties: [:]), png.count <= 10_000_000 {
            return (png, "image/png")
        }

        let maximumDimension = 1600
        let scale = min(1, Double(maximumDimension) / Double(max(bitmap.pixelsWide, bitmap.pixelsHigh)))
        var width = max(1, Int((Double(bitmap.pixelsWide) * scale).rounded()))
        var height = max(1, Int((Double(bitmap.pixelsHigh) * scale).rounded()))
        while width > 0 && height > 0 {
            guard let resized = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: width,
                pixelsHigh: height,
                bitsPerSample: 8,
                samplesPerPixel: 3,
                hasAlpha: false,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ) else { return nil }
            guard let context = NSGraphicsContext(bitmapImageRep: resized) else { return nil }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.imageInterpolation = .high
            bitmap.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
            context.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()
            for quality in stride(from: 0.85, through: 0.35, by: -0.1) {
                if let jpeg = resized.representation(using: .jpeg, properties: [.compressionFactor: quality]), jpeg.count <= 10_000_000 {
                    return (jpeg, "image/jpeg")
                }
            }
            guard width > 1, height > 1 else { return nil }
            width = max(1, Int(Double(width) * 0.85))
            height = max(1, Int(Double(height) * 0.85))
        }
        return nil
    }

    private static func image(fromDataURL value: String) -> NSImage? {
        guard let comma = value.firstIndex(of: ","), let data = Data(base64Encoded: String(value[value.index(after: comma)...])) else { return nil }
        return NSImage(data: data)
    }

    private func saveAndBack() {
        draftAutosaveTask?.cancel()
        if userInputRequest != nil {
            userInputRequest = nil
            Task { @MainActor in
                await Task.yield()
                onBack()
            }
            return
        }
        if isReadOnly { onBack(); return }
        if isResponding { onBack(); return }
        let hasStartedRepository = task.repositoryWorktrees.contains { !$0.isPending }
        let hasDraft = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if isNewTask, !hasStartedRepository, task.contextFolderPaths.isEmpty,
           pendingImages.isEmpty, messages.isEmpty, activities.isEmpty,
           !hasDraft, !isLoadingHistory {
            Task { @MainActor in
                do {
                    try await BoardTaskManager(modelContext: modelContext).delete(task.id)
                    onBack()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            return
        }
        if draftNeedsAutosave, draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Task { @MainActor in
                do {
                    _ = try await BoardTaskManager(modelContext: modelContext).savePrompt(task.id, prompt: "")
                    draftNeedsAutosave = false
                    await saveDraftAndGenerateTitle(status: nil, then: onBack)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            return
        }
        Task { @MainActor in _ = await saveDraftAndGenerateTitle(status: nil, then: onBack) }
    }

    private func scheduleDraftAutosave(_ value: String) {
        draftAutosaveTask?.cancel()
        let prompt = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isReadOnly, !isDisplayingActiveResponse, !isLoadingHistory else { return }
        draftAutosaveTask = Task { @MainActor in
            // Let AppKit finish a burst of synthesized keystrokes before the
            // main-actor SwiftData write starts. This keeps long XCTest
            // `typeText` operations responsive while retaining prompt
            // autosave once typing settles.
            try? await Task.sleep(nanoseconds: 750_000_000)
            guard !Task.isCancelled, !isResponding, !isLoadingHistory else { return }
            do {
                _ = try await BoardTaskManager(modelContext: modelContext).savePrompt(task.id, prompt: prompt)
                if draft == value { draftNeedsAutosave = false }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    @discardableResult
    private func saveDraftAndGenerateTitle(
        status: TaskStatus?,
        prompt submittedPrompt: String? = nil,
        generateTitle: Bool = true,
        reserveTitleForSend: Bool = false,
        then completion: (() -> Void)? = nil
    ) async -> Bool {
        let prompt = (submittedPrompt ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            if task.title == "Generating title…", task.pendingSubmittedPrompt == nil {
                _ = try? await BoardTaskManager(modelContext: modelContext).renameIfTitleMatches(
                    task.id,
                    expectedTitle: "Generating title…",
                    title: "Untitled task"
                )
            }
            completion?()
            return true
        }
        let taskManager = BoardTaskManager(modelContext: modelContext)
        var shouldGenerateTitle = false
        do {
            let savedTask = try await taskManager.savePrompt(
                task.id,
                prompt: prompt,
                status: status,
                submitted: reserveTitleForSend
            )
            if generateTitle, ["Generating title…", "Untitled task"].contains(savedTask.title) {
                shouldGenerateTitle = try await taskManager.renameIfTitleMatches(
                    task.id,
                    expectedTitle: savedTask.title,
                    title: "Generating title…"
                ) != nil
            }
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
        completion?()
        guard shouldGenerateTitle else { return true }
        isGeneratingTitle = true
        Task { @MainActor in
            let generated = await generateTaskTitle(from: prompt)
            let title = generated?.title
            let titleSource = generated?.provider.rawValue ?? "prompt-fallback"
            let fallback = prompt.split(whereSeparator: \.isWhitespace).prefix(8).joined(separator: " ")
            let taskManager = BoardTaskManager(modelContext: modelContext)
            let resolvedTitle = title.flatMap { $0.isEmpty ? nil : $0 } ?? fallback
            do {
                guard try await taskManager.renameIfTitleMatches(
                    task.id,
                    expectedTitle: "Generating title…",
                    title: resolvedTitle
                ) != nil else {
                    let currentTitle = (try? taskManager.taskModel(task.id).title) ?? ""
                    StationAIDiagnostics.record("task.title_apply.skipped", fields: [
                        "taskID": task.id.uuidString,
                        "reason": "title_changed",
                        "currentTitleState": StationAITaskTitleDiagnostics.state(of: currentTitle),
                        "titleSource": titleSource
                    ])
                    isGeneratingTitle = false
                    return
                }
                StationAIDiagnostics.record("task.title_apply.succeeded", fields: [
                    "taskID": task.id.uuidString,
                    "titleSource": titleSource,
                    "fallbackWordCount": title == nil ? String(fallback.split(whereSeparator: \.isWhitespace).count) : "0"
                ])
            } catch {
                var fields = StationAIDiagnostics.errorFields(error)
                fields["taskID"] = task.id.uuidString
                fields["titleSource"] = titleSource
                StationAIDiagnostics.record("task.title_apply.failed", fields: fields)
            }
            isGeneratingTitle = false
        }
        return true
    }

    private func generateTaskTitle(from prompt: String) async -> (title: String, provider: ConversationProvider)? {
        guard let workspace = try? ConversationWorkspaceContext(roots: workspaceRootURLs) else {
            StationAIDiagnostics.record("task.title_generation.failed", fields: [
                "taskID": task.id.uuidString,
                "phase": "workspace-resolution",
                "reason": "workspace_unavailable"
            ])
            return nil
        }
        return await ConversationTitleGenerator(clients: conversationClients.helperClients(preferring: provider))
            .generateTitle(from: prompt, workspace: workspace, taskID: task.id)
    }

    private var providerMenu: some View {
        Menu {
            ForEach(ConversationProvider.allCases) { option in
                Button {
                    switchProvider(to: option)
                } label: {
                    if option == provider {
                        Label(option.displayName, systemImage: "checkmark")
                    } else {
                        Text(option.displayName)
                    }
                }
                .buttonHoverPointer()
                .help("Run this task's next turns with \(option.displayName)")
                .accessibilityIdentifier("conversation-provider-\(option.rawValue)")
            }
        } label: {
            Text(provider.displayName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .buttonHoverPointer()
        .disabled(!canSwitchProvider)
        .help(providerMenuHelp)
        .accessibilityLabel("Provider: \(provider.displayName)")
        .accessibilityValue(provider.rawValue)
        .accessibilityIdentifier("conversation-provider-menu")
    }

    private var providerMenuHelp: String {
        canSwitchProvider
            ? "Choose which assistant runs this task"
            : "Wait for the current turn, questions, and queued follow-ups to finish before switching"
    }

    private func switchProvider(to newProvider: ConversationProvider) {
        guard newProvider != provider, canSwitchProvider else { return }
        isSwitchingProvider = true
        Task { @MainActor in
            defer { isSwitchingProvider = false }
            do {
                _ = try await conversationManager.setProvider(taskID: task.id, provider: newProvider)
                isEnteringGoal = false
                errorMessage = nil
                providerNotice = nil
                modelOptions = []
                await loadConversation()
                await loadModels()
                await loadProviderNotice()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Summarizes how the selected provider's native configuration differs, so a
    /// switch doesn't silently change which skills or MCP servers are available.
    private func loadProviderNotice() async {
        guard let capabilities = try? await conversationManager.providerCapabilities(taskID: task.id),
              let current = capabilities.first(where: { $0.provider == provider }) else { return }
        if let error = current.error, !current.isAvailable {
            providerNotice = error
            return
        }
        var parts: [String] = []
        switch provider {
        case .claude:
            parts.append("Claude uses its own settings: \(current.skills.count) skills and commands, \(current.mcpServers.count) MCP servers.")
        case .codex:
            parts.append("Codex runs without MCP servers, apps, or hooks.")
        }
        parts.append(provider.supportsGoals ? "Goals are available." : "Goals are available only with Codex.")
        parts.append("Earlier turns are shared as text context on the next message.")
        providerNotice = parts.joined(separator: " ")
    }

    private func pauseResponse() {
        guard isResponding, !isPausingResponse else { return }
        isPausingResponse = true
        Task { @MainActor in
            do {
                let interrupted = try await conversationManager.interrupt(taskID: task.id)
                guard interrupted else {
                    isPausingResponse = false
                    return
                }
            } catch {
                isPausingResponse = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func continueResponse() {
        guard hasPausedResponse else { return }
        sendMessage(overrideText: "Continue with the same request from where you left off.")
    }

    private func activatePlanMode() {
        isEnteringGoal = false
        setConversationMode(.plan)
        draft = ""
    }

    private var conversationModeDefaultsKey: String {
        "conversationMode.\(task.id.uuidString)"
    }

    private func setConversationMode(_ mode: ConversationMode) {
        conversationMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: conversationModeDefaultsKey)
    }

    private func startImplementingPlan() {
        isEnteringGoal = false
        setConversationMode(.code)
        sendMessage(overrideText: "Start implementing the plan.")
    }

    private var workspaceRootURLs: [URL] {
        task.workspaceRootPaths.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
    }

    private var conversationManager: ConversationManager {
        ConversationManager(
            tasks: BoardTaskManager(modelContext: modelContext),
            clients: conversationClients
        )
    }

    private var workspaceManager: WorkspaceManager {
        WorkspaceManager(taskManager: BoardTaskManager(modelContext: modelContext))
    }

    private func updateWorkspaceRoots(_ roots: [URL]) {
        Task { @MainActor in
            do {
                _ = try await WorkspaceManager(taskManager: BoardTaskManager(modelContext: modelContext))
                    .setRoots(roots.map { $0.standardizedFileURL.path }, for: task.id)
                await refreshWorkspaceChanges()
            } catch {
                errorMessage = "Couldn't save working folders: \(error.localizedDescription)"
            }
        }
    }

    private func saveConversationRepository(_ original: RepositoryWorktreeRecord) {
        let branch = editedBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        let branchFrom = editedBranchFrom.trimmingCharacters(in: .whitespacesAndNewlines)
        let mergeTarget = editedMergeTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty, !branchFrom.isEmpty else {
            errorMessage = "Branch and merge-from values can't be empty."
            return
        }
        Task { @MainActor in
            do {
                _ = try await BoardTaskManager(modelContext: modelContext).updateRepository(
                    task.id,
                    repositoryPath: original.repositoryPath,
                    branch: branch,
                    branchFrom: branchFrom,
                    mergeTarget: mergeTarget.isEmpty ? nil : mergeTarget
                )
                repositoryBeingEdited = nil
                errorMessage = nil
            } catch {
                errorMessage = "Couldn't save repository settings: \(error.localizedDescription)"
            }
        }
    }

    @ViewBuilder
    private func repositoryDetailRow(
        _ title: String,
        value: Binding<String>,
        field: String,
        placeholder: String,
        identifier: String,
        editable: Bool
    ) -> some View {
        HStack(spacing: 8) {
            Text(title).foregroundStyle(.secondary).frame(width: 82, alignment: .leading)
            if editable, editingRepositoryField == field {
                TextField(placeholder, text: value).textFieldStyle(.roundedBorder).accessibilityIdentifier(identifier)
            } else {
                let displayValue = value.wrappedValue.isEmpty ? placeholder : value.wrappedValue
                Text(displayValue)
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(displayValue)
                    .accessibilityIdentifier("\(identifier)-value")
                if editable {
                    Button {
                        editingRepositoryField = field
                    } label: {
                        Image(systemName: "pencil").font(.system(size: 10, weight: .medium))
                    }
                    .buttonHoverPointer()
                    .buttonStyle(.plain).help("Edit \(title)").accessibilityLabel("Edit \(title)")
                    .accessibilityIdentifier("\(identifier)-edit")
                }
            }
        }
    }

    private func removeConversationRepository(_ repository: RepositoryWorktreeRecord) {
        Task { @MainActor in
            do {
                _ = try await BoardTaskManager(modelContext: modelContext).removeRepository(
                    task.id,
                    repositoryPath: repository.repositoryPath,
                    duringActiveConversation: true
                )
                repositoryBeingEdited = nil
                errorMessage = nil
                await refreshWorkspaceChanges()
            } catch {
                errorMessage = "Couldn't remove repository: \(error.localizedDescription)"
            }
        }
    }

    private func scrollToLatest(using proxy: ScrollViewProxy, viewportHeight: CGFloat) {
        guard !messages.isEmpty || !activities.isEmpty || activeGoal?.status == "complete" else { return }
        // A load in progress owns the scroll position: following the bottom now
        // would scroll past the question the transcript is about to pin.
        if isLatestConversationTurnPinPending {
            presentLatestConversationTurn(using: proxy)
            return
        }
        // While the newest turn still fits the viewport, keep its question
        // pinned to the top instead of following the bottom into the filler
        // that makes that pin reachable.
        if let turnStartID = latestConversationTurnStartID,
           oldestRenderedMessageID == turnStartID,
           conversationContentHeight > 0,
           conversationContentHeight <= viewportHeight {
            presentLatestConversationTurn(using: proxy)
            return
        }
        // Scroll to the real latest row. A synthetic target after LazyVStack can
        // be positioned using its estimated content height before the lazy rows
        // have settled, leaving the viewport in the blank space below the chat.
        let latestMessageID = renderedConversationMessages.last?.id
        // Defer until the state-driven content update has had a layout pass.
        let shouldAnimate = hasPresentedLatestConversation
        Task { @MainActor in
            await Task.yield()
            // Record the question this presentation lands on, so a newly sent
            // one is told apart from the one already in view.
            lastScrolledUserMessageID = renderedConversationMessages.last(where: { $0.role == .user })?.id
            let scroll = {
                if let latestMessageID {
                    proxy.scrollTo(latestMessageID, anchor: .bottom)
                } else {
                    proxy.scrollTo("conversation-latest-anchor", anchor: .bottom)
                }
            }
            if shouldAnimate {
                withAnimation(.easeOut(duration: 0.2), scroll)
            } else {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction, scroll)
            }
            // A LazyVStack places rows it has not realized yet from estimated
            // heights, so the first scroll can stop short of the real last row.
            // Scrolling again after it has been realized lands on it.
            var settleTransaction = Transaction()
            settleTransaction.disablesAnimations = true
            for delay in Self.scrollSettleDelays {
                try? await Task.sleep(nanoseconds: delay)
                withTransaction(settleTransaction, scroll)
            }
            hasPresentedLatestConversation = true
        }
    }

    /// After the conversation is already settled, a newly sent question should land at the
    /// top of the viewport and stay there while its answer streams in below — mirroring how
    /// ChatGPT/Claude.ai keep your question in view instead of auto-scrolling to chase the
    /// growing answer all the way to the bottom.
    private func scrollToLatestUserMessage(using proxy: ScrollViewProxy, viewportHeight: CGFloat) {
        guard hasPresentedLatestConversation else {
            scrollToLatest(using: proxy, viewportHeight: viewportHeight)
            return
        }
        guard let latestUserMessage = renderedConversationMessages.last(where: { $0.role == .user }),
              latestUserMessage.id != lastScrolledUserMessageID else { return }
        lastScrolledUserMessageID = latestUserMessage.id
        Task { @MainActor in
            await Task.yield()
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(latestUserMessage.id, anchor: .top)
            }
        }
    }
}

/// Reports the transcript's scroll offset where the platform supports it. The
/// preference-based marker stays as the fallback for macOS 14.
private struct ConversationScrollOffsetObserver: ViewModifier {
    let onOffsetChange: (CGFloat) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y
            } action: { _, offsetY in
                onOffsetChange(offsetY)
            }
        } else {
            content
        }
    }
}

private struct ConversationTopMarkerPositionKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ConversationScrollContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// The native text view owns wrapping and document sizing. SwiftUI only receives
// a bounded viewport height; it never asks a multiline TextField for its ideal size.
private struct NativeChatEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    @Binding var isFocused: Bool
    let isEnabled: Bool
    let autofocusOnAppear: Bool
    let accessibilityHelp: String
    let onSubmit: () -> Void
    let onSteerSubmit: () -> Void
    let onPasteImage: (Data) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> ChatEditorScrollView {
        let scroll = ChatEditorScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        let editor = ChatEditorTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 28))
        editor.isRichText = false
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: 14)
        editor.textColor = .textColor
        editor.textContainerInset = NSSize(width: 0, height: 4)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.minSize = NSSize(width: 0, height: 28)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.heightTracksTextView = false
        editor.textContainer?.containerSize = NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude)
        editor.setAccessibilityIdentifier("message-composer")
        editor.setAccessibilityLabel("Message")
        editor.delegate = context.coordinator
        scroll.documentView = editor
        scroll.onHeightChange = { [weak coordinator = context.coordinator] height in
            // AppKit layout must finish before updating SwiftUI state.
            DispatchQueue.main.async { [weak scroll] in
                guard let scroll, scroll.viewportHeight == height else { return }
                if coordinator?.parent.height != height { coordinator?.parent.height = height }
            }
        }
        return scroll
    }

    func updateNSView(_ scroll: ChatEditorScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? ChatEditorTextView else { return }
        editor.onSubmit = onSubmit
        editor.onSteerSubmit = onSteerSubmit
        editor.onPasteImage = onPasteImage
        editor.isEditable = isEnabled
        editor.isSelectable = isEnabled
        editor.setAccessibilityHelp(accessibilityHelp)
        scroll.shouldFocusEditor = isFocused && isEnabled
        scroll.shouldAutofocusEditor = autofocusOnAppear && isEnabled
        let editorOwnsEditing = isFocused && editor.window?.firstResponder === editor
        if editor.string != text, !editorOwnsEditing {
            editor.string = text
            editor.undoManager?.removeAllActions()
            scroll.requestTextLayout()
        }
        if isFocused, isEnabled, editor.window?.firstResponder !== editor {
            if let window = editor.window {
                window.makeFirstResponder(editor)
            } else {
                DispatchQueue.main.async { [weak editor, weak coordinator = context.coordinator] in
                    guard let editor,
                          let coordinator,
                          coordinator.parent.isFocused,
                          coordinator.parent.isEnabled else { return }
                    editor.window?.makeFirstResponder(editor)
                }
            }
        }
        scroll.focusEditorIfNeeded()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeChatEditor
        init(_ parent: NativeChatEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? ChatEditorTextView else { return }
            parent.text = editor.string
            (editor.enclosingScrollView as? ChatEditorScrollView)?.requestTextLayout()
        }

        func textDidBeginEditing(_ notification: Notification) { parent.isFocused = true }
        func textDidEndEditing(_ notification: Notification) { parent.isFocused = false }
    }
}

private final class ChatEditorScrollView: NSScrollView {
    var onHeightChange: ((CGFloat) -> Void)?
    var shouldFocusEditor = false
    var shouldAutofocusEditor = false
    private var didAutofocusEditor = false
    private(set) var viewportHeight: CGFloat = 28
    private var previousWidth: CGFloat = 0
    private var textLayoutNeeded = true
    private var layoutRequestGeneration = 0

    func requestTextLayout() {
        textLayoutNeeded = true
        layoutRequestGeneration += 1
        let generation = layoutRequestGeneration
        // Let NSTextView finish its edit/layout pass, then update the viewport
        // before another typing burst can reach the next wrapped line.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.layoutRequestGeneration == generation else { return }
            self.needsLayout = true
            self.layoutSubtreeIfNeeded()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            self?.focusEditorIfNeeded()
        }
    }

    func focusEditorIfNeeded() {
        guard let window,
              let editor = documentView as? NSTextView,
              shouldFocusEditor || (shouldAutofocusEditor && !didAutofocusEditor) else { return }
        if window.makeFirstResponder(editor), shouldAutofocusEditor {
            didAutofocusEditor = true
        }
    }

    override func layout() {
        super.layout()
        guard let editor = documentView as? NSTextView else { return }
        let width = contentSize.width
        guard width > 0, textLayoutNeeded || width != previousWidth else { return }
        textLayoutNeeded = false
        previousWidth = width
        editor.setFrameSize(NSSize(width: width, height: editor.frame.height))
        let font = editor.font ?? NSFont.systemFont(ofSize: 14)
        let inset = editor.textContainerInset
        let laidOutTextHeight: CGFloat
        if let layoutManager = editor.layoutManager, let textContainer = editor.textContainer {
            // Measure with the same TextKit container that wraps the live editor.
            // A separate boundingRect calculation ignores line-fragment padding,
            // so it can report one fewer line exactly as text crosses a wrap.
            layoutManager.ensureLayout(for: textContainer)
            let usedRect = layoutManager.usedRect(for: textContainer)
            laidOutTextHeight = max(usedRect.maxY, layoutManager.extraLineFragmentRect.maxY)
        } else {
            laidOutTextHeight = 0
        }
        let lineHeight = editor.layoutManager?.defaultLineHeight(for: font) ?? font.pointSize * 1.2
        let contentHeight = ceil(max(lineHeight, laidOutTextHeight) + inset.height * 2)
        let documentHeight = max(28, contentHeight)
        editor.setFrameSize(NSSize(width: width, height: documentHeight))
        documentHeightDidChange(documentHeight)
    }

    func documentHeightDidChange(_ documentHeight: CGFloat) {
        let editor = documentView as? NSTextView
        let font = editor?.font ?? NSFont.systemFont(ofSize: 14)
        let lineHeight = editor?.layoutManager?.defaultLineHeight(for: font) ?? 17
        let verticalInset = editor?.textContainerInset.height ?? 4
        let maximumHeight = ceil(lineHeight * 12 + verticalInset * 2)
        let newHeight = min(maximumHeight, max(28, ceil(documentHeight)))
        if viewportHeight != newHeight {
            viewportHeight = newHeight
            onHeightChange?(newHeight)
        }
    }
}

private final class ChatEditorTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onSteerSubmit: (() -> Void)?
    var onPasteImage: ((Data) -> Void)?

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)),
           NSPasteboard.general.canReadObject(forClasses: [NSImage.self], options: nil) {
            return isEditable
        }
        return super.validateUserInterfaceItem(item)
    }

    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 36 || event.keyCode == 76), !hasMarkedText(), isEditable {
            if event.modifierFlags.contains(.shift) {
                insertNewlineIgnoringFieldEditor(nil)
            } else if event.modifierFlags.contains(.command) {
                onSteerSubmit?()
            } else {
                onSubmit?()
            }
            return
        }
        super.keyDown(with: event)
    }

    override func paste(_ sender: Any?) {
        guard isEditable else { return }
        let pasteboard = NSPasteboard.general
        // Prefer the original image bytes. AppKit's NSImage object reader can
        // reject large clipboard representations before the composer gets a
        // chance to resize them for the 10 MB payload limit.
        if let data = pasteboard.data(forType: .png)
                    ?? pasteboard.data(forType: .tiff) {
            onPasteImage?(data)
        } else if let image = pasteboard.readObjects(forClasses: [NSImage.self])?.first as? NSImage {
            if let data = image.tiffRepresentation {
                onPasteImage?(data)
            } else {
                super.paste(sender)
            }
        } else {
            super.paste(sender)
        }
    }
}

private struct SelectableAnnotationText: NSViewRepresentable {
    let text: String
    let annotations: [ConversationAnnotation]
    var responseAnnotations: [ResponseAnnotationReference] = []
    var responseCommentSourcePrefix = ""
    var isAssistantText = false
    var textColor: NSColor = .labelColor
    let onSelection: (NSRange, String, CGRect) -> Void
    var formattedText: NSAttributedString? = nil
    var font = NSFont.systemFont(ofSize: 16)

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onSelection: onSelection,
            responseCommentSourcePrefix: responseCommentSourcePrefix
        )
    }

    func makeNSView(context: Context) -> NSTextView {
        let view = CommentTrackingTextView()
        view.isEditable = false
        view.isSelectable = true
        if isAssistantText {
            view.setAccessibilityRole(.staticText)
        }
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 0, height: 5)
        view.textContainer?.lineFragmentPadding = 0
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.delegate = context.coordinator
        context.coordinator.anchorView = view
        view.hoverTrackingOwner = context.coordinator
        view.updateTrackingAreas()
        update(view, coordinator: context.coordinator)
        context.coordinator.renderedKey = renderKey
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        context.coordinator.onSelection = onSelection
        context.coordinator.responseCommentSourcePrefix = responseCommentSourcePrefix
        context.coordinator.anchorView = view
        guard context.coordinator.renderedKey != renderKey else {
            return
        }
        update(view, coordinator: context.coordinator)
        context.coordinator.renderedKey = renderKey
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        let width = max(40, proposal.width ?? 500)
        guard let renderedText = nsView.textStorage else { return nil }
        let contentHeight = measuredTextHeight(for: renderedText, width: width)
        return CGSize(width: width, height: ceil(contentHeight) + 2 * nsView.textContainerInset.height + 2)
    }

    private var renderKey: String {
        responseCommentSourcePrefix + "|" + text + annotations.map { "\($0.startOffset):\($0.endOffset)" }.joined(separator: ",")
            + responseAnnotations.map { "\($0.text):\($0.comment)" }.joined(separator: "|")
    }

    private func update(_ view: NSTextView, coordinator: Coordinator) {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 4
        let value: NSMutableAttributedString
        if let formattedText {
            value = NSMutableAttributedString(attributedString: formattedText)
            for (key, fallback) in [(NSAttributedString.Key.font, font as Any),
                                    (.foregroundColor, textColor as Any),
                                    (.paragraphStyle, style as Any)] {
                var missingRanges: [NSRange] = []
                value.enumerateAttribute(key, in: NSRange(location: 0, length: value.length)) { attribute, range, _ in
                    if attribute == nil { missingRanges.append(range) }
                }
                for range in missingRanges where range.length > 0 {
                    value.addAttribute(key, value: fallback, range: range)
                }
            }
        } else {
            value = NSMutableAttributedString(string: text, attributes: [
                .font: font,
                .foregroundColor: textColor,
                .paragraphStyle: style
            ])
        }
        for annotation in annotations {
            let range = NSRange(location: annotation.startOffset, length: annotation.endOffset - annotation.startOffset)
            guard range.location >= 0, NSMaxRange(range) <= value.length else { continue }
            value.addAttribute(.foregroundColor, value: NSColor.systemOrange, range: range)
        }
        Self.replaceResponseAnnotationMarkers(in: value, references: responseAnnotations)
        view.font = font
        view.textColor = textColor
        view.backgroundColor = .clear
        view.textStorage?.setAttributedString(value)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.responseCommentContentDidChange()
    }

    private static let responseCommentTextKey = NSAttributedString.Key("StationAIResponseCommentText")
    private static let responseCommentBodyKey = NSAttributedString.Key("StationAIResponseCommentBody")

    private static func replaceResponseAnnotationMarkers(in value: NSMutableAttributedString, references: [ResponseAnnotationReference]) {
        let pattern = #":(?:stationai-annotation|codex-annotation)\{index=\"(\d+)\"\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let originalText = value.string as NSString
        for match in regex.matches(in: value.string, range: NSRange(location: 0, length: originalText.length)).reversed() {
            guard match.numberOfRanges > 1,
                  let index = Int(originalText.substring(with: match.range(at: 1))) else { continue }
            let label = match.range.location == 0 ? "\(index + 1)." : "Comment \(index + 1)"
            let isResolved = references.indices.contains(index)
            let replacement = NSMutableAttributedString(string: label, attributes: [
                .font: NSFont.systemFont(ofSize: 16),
                .foregroundColor: isResolved ? NSColor.controlAccentColor
                    : (value.attribute(.foregroundColor, at: match.range.location, effectiveRange: nil) as? NSColor ?? .labelColor),
            ])
            if isResolved {
                let reference = references[index]
                replacement.addAttribute(.underlineStyle,
                                         value: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue,
                                         range: NSRange(location: 0, length: replacement.length))
                replacement.addAttribute(responseCommentTextKey, value: reference.text, range: NSRange(location: 0, length: replacement.length))
                replacement.addAttribute(responseCommentBodyKey, value: reference.comment, range: NSRange(location: 0, length: replacement.length))
            }
            value.replaceCharacters(in: match.range, with: replacement)
        }
    }

    final class Coordinator: NSResponder, NSTextViewDelegate, NSPopoverDelegate {
        var onSelection: (NSRange, String, CGRect) -> Void
        var responseCommentSourcePrefix: String
        weak var anchorView: NSTextView?
        var renderedKey = ""
        private var responseCommentPopover: NSPopover?
        private var activeResponseCommentID: String?
        private var pendingResponseCommentSourceID: String?
        private var pendingResponseCommentWorkItem: DispatchWorkItem?

        init(
            onSelection: @escaping (NSRange, String, CGRect) -> Void,
            responseCommentSourcePrefix: String
        ) {
            self.onSelection = onSelection
            self.responseCommentSourcePrefix = responseCommentSourcePrefix
            super.init()
        }

        required init?(coder: NSCoder) {
            return nil
        }

        override func mouseEntered(with event: NSEvent) {
            updateHover(for: event)
        }

        override func mouseMoved(with event: NSEvent) {
            updateHover(for: event)
        }

        override func mouseExited(with event: NSEvent) {
            guard let anchorView else { return }
            updateResponseCommentHover(at: nil, in: anchorView)
        }

        private func updateHover(for event: NSEvent) {
            guard let anchorView else { return }
            updateResponseCommentHover(at: anchorView.convert(event.locationInWindow, from: nil), in: anchorView)
        }

        func updateResponseCommentHover(at point: CGPoint?, in view: NSTextView) {
            let hit = point.flatMap { responseComment(at: $0, in: view) }
            guard let hit else {
                cancelPendingResponseCommentHover()
                closeResponseCommentPopover()
                return
            }
            let sourceID = hit.sourceID
            if sourceID == pendingResponseCommentSourceID ||
                (sourceID == activeResponseCommentID && responseCommentPopover?.isShown == true) {
                return
            }
            cancelPendingResponseCommentHover()
            closeResponseCommentPopover()
            pendingResponseCommentSourceID = sourceID
            let workItem = DispatchWorkItem { [weak self, weak view] in
                guard let self, let view,
                      self.pendingResponseCommentSourceID == sourceID,
                      let window = view.window else { return }
                self.pendingResponseCommentWorkItem = nil
                self.pendingResponseCommentSourceID = nil
                let currentPoint = view.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
                let currentHit = self.responseComment(at: currentPoint, in: view)
                guard let currentHit,
                      currentHit.sourceID == sourceID else { return }
                self.showResponseCommentPopover(
                    sourceID: sourceID,
                    selectedText: currentHit.selectedText,
                    comment: currentHit.comment,
                    bounds: currentHit.anchor,
                    anchorView: view
                )
            }
            pendingResponseCommentWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(200), execute: workItem)
        }

        private func responseComment(at point: CGPoint, in view: NSTextView) -> (sourceID: String, selectedText: String, comment: String, anchor: CGRect)? {
            guard let storage = view.textStorage,
                  let layoutManager = view.layoutManager,
                  let textContainer = view.textContainer,
                  let window = view.window else { return nil }
            var hit: (sourceID: String, selectedText: String, comment: String, anchor: CGRect)?
            storage.enumerateAttribute(
                SelectableAnnotationText.responseCommentTextKey,
                in: NSRange(location: 0, length: storage.length)
            ) { selectedTextValue, range, stop in
                guard let selectedText = selectedTextValue as? String, range.length > 0,
                      let comment = storage.attribute(SelectableAnnotationText.responseCommentBodyKey,
                                                      at: range.location, effectiveRange: nil) as? String else { return }
                let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                var fragments: [CGRect] = []
                layoutManager.enumerateEnclosingRects(
                    forGlyphRange: glyphRange,
                    withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                    in: textContainer
                ) { rect, _ in
                    let origin = view.textContainerOrigin
                    fragments.append(CGRect(
                        x: origin.x + rect.minX,
                        y: view.isFlipped ? origin.y + rect.minY : view.bounds.height - origin.y - rect.maxY,
                        width: rect.width,
                        height: rect.height
                    ))
                }
                guard let firstFragment = fragments.first else { return }
                let firstScreenRect = view.firstRect(forCharacterRange: range, actualRange: nil)
                guard !firstScreenRect.isNull, !firstScreenRect.isEmpty else { return }
                let firstViewRect = view.convert(window.convertFromScreen(firstScreenRect), from: nil)
                let offset = CGPoint(x: firstViewRect.minX - firstFragment.minX,
                                     y: firstViewRect.minY - firstFragment.minY)
                for (index, fragment) in fragments.enumerated() {
                    let glyphBounds = index == 0 ? firstViewRect
                        : fragment.offsetBy(dx: offset.x, dy: offset.y)
                    let bounds = glyphBounds.insetBy(dx: -4, dy: -5)
                    guard bounds.contains(point) else { continue }
                    hit = (
                        sourceID: "\(self.responseCommentSourcePrefix):\(range.location)",
                        selectedText: selectedText,
                        comment: comment,
                        anchor: CGRect(x: bounds.minX, y: bounds.midY, width: bounds.width, height: 1)
                    )
                    stop.pointee = true
                    break
                }
            }
            return hit
        }


        private func showResponseCommentPopover(
            sourceID: String,
            selectedText: String,
            comment: String,
            bounds: CGRect,
            anchorView: NSView
        ) {
            guard activeResponseCommentID != sourceID || responseCommentPopover?.isShown != true else { return }
            closeResponseCommentPopover()
            activeResponseCommentID = sourceID

            let popover = NSPopover()
            popover.behavior = .applicationDefined
            popover.animates = false
            popover.delegate = self
            let hostingController = NSHostingController(rootView: ResponseCommentHoverCard(
                selectedText: selectedText,
                comment: comment
            ))
            hostingController.view.frame = CGRect(x: 0, y: 0, width: 320, height: 120)
            popover.contentViewController = hostingController
            popover.contentSize = NSSize(width: 320, height: 120)
            responseCommentPopover = popover
            popover.show(relativeTo: bounds, of: anchorView, preferredEdge: .minY)
        }

        private func closeResponseCommentPopover() {
            responseCommentPopover?.close()
            responseCommentPopover = nil
            activeResponseCommentID = nil
        }

        private func cancelPendingResponseCommentHover() {
            pendingResponseCommentWorkItem?.cancel()
            pendingResponseCommentWorkItem = nil
            pendingResponseCommentSourceID = nil
        }

        func responseCommentContentDidChange() {
            cancelPendingResponseCommentHover()
            closeResponseCommentPopover()
        }

        func popoverDidClose(_ notification: Notification) {
            guard let popover = notification.object as? NSPopover,
                  popover === responseCommentPopover else { return }
            responseCommentPopover = nil
            activeResponseCommentID = nil
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            let range = view.selectedRange()
            guard range.length > 0, NSMaxRange(range) <= (view.string as NSString).length else {
                onSelection(range, "", .zero)
                return
            }
            let text = (view.string as NSString).substring(with: range)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            let glyphs = view.layoutManager?.glyphRange(forCharacterRange: range, actualCharacterRange: nil) ?? NSRange(location: 0, length: 0)
            var bounds = view.layoutManager?.boundingRect(forGlyphRange: glyphs, in: view.textContainer!) ?? .zero
            bounds.origin.x += view.textContainerOrigin.x
            bounds.origin.y += view.textContainerOrigin.y
            onSelection(range, text, bounds)
        }
    }
}

/// A discrete effort slider whose knob is an opaque white disc, so it stays solid over any track or popover background.
private struct EffortStepSlider: View {
    @Binding var selection: ConversationEffort
    let choices: [ConversationEffort]

    private let knobDiameter: CGFloat = 20
    private let trackHeight: CGFloat = 6

    private var selectedIndex: Int { choices.firstIndex(of: selection) ?? 0 }
    private var stepCount: Int { max(choices.count - 1, 1) }

    var body: some View {
        GeometryReader { proxy in
            let travel = max(proxy.size.width - knobDiameter, 1)
            let knobX = travel * CGFloat(selectedIndex) / CGFloat(stepCount)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.2))
                    .frame(height: trackHeight)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: knobX + knobDiameter / 2, height: trackHeight)
                ForEach(choices.indices, id: \.self) { index in
                    Circle()
                        .fill(Color.primary.opacity(0.35))
                        .frame(width: 4, height: 4)
                        .offset(x: travel * CGFloat(index) / CGFloat(stepCount) + knobDiameter / 2 - 2)
                }
                Circle()
                    .fill(Color.white)
                    .frame(width: knobDiameter, height: knobDiameter)
                    .offset(x: knobX)
            }
            .frame(width: proxy.size.width, height: knobDiameter, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard !choices.isEmpty else { return }
                let fraction = (value.location.x - knobDiameter / 2) / travel
                let index = min(Int((min(max(fraction, 0), 1) * CGFloat(stepCount)).rounded()), choices.count - 1)
                selection = choices[index]
            })
        }
        .frame(height: knobDiameter)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { moveSelection(by: -1) }
        .onKeyPress(.rightArrow) { moveSelection(by: 1) }
    }

    private func moveSelection(by delta: Int) -> KeyPress.Result {
        guard !choices.isEmpty else { return .ignored }
        selection = choices[min(max(selectedIndex + delta, 0), choices.count - 1)]
        return .handled
    }
}
