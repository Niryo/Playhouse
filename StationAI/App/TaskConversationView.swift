import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

private struct AssistantMarkdownBlock: Identifiable {
    enum Kind {
        case heading(Int)
        case listItem
        case paragraph
    }

    let id: Int
    let kind: Kind
    let text: String
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
    @State private var isGeneratingTitle = false
    @State private var conversationMode: CodexConversationMode = .code
    @State private var isEnteringGoal = false
    @State private var activeGoal: CodexThreadGoal?
    @State private var goalAchievementTimelineEntries: [GoalAchievementTimelineEntry] = []
    @State private var currentGoalGenerationID: String?
    @State private var currentGoalObjective: String?
    @State private var currentGoalTimeBaselineSeconds: Double?
    @State private var isGoalExpanded = false
    @State private var goalStatusUpdatedAt = Date.now
    @State private var modelOptions = [CodexModelOption(id: CodexAppServerClient.modelID, name: "GPT-6 Luna", isDefault: true)]
    @State private var selectedModelID = CodexAppServerClient.modelID
    @State private var messages: [CodexChatMessage] = []
    @State private var activities: [CodexActivity] = []
    @State private var isActivityExpanded = false
    @State private var responseStartedAt: Date?
    @State private var completedResponseDuration: Int?
    @State private var collapsedProgressTurnIDs = Set<String>()
    @State private var selectedSubagent: CodexActivity?
    @State private var subagentHistory: CodexThreadHistory?
    @State private var isLoadingSubagent = false
    @State private var subagentError: String?
    @State private var changeInventory = WorkspaceChangeInventory(staged: [], working: [])
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
    @State private var isResponding = false
    @State private var isPreparingSubmittedMessage = false
    @State private var conflictResolutionAttempt = 0
    @State private var hasPausedResponse = false
    @State private var isPausingResponse = false
    @State private var queuedMessages: [QueuedConversationMessage] = []
    @State private var isSubmittingLiveMessage = false
    @State private var userInputRequest: CodexUserInputRequest?
    @State private var userInputAnswers: [String: [String]] = [:]
    @State private var userInputOther: [String: String] = [:]
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
        (draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pendingImages.isEmpty && !isEnteringGoal) || workspaceRootURLs.isEmpty || isResponding || isLoadingHistory
    }

    private var canPauseResponse: Bool {
        guard let threadID = task.codexThreadID else { return false }
        return codexClient.canInterruptActiveTurn(threadID: threadID)
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

    private var progressMessages: [CodexChatMessage] {
        messages.filter { progressMessageIDs.contains($0.id) }
    }

    private var conversationMessages: [CodexChatMessage] {
        let completedProgressIDs = progressMessageIDs
        return messages.filter { !completedProgressIDs.contains($0.id) }
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

    private var currentActivity: CodexActivity? {
        activities.enumerated()
            .filter { $0.element.isActive }
            .max { lhs, rhs in
                let lhsStart = lhs.element.startedAt ?? .distantPast
                let rhsStart = rhs.element.startedAt ?? .distantPast
                return lhsStart == rhsStart ? lhs.offset < rhs.offset : lhsStart < rhsStart
            }?.element
    }

    private var hasCompletedAssistantResponse: Bool {
        guard let latestUserIndex = messages.lastIndex(where: { $0.role == .user }) else {
            return messages.contains { $0.role == .assistant && $0.phase == "final_answer" }
        }
        return messages.dropFirst(latestUserIndex + 1).contains {
            $0.role == .assistant && $0.phase == "final_answer"
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
            guard isNewTask else { return }
            isShowingRepositoryPicker = true
            lastSelectedRepositoryPaths = WorkspaceSettingsManager().lastSelectedRepositories
            loadSuggestedRepositories()
        }
        .sheet(isPresented: $isShowingWorkspaceEditor) {
            WorkspaceRootsEditor(
                parentFolderURL: WorkspaceSettings.validDirectoryURL(for: defaultParentFolderPath),
                initialRoots: workspaceRootURLs,
                repositoryWorktrees: task.repositoryWorktrees,
                onSave: updateWorkspaceRoots
            )
        }
        .fileImporter(isPresented: $isShowingImagePicker, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            do {
                for url in try result.get() { try addImageData(Data(contentsOf: url)) }
            } catch { errorMessage = "Couldn't load image: \(error.localizedDescription)" }
        }
        .task {
            if !isReadOnly {
                _ = try? await BoardTaskManager(modelContext: modelContext)
                    .reconcileLifecycleStatusOnOpen(task.id, client: codexClient)
            }
            if !isReadOnly, let request = codexClient.pendingUserInputRequest, request.threadID == task.codexThreadID {
                userInputRequest = request
            }
            await loadConversation()
            if !isReadOnly { refreshQueuedMessages() }
            if !isReadOnly { await loadModels() }
            if conflictResolutionRequested && !isReadOnly && !isResponding {
                conflictResolutionAttempt = 1
                sendMessage(overrideText: "The PR has conflicts. Fix them, commit, and push.")
            }
        }
        .onChange(of: codexClient.isTurnActive) { _, isTurnActive in
            if !isTurnActive, !isReadOnly {
                refreshQueuedMessages()
            }
            let submittedTurnIsPending = task.pendingSubmittedPrompt != nil
                && (task.status == .inProgress || task.status == .waitingResponse)
            guard let taskThreadID = task.codexThreadID else {
                isResponding = submittedTurnIsPending
                return
            }
            isResponding = submittedTurnIsPending || (isTurnActive && codexClient.isTurnActive(threadID: taskThreadID))
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
                        changeSection(title: "Staged Changes", entries: changeInventory.staged)
                        changeSection(title: "Changes", entries: changeInventory.working)
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

    private func changeSection(title: String, entries: [WorkspaceChangeEntry]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Image(systemName: title == "Staged Changes" ? "checkmark.circle.fill" : "circle.dashed")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(title == "Staged Changes" ? .green : .secondary)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Text("\(entries.count)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .accessibilityIdentifier(title == "Staged Changes" ? "staged-changes-section" : "working-changes-section")

            if entries.isEmpty {
                Text("No files")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 31)
                    .padding(.vertical, 3)
            } else {
                let groups = repositoryGroups(entries)
                ForEach(groups, id: \.repository) { repositoryGroup in
                    if Set(changeInventory.staged.map(\.repository) + changeInventory.working.map(\.repository)).count > 1 {
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
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 0)
                                Text(statusBadge(for: entry))
                                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                                    .foregroundStyle(changeColor(for: entry.status))
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                            .background(
                                selectedChange?.id == entry.id
                                    ? Color.accentColor.opacity(0.15)
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: 5)
                            )
                        }
                        .buttonHoverPointer()
                        .buttonStyle(.plain)
                        .help("View \(entry.group.rawValue) diff for \(entry.path)")
                        .accessibilityLabel("\(entry.path), \(entry.status), \(entry.group.rawValue)")
                        .accessibilityIdentifier("workspace-change-\(entry.group.rawValue)-\(entry.path)")
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

                if !isReadOnly, let userInputRequest { userInputForm(userInputRequest) }

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
                        Text("\(repositoryLabel(selectedChange.repository)) · \(selectedChange.group == .staged ? "Staged" : "Working tree")")
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
                    if let current = (inventory.staged + inventory.working).first(where: { $0.id == selectedChange.id }) {
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
            .disabled(isPreparingSubmittedMessage)

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
                if isResponding {
                    currentActivityIndicator
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            Button {
                isShowingWorkspaceEditor = true
            } label: {
                Label("Folders", systemImage: "folder")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonHoverPointer()
            .buttonStyle(.bordered)
            .help("Edit working folders for this task")
            .accessibilityIdentifier("edit-workspace-roots-button")
            .disabled(isReadOnly)
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WorkspaceTheme.windowBackground.opacity(0.96))
    }

    private var currentActivityIndicator: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            HStack(spacing: 7) {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
                if let currentActivity {
                    Text(currentActivity.title)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .accessibilityIdentifier("current-activity-title")
                    Spacer(minLength: 4)
                    if currentActivity.startedAt != nil {
                        Text(currentActivity.durationLabel(at: timeline.date) ?? "Running · 0 ms")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .accessibilityValue(currentActivity.durationLabel(at: timeline.date) ?? "Running · 0 ms")
                            .accessibilityIdentifier("current-activity-duration")
                    }
                } else {
                    Text("Thinking")
                        .font(.system(size: 11, weight: .medium))
                        .accessibilityIdentifier("current-activity-title")
                    Spacer(minLength: 4)
                }
            }
            .foregroundStyle(Color.accentColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("current-activity-indicator")
        }
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
                    Button("Change…", action: chooseRepositoryParentFolder)
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
                Button("Choose suggestion folder…", action: chooseRepositoryParentFolder)
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

    private func selectRepositories(_ repositories: [URL]) {
        isShowingRepositoryPicker = false
        repositorySearch = ""
        Task { @MainActor in
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
                isShowingRepositoryPicker = true
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

    private func chooseRepositoryParentFolder() {
        guard !isChoosingRepositoryParent else { return }
        isShowingRepositoryPicker = false
        let panel = NSOpenPanel()
        panel.title = "Choose default parent folder"
        panel.message = "StationAI will suggest Git repositories found under this folder."
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
                    isShowingRepositoryPicker = true
                    return
                }
                let path = selected.standardizedFileURL.path
                do {
                    try WorkspaceSettingsManager().setDefaultParentFolder(path)
                    defaultParentFolderPath = path
                    loadSuggestedRepositories()
                    isShowingRepositoryPicker = true
                } catch {
                    errorMessage = "Couldn't set the repository suggestion folder: \(error.localizedDescription)"
                    isShowingRepositoryPicker = true
                }
            }
        }
    }

    private var safetyNotice: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !workspaceRootURLs.isEmpty {
                let folderLabels = workspaceRootURLs.map { url in
                    task.repositoryWorktrees.first(where: { URL(fileURLWithPath: $0.worktreePath).standardizedFileURL.path == url.path })
                        .map { "\(URL(fileURLWithPath: $0.repositoryPath).lastPathComponent) · \($0.branch)" } ?? url.lastPathComponent
                }
                let folderSummary = "Working in: " + folderLabels.joined(separator: " · ")
                let fullFolderSummary = "Working in: " + workspaceRootURLs.map(\.path).joined(separator: " · ")
                Text(folderSummary)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .accessibilityLabel(folderSummary)
                    .accessibilityValue(fullFolderSummary)
                    .accessibilityIdentifier("working-folders-summary")
            }
        }
        .frame(maxWidth: 820, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .padding(.top, 12)
    }

    private var conversation: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if messages.isEmpty && activeGoal?.status != "complete" && !isLoadingHistory {
                        VStack(spacing: 12) {
                            Image(systemName: "bubble.left.and.bubble.right")
                                .font(.system(size: 25, weight: .regular))
                                .foregroundStyle(Color.accentColor.opacity(0.8))
                            Text("Start a conversation")
                                .font(.system(size: 17, weight: .semibold))
                            Text("Send a message to Codex · Luna.")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 210)
                        .padding(30)
                        .accessibilityIdentifier("empty-conversation")
                    } else if !messages.isEmpty {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            ForEach(goalAchievementTimelineEntries.filter {
                                goalAchievementAnchorMessageID(for: $0) == nil
                            }) { entry in
                                goalAchievementTimelineRow(entry)
                                    .id(entry.id)
                            }
                            ForEach(conversationMessages) { message in
                                if shouldShowActivityDisclosure, message.id == activityDisclosureAnchorID {
                                    activityList
                                }
                                messageBubble(message)
                                    .id(message.id)
                                ForEach(goalAchievementTimelineEntries.filter {
                                    goalAchievementAnchorMessageID(for: $0) == message.id
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
                        ForEach(goalAchievementTimelineEntries.filter {
                            goalAchievementAnchorMessageID(for: $0) == nil
                        }) { entry in
                            goalAchievementTimelineRow(entry)
                                .id(entry.id)
                        }
                    }

                    if isDisplayingActiveResponse {
                        ForEach(activeSubagents) { activity in
                            subagentTimelineRow(activity)
                        }
                    }
                    ForEach(activities.filter { $0.isContextCompaction && $0.timelineOrder == nil }) { activity in
                        contextCompactionTimelineRow(activity)
                    }
                    // Keep a stable scroll target outside the LazyVStack. A newly
                    // loaded last message may not have been materialized yet when
                    // SwiftUI delivers the messages change notification.
                    Color.clear
                        .frame(height: 1)
                        .id("conversation-latest-anchor")
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.visible)
            .accessibilityIdentifier("conversation-scroll-view")
            .onChange(of: messages.count) { _, _ in
                scrollToLatest(using: scrollProxy)
            }
            .onChange(of: messages.map(\.text)) { _, _ in
                scrollToLatest(using: scrollProxy)
            }
            .onChange(of: hasCompletedAssistantResponse) { _, hasCompletedResponse in
                if hasCompletedResponse {
                    isActivityExpanded = false
                }
            }
            .onChange(of: activities) { _, _ in
                if isResponding { scrollToLatest(using: scrollProxy) }
            }
            .onChange(of: isResponding) { _, _ in
                scrollToLatest(using: scrollProxy)
            }
            .onChange(of: activeGoal?.status) { _, status in
                if status == "complete" { scrollToLatest(using: scrollProxy) }
            }
            .onChange(of: goalAchievementTimelineEntries.count) { _, _ in
                scrollToLatest(using: scrollProxy)
            }
        }
    }

    private var activeSubagents: [CodexActivity] {
        activities.filter { $0.isSubagent && ["inprogress", "running"].contains($0.status.lowercased()) }
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
                    ForEach(activities.filter { !$0.isSubagent && !$0.isContextCompaction }) { activity in
                        activityRow(activity)
                    }
                    let agentActivities = activities.filter(\.isSubagent)
                    if !isDisplayingActiveResponse && !agentActivities.isEmpty {
                        Text("Agents used")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                        ForEach(agentActivities) { activity in
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

    private func subagentTimelineRow(_ activity: CodexActivity) -> some View {
        Button {
            openSubagent(activity)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image("SubagentIcon")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 20, height: 20)
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
            .accessibilityElement(children: .contain)
        }
        .buttonHoverPointer()
        .help("Open the read-only conversation for this agent")
        .buttonStyle(.plain)
        .accessibilityLabel("\(activity.title) \(activity.timelineStatus)")
        .accessibilityValue([activity.detail, activity.durationLabel()].compactMap { $0 }.joined(separator: "\n"))
        .accessibilityIdentifier("codex-subagent-row-\(activity.childThreadID ?? activity.id)")
    }

    private func activityRow(_ activity: CodexActivity) -> some View {
        let displayDetail = [activity.detail]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Image(systemName: activity.status == "completed" ? "checkmark.circle.fill" : activity.status == "interrupted" ? "pause.circle.fill" : "gearshape.2.fill")
                    .foregroundStyle(activity.status == "completed" ? .green : activity.status == "interrupted" ? .orange : .accentColor)
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

    private func contextCompactionTimelineRow(_ activity: CodexActivity) -> some View {
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

    private func openSubagent(_ activity: CodexActivity) {
        selectedSubagent = activity
        subagentHistory = nil
        subagentError = nil
        isLoadingSubagent = true
        guard let threadID = activity.childThreadID else { return }
        Task { @MainActor in
            do {
                let roots = task.workspaceRootPaths.isEmpty && task.status == .done
                    ? task.repositoryWorktrees.map { URL(fileURLWithPath: $0.repositoryPath, isDirectory: true) }
                    : workspaceRootURLs
                let workspace = try CodexWorkspaceContext(roots: roots)
                subagentHistory = try await codexClient.inspectThreadReadOnly(id: threadID, workspace: workspace)
            } catch {
                subagentError = "Couldn't load this agent conversation: \(error.localizedDescription)"
            }
            isLoadingSubagent = false
        }
    }

    private func subagentConversation(_ activity: CodexActivity) -> some View {
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
    private func messageBubble(_ message: CodexChatMessage) -> some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .assistant {
                if Self.displayableAssistantText(message.text).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && isResponding {
                    EmptyView()
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

    private func assistantBubble(_ message: CodexChatMessage) -> some View {
        let displayText = Self.displayableAssistantText(message.text)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Codex · Luna")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            assistantMarkdownContent(displayText)
            .font(.system(size: 16, weight: .regular))
            .foregroundStyle(WorkspaceTheme.conversationText)
            .padding(.horizontal, 15)
            .padding(.vertical, 11)
            .background(
                WorkspaceTheme.panelBackground,
                in: RoundedRectangle(cornerRadius: 17, style: .continuous)
            )
            .accessibilityElement(children: .contain)
            .accessibilityLabel(displayText.isEmpty ? "Waiting for Codex response" : String(Self.markdownAttributedText(displayText).characters))
            .accessibilityIdentifier("assistant-message-\(message.id)")
        }
        .frame(maxWidth: 620, alignment: .leading)
    }

    private func userBubble(_ message: CodexChatMessage) -> some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(Array(message.imageDataURLs.enumerated()), id: \.offset) { index, dataURL in
                if let image = Self.image(fromDataURL: dataURL) {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 260, maxHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .accessibilityIdentifier("chat-image-\(message.id)-\(index)")
                }
            }
            if !message.text.isEmpty {
                Text(message.text)
                    .font(.system(size: 16, weight: .regular)).foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .padding(.horizontal, 16).padding(.vertical, 11)
                    .background(WorkspaceTheme.accent, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            }
        }
            .frame(maxWidth: 620, alignment: .trailing)
            .accessibilityIdentifier("user-message-\(message.id)")
    }

    private static func markdownAttributedText(_ markdown: String) -> AttributedString {
        (try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .full)))
            ?? AttributedString(markdown)
    }

    private static func displayableAssistantText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "<proposed_plan>", with: "")
            .replacingOccurrences(of: "</proposed_plan>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func assistantMarkdownContent(_ markdown: String) -> some View {
        let blocks = Self.markdownBlocks(markdown)
        var content = AttributedString()
        for (index, block) in blocks.enumerated() {
            if index > 0 {
                content.append(AttributedString("\n\n"))
            }
            if case .listItem = block.kind {
                content.append(AttributedString("•  "))
            }
            var text = Self.markdownAttributedText(block.text)
            switch block.kind {
            case .heading(let level):
                text.font = .system(size: level == 1 ? 19 : level == 2 ? 17 : 15, weight: .semibold)
            case .listItem, .paragraph:
                break
            }
            content.append(text)
        }
        return Text(content)
            .lineSpacing(4)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private static func markdownBlocks(_ markdown: String) -> [AssistantMarkdownBlock] {
        var blocks: [AssistantMarkdownBlock] = []
        var paragraphLines: [String] = []
        var paragraphStart: Int?

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

        for (index, rawLine) in markdown.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else {
                flushParagraph()
                continue
            }
            let headingPrefix = line.prefix(while: { $0 == "#" })
            if !headingPrefix.isEmpty, headingPrefix.count <= 6,
               line.dropFirst(headingPrefix.count).first == " " {
                flushParagraph()
                blocks.append(AssistantMarkdownBlock(
                    id: index,
                    kind: .heading(headingPrefix.count),
                    text: String(line.dropFirst(headingPrefix.count + 1))
                ))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                flushParagraph()
                blocks.append(AssistantMarkdownBlock(id: index, kind: .listItem, text: String(line.dropFirst(2))))
            } else {
                paragraphStart = paragraphStart ?? index
                paragraphLines.append(line)
            }
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
                            Image(nsImage: attachment.image).resizable().scaledToFill()
                                .frame(width: 64, height: 52).clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(alignment: .topTrailing) {
                                    Button {
                                        pendingImages.removeAll { $0.id == attachment.id }
                                        persistDraftImages()
                                    } label: {
                                        Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .black.opacity(0.7))
                                    }
                                    .buttonHoverPointer()
                                    .help("Remove image").buttonStyle(.plain).accessibilityLabel("Remove image")
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

            if workspaceRootURLs.isEmpty {
                Label("Choose at least one working folder before sending a message.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Choose at least one working folder before sending a message.")
                    .accessibilityIdentifier("no-working-folders-error")
            }

            if let errorMessage,
               errorMessage != WorkspaceError.noRoots.localizedDescription {
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
                if let activeGoal, activeGoal.status != "complete", !isReadOnly {
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
                        Button { isGoalExpanded.toggle() } label: { Image(systemName: isGoalExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.and.arrow.down.left") }
                            .buttonHoverPointer().buttonStyle(.plain).help(isGoalExpanded ? "Collapse goal" : "Expand goal")
                            .accessibilityLabel(isGoalExpanded ? "Collapse goal" : "Expand goal").accessibilityIdentifier("goal-expand-button")
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
                    isEnabled: !isReadOnly && !isLoadingHistory,
                    accessibilityHelp: isReadOnly
                        ? "Archived conversation, read-only."
                         : (isResponding ? "Press Return to queue this follow-up. Press Command-Return to steer the active turn, or use a queued row's Steer action."
                            : (isLoadingHistory ? "Composer unavailable while conversation history loads." : "")),
                    onSubmit: {
                        if isResponding, codexClient.isTurnActive(threadID: task.codexThreadID ?? "") {
                            queueDraftForAfterTurn()
                        } else if isResponding {
                            errorMessage = "The active turn is finishing; try again when follow-ups are available."
                        } else {
                            sendMessage()
                        }
                    },
                    onSteerSubmit: {
                        if isResponding, codexClient.isTurnActive(threadID: task.codexThreadID ?? "") {
                            steerCurrentTurn()
                        }
                    },
                    onPasteImage: { image in
                        do { try addImage(image) }
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
                        } else if newValue.trimmingCharacters(in: .whitespacesAndNewlines) == "/goal" {
                            isEnteringGoal = true
                            conversationMode = .code
                            draft = ""
                        }
                        if !isReadOnly, !isResponding, !isLoadingHistory {
                            draftNeedsAutosave = true
                        }
                        scheduleDraftAutosave(newValue)
                    }
                    .disabled(isReadOnly || isLoadingHistory || isPreparingSubmittedMessage)
                    .accessibilityIdentifier("message-composer")

                HStack(spacing: 12) {
                    Button { isShowingImagePicker = true } label: { Image(systemName: "paperclip") }
                    .buttonHoverPointer()
                    .help("Attach image")
                        .buttonStyle(.plain).accessibilityLabel("Attach image")
                        .accessibilityIdentifier("attach-chat-image-button")
                    Menu {
                        Button {
                            isEnteringGoal = true
                            conversationMode = .code
                            draft = ""
                        } label: {
                            Label("Goal", systemImage: "scope")
                        }
                        .buttonHoverPointer()
                        .help("Set a goal to keep pursuing")
                        .accessibilityIdentifier("conversation-mode-goal")
                        ForEach(CodexConversationMode.allCases, id: \.self) { mode in
                            Button {
                                isEnteringGoal = false
                                conversationMode = mode
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

                    Spacer(minLength: 0)

                    Picker("Model", selection: $selectedModelID) {
                        ForEach(modelOptions) { model in
                            Text(model.name)
                                .tag(model.id)
                            .accessibilityIdentifier("model-option-\(model.id)")
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Model: \(selectedModelName)")
                    .accessibilityIdentifier("model-picker-menu")

                    if isResponding {
                        Button(action: pauseResponse) {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 31, height: 31)
                                .background(Color.primary.opacity(0.72), in: RoundedRectangle(cornerRadius: 9))
                        }
                        .buttonHoverPointer()
                        .help("Pause Codex response")
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
                        .help("Continue Codex response")
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

    private func userInputForm(_ request: CodexUserInputRequest) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Codex has a few questions")
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
                            Button {
                                var selected = userInputAnswers[question.id] ?? []
                                if selected.contains(option.label) { selected.removeAll { $0 == option.label } }
                                else { selected.append(option.label) }
                                userInputAnswers[question.id] = selected
                            } label: {
                                Label(option.label, systemImage: (userInputAnswers[question.id] ?? []).contains(option.label) ? "checkmark.circle.fill" : "circle")
                            }
                            .buttonHoverPointer()
                            .help("Select answer: \(option.label)")
                            .buttonStyle(.plain)
                        }
                        if question.allowsOther {
                            TextField("Other answer", text: Binding(
                                get: { userInputOther[question.id] ?? "" },
                                set: { userInputOther[question.id] = $0 }
                            )).textFieldStyle(.roundedBorder)
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
                    return selections.isEmpty && (userInputOther[question.id] ?? "").isEmpty
                })
                .accessibilityIdentifier("submit-ai-answers-button")
        }
        .padding(16)
        .frame(maxWidth: 720, alignment: .leading)
        .background(WorkspaceTheme.panelBackground, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
    }

    private func submitUserInput(_ request: CodexUserInputRequest) async {
        var answers: [String: [String]] = [:]
        for question in request.questions {
            var values = userInputAnswers[question.id] ?? []
            if let other = userInputOther[question.id]?.trimmingCharacters(in: .whitespacesAndNewlines), !other.isEmpty { values.append(other) }
            answers[question.id] = values
        }
        if request.isBlocking {
            do {
                _ = try await BoardTaskManager(modelContext: modelContext).setLifecycleStatus(task.id, to: .inProgress)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }
        guard codexClient.answerUserInput(requestID: request.id, threadID: request.threadID, answers: answers) else {
            if request.isBlocking {
                _ = try? await BoardTaskManager(modelContext: modelContext).setLifecycleStatus(task.id, to: .waitingResponse)
            }
            errorMessage = "Codex couldn't accept those answers. Please check the responses and try again."
            return
        }
        userInputRequest = nil
        userInputAnswers = [:]
        userInputOther = [:]
    }

    private func loadConversation() async {
        isLoadingHistory = true
        errorMessage = nil
        defer { isLoadingHistory = false }

        do {
            let history = try await conversationManager.history(taskID: task.id) {
                actionNotice = "Codex requested an approval. StationAI denied it because approval prompts are disabled."
            }
            messages = history.messages
            activities = history.activities
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
                messages.append(CodexChatMessage(id: UUID().uuidString, role: .user, text: submittedPrompt))
            }
            draft = promptWasSent || hasPendingSubmittedPrompt ? "" : (task.savedPrompt ?? "")
            if !promptWasSent && !hasPendingSubmittedPrompt {
                pendingImages = task.draftImageDataURLs.compactMap { dataURL in
                    guard let comma = dataURL.firstIndex(of: ","),
                          let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])),
                          let image = NSImage(data: data) else { return nil }
                    return PendingImage(dataURL: dataURL, image: image)
                }
            }
            isResponding = hasPendingSubmittedPrompt
                && (task.status == .inProgress || task.status == .waitingResponse)
            if let threadID = task.codexThreadID {
                isResponding = isResponding || codexClient.isTurnActive(threadID: threadID)
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
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadModels() async {
        do {
            modelOptions = try await conversationManager.models(taskID: task.id)
            if !modelOptions.contains(where: { $0.id == selectedModelID }),
               let defaultModel = modelOptions.first(where: \.isDefault) ?? modelOptions.first {
                selectedModelID = defaultModel.id
            }
        } catch {
            // Keep the last known model available when an offline or unauthenticated app-server cannot list models.
        }
    }

    private var selectedModelName: String {
        modelOptions.first(where: { $0.id == selectedModelID })?.name ?? selectedModelID
    }

    private func sendMessage(overrideText: String? = nil) {
        let text = (overrideText ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!text.isEmpty || !pendingImages.isEmpty), !isResponding, !isLoadingHistory else { return }
        let resolutionAttempt = conflictResolutionAttempt
        if text == "/plan" {
            activatePlanMode()
            return
        }
        if isEnteringGoal {
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
        guard !text.isEmpty || !pendingImages.isEmpty else { return }
        let userMessageID = UUID().uuidString
        let assistantMessageID = UUID().uuidString
        let previousResponseDuration = completedResponseDuration
        messages.append(CodexChatMessage(id: userMessageID, role: .user, text: text, imageDataURLs: pendingImages.map(\.dataURL)))
        messages.append(CodexChatMessage(id: assistantMessageID, role: .assistant, text: ""))
        isResponding = true
        let startedAt = Date()
        responseStartedAt = startedAt
        completedResponseDuration = nil
        UserDefaults.standard.set(startedAt, forKey: responseStartedAtDefaultsKey)
        UserDefaults.standard.removeObject(forKey: completedResponseDurationDefaultsKey)
        draft = ""
        let imageDataURLs = pendingImages.map(\.dataURL)
        pendingImages = []
        hasPausedResponse = false
        isPausingResponse = false
        errorMessage = nil
        actionNotice = nil
        activities = []
        isPreparingSubmittedMessage = true

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
                draft = text
                pendingImages = imageDataURLs.compactMap { dataURL in
                    guard let image = Self.image(fromDataURL: dataURL) else { return nil }
                    return PendingImage(dataURL: dataURL, image: image)
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
                _ = try await conversationManager.send(taskID: task.id, text: text, imageDataURLs: imageDataURLs, mode: conversationMode, modelID: selectedModelID, onTurnStarting: {
                    isResponding = true
                }, onUpdate: { update in
                    switch update.type {
                    case "text_delta":
                        guard let delta = update.text else { return }
                        guard let messageIndex = messages.firstIndex(where: { $0.id == assistantMessageID }) else { return }
                        messages[messageIndex].text += delta
                    case "assistant_final":
                        guard let text = update.text else { return }
                        guard let messageIndex = messages.lastIndex(where: { $0.role == .assistant }) else { return }
                        messages[messageIndex].text = text
                        messages[messageIndex].phase = "final_answer"
                    case "assistant_progress":
                        guard let itemID = update.itemID, let text = update.text else { return }
                        if let index = messages.firstIndex(where: { $0.id == itemID }) {
                            messages[index].text = text
                            messages[index].phase = update.phase
                        } else if let placeholderIndex = messages.firstIndex(where: { $0.id == assistantMessageID }) {
                            messages.insert(CodexChatMessage(
                                id: itemID,
                                role: .assistant,
                                text: text,
                                phase: update.phase
                            ), at: placeholderIndex)
                        } else {
                            messages.append(CodexChatMessage(
                                id: itemID,
                                role: .assistant,
                                text: text,
                                phase: update.phase
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
                        messages = history.messages
                        activities = history.activities
                        if update.type == "completed" {
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
                            isActivityExpanded = false
                            Task { await refreshWorkspaceChanges() }
                        }
                    case "queue_changed":
                        refreshQueuedMessages()
                    case "steered_message":
                        messages.append(CodexChatMessage(id: UUID().uuidString, role: .user, text: update.message ?? "", imageDataURLs: update.imageDataURLs ?? []))
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
                if codexClient.wasLastTurnInterrupted {
                    hasPausedResponse = true
                } else {
                    messages.removeAll { $0.id == userMessageID || $0.id == assistantMessageID }
                    draft = text
                    pendingImages = imageDataURLs.compactMap { dataURL in
                        guard let image = Self.image(fromDataURL: dataURL) else { return nil }
                        return PendingImage(dataURL: dataURL, image: image)
                    }
                    errorMessage = error.localizedDescription
                }
                isComposerFocused = true
            }

            isResponding = false
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

    private func fallbackGoalCompletionAnchorID(in historyMessages: [CodexChatMessage], objective: String) -> String {
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
                actionNotice = "Codex requested an approval. StationAI denied it because approval prompts are disabled."
            }
            messages = history.messages
            activities = history.activities
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
                    }
                    errorMessage = nil
                    return
                }
                messages.append(CodexChatMessage(id: UUID().uuidString, role: .user, text: outcome.message))
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
                messages.append(CodexChatMessage(id: UUID().uuidString, role: .user, text: text, imageDataURLs: imageDataURLs))
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
                })
                guard retried else {
                    throw BridgeCommandError(code: "operation_failed", message: "The queued follow-up still needs your attention.")
                }
                let history = try await conversationManager.history(taskID: task.id)
                messages = history.messages
                activities = history.activities
                refreshQueuedMessages()
                errorMessage = nil
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func addImageData(_ data: Data) throws {
        guard let image = NSImage(data: data) else {
            throw BridgeCommandError(code: "invalid_argument", message: "Choose up to 8 valid images that fit within 10 MB after encoding.")
        }
        try addImage(image)
    }

    private func addImage(_ image: NSImage) throws {
        guard pendingImages.count < 8 else {
            throw BridgeCommandError(code: "invalid_argument", message: "Choose up to 8 valid images that fit within 10 MB after encoding.")
        }
        let bitmap = image.representations.compactMap { $0 as? NSBitmapImageRep }.first
            ?? image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))
            ?? image.cgImage(forProposedRect: nil, context: nil, hints: nil).map(NSBitmapImageRep.init(cgImage:))
        guard let bitmap else {
            throw BridgeCommandError(code: "invalid_argument", message: "Choose up to 8 valid images that fit within 10 MB after encoding.")
        }
        guard let encoded = Self.encodedImage(bitmap), encoded.data.count <= 10_000_000 else {
            throw BridgeCommandError(code: "invalid_argument", message: "Choose up to 8 valid images that fit within 10 MB after encoding.")
        }
        guard let previewImage = NSImage(data: encoded.data) else {
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

    private static func encodedImage(_ bitmap: NSBitmapImageRep) -> (data: Data, mimeType: String)? {
        if let png = bitmap.representation(using: .png, properties: [:]), png.count <= 10_000_000 {
            return (png, "image/png")
        }

        var width = bitmap.pixelsWide
        var height = bitmap.pixelsHigh
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
        if isReadOnly { onBack(); return }
        if isResponding { onBack(); return }
        if isNewTask, draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, pendingImages.isEmpty,
           messages.isEmpty, activities.isEmpty, !isLoadingHistory {
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
        guard !isReadOnly, !isResponding, !isLoadingHistory else { return }
        draftAutosaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
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
            if (generateTitle || reserveTitleForSend), ["Generating title…", "Untitled task"].contains(savedTask.title) {
                shouldGenerateTitle = try await taskManager.renameIfTitleMatches(
                    task.id,
                    expectedTitle: savedTask.title,
                    title: "Generating title…"
                ) != nil
                if reserveTitleForSend {
                    shouldGenerateTitle = false
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
        completion?()
        guard shouldGenerateTitle else { return true }
        isGeneratingTitle = true
        Task { @MainActor in
            let title = await generateTaskTitle(from: prompt)
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
                        "titleSource": title == nil ? "prompt-fallback" : "codex"
                    ])
                    isGeneratingTitle = false
                    return
                }
                StationAIDiagnostics.record("task.title_apply.succeeded", fields: [
                    "taskID": task.id.uuidString,
                    "titleSource": title == nil ? "prompt-fallback" : "codex",
                    "fallbackWordCount": title == nil ? String(fallback.split(whereSeparator: \.isWhitespace).count) : "0"
                ])
            } catch {
                var fields = StationAIDiagnostics.errorFields(error)
                fields["taskID"] = task.id.uuidString
                fields["titleSource"] = title == nil ? "prompt-fallback" : "codex"
                StationAIDiagnostics.record("task.title_apply.failed", fields: fields)
            }
            isGeneratingTitle = false
        }
        return true
    }

    private func generateTaskTitle(from prompt: String) async -> String? {
        guard let workspace = try? CodexWorkspaceContext(roots: workspaceRootURLs) else {
            StationAIDiagnostics.record("task.title_generation.failed", fields: [
                "taskID": task.id.uuidString,
                "phase": "workspace-resolution",
                "reason": "workspace_unavailable"
            ])
            return nil
        }
        let fixtureExecutable = ProcessInfo.processInfo.environment["STATIONAI_E2E_CODEX_EXECUTABLE"]
        return await CodexTaskTitleGenerator(client: CodexAppServerClient(codexExecutableOverride: fixtureExecutable))
            .generateTitle(from: prompt, workspace: workspace, taskID: task.id)
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
        conversationMode = .plan
        draft = ""
    }

    private var workspaceRootURLs: [URL] {
        task.workspaceRootPaths.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
    }

    private var conversationManager: CodexConversationManager {
        CodexConversationManager(
            tasks: BoardTaskManager(modelContext: modelContext),
            client: codexClient
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
                    repositoryPath: repository.repositoryPath
                )
                repositoryBeingEdited = nil
                errorMessage = nil
                await refreshWorkspaceChanges()
            } catch {
                errorMessage = "Couldn't remove repository: \(error.localizedDescription)"
            }
        }
    }

    private func scrollToLatest(using proxy: ScrollViewProxy) {
        guard !messages.isEmpty || !activities.isEmpty || activeGoal?.status == "complete" else { return }
        // Defer until the state-driven content update has had a layout pass.
        // Scrolling synchronously from onChange can run before LazyVStack has
        // created its final row, which intermittently leaves reopened chats at top.
        Task { @MainActor in
            await Task.yield()
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo("conversation-latest-anchor", anchor: .bottom)
            }
        }
    }
}

// The native text view owns wrapping and document sizing. SwiftUI only receives
// a bounded viewport height; it never asks a multiline TextField for its ideal size.
private struct NativeChatEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    @Binding var isFocused: Bool
    let isEnabled: Bool
    let accessibilityHelp: String
    let onSubmit: () -> Void
    let onSteerSubmit: () -> Void
    let onPasteImage: (NSImage) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> ChatEditorScrollView {
        let scroll = ChatEditorScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.setAccessibilityIdentifier("message-composer-scroll-view")
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
        editor.onDocumentHeightChange = { [weak scroll] height in
            scroll?.documentHeightDidChange(height)
        }
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
        if editor.string != text {
            editor.string = text
            editor.undoManager?.removeAllActions()
            scroll.requestTextLayout()
        }
        if isFocused, isEnabled, editor.window?.firstResponder !== editor {
            editor.window?.makeFirstResponder(editor)
        }
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
    private(set) var viewportHeight: CGFloat = 28
    private var previousWidth: CGFloat = 0
    private var textLayoutNeeded = true

    func requestTextLayout() {
        textLayoutNeeded = true
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let editor = documentView as? NSTextView else { return }
        let width = contentSize.width
        guard width > 0, textLayoutNeeded || width != previousWidth else { return }
        textLayoutNeeded = false
        previousWidth = width
        editor.setFrameSize(NSSize(width: width, height: editor.frame.height))
        guard let textContainer = editor.textContainer,
              let layoutManager = editor.layoutManager else { return }
        // NSTextView can keep its previous long-document frame after deletion
        // until the layout manager recomputes glyph usage for the edited text.
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        let trailingLineBottom = layoutManager.extraLineFragmentTextContainer === textContainer
            ? layoutManager.extraLineFragmentRect.maxY
            : usedRect.maxY
        let contentHeight = ceil(max(usedRect.maxY, trailingLineBottom) + editor.textContainerInset.height * 2)
        let documentHeight = max(28, contentHeight)
        editor.setFrameSize(NSSize(width: width, height: documentHeight))
        documentHeightDidChange(documentHeight)
    }

    func documentHeightDidChange(_ documentHeight: CGFloat) {
        let newHeight = min(240, max(28, ceil(documentHeight)))
        if viewportHeight != newHeight {
            viewportHeight = newHeight
            onHeightChange?(newHeight)
        }
    }
}

private final class ChatEditorTextView: NSTextView {
    var onDocumentHeightChange: ((CGFloat) -> Void)?

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // NSTextView can finish laying out text after the scroll view's layout
        // pass. Follow its actual document height whenever native layout changes
        // it, including restored drafts, wrapping and deletion.
        onDocumentHeightChange?(frame.height)
    }

    var onSubmit: (() -> Void)?
    var onSteerSubmit: (() -> Void)?
    var onPasteImage: ((NSImage) -> Void)?

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
        let image = pasteboard.readObjects(forClasses: [NSImage.self])?.first as? NSImage
        if let image {
            onPasteImage?(image)
        } else if let data = pasteboard.data(forType: .png)
                    ?? pasteboard.data(forType: .tiff),
                  let image = NSImage(data: data) {
            onPasteImage?(image)
        } else {
            super.paste(sender)
        }
    }
}
