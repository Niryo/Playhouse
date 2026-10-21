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

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var codexClient: CodexAppServerClient
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(WorkspaceSettings.defaultParentFolderKey, store: WorkspaceSettings.preferencesStore) private var defaultParentFolderPath = ""

    let task: BoardTask
    var isNewTask = false
    var isReadOnly = false
    let onBack: () -> Void

    @State private var draft = ""
    @State private var pendingImages: [PendingImage] = []
    @State private var isShowingImagePicker = false
    @State private var isGeneratingTitle = false
    @State private var conversationMode: CodexConversationMode = .code
    @State private var modelOptions = [CodexModelOption(id: CodexAppServerClient.modelID, name: "GPT-6 Luna", isDefault: true)]
    @State private var selectedModelID = CodexAppServerClient.modelID
    @State private var messages: [CodexChatMessage] = []
    @State private var activities: [CodexActivity] = []
    @State private var isActivityExpanded = false
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
    @State private var hasPausedResponse = false
    @State private var isPausingResponse = false
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
        (draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pendingImages.isEmpty) || workspaceRootURLs.isEmpty || isResponding || isLoadingHistory
    }

    private var diffHighlightStatus: String {
        guard let diffChangeCount else { return "Calculating changes…" }
        guard diffChangeCount > 0 else { return "No text changes" }
        return "\(diffChangeCount) change\(diffChangeCount == 1 ? "" : "s") highlighted"
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
            if !isReadOnly { await loadModels() }
        }
        .onChange(of: codexClient.isTurnActive) { _, isTurnActive in
            let submittedTurnIsPending = task.pendingSubmittedPrompt != nil
                && (task.status == .inProgress || task.status == .waitingResponse)
            guard let taskThreadID = task.codexThreadID else {
                isResponding = submittedTurnIsPending
                return
            }
            isResponding = submittedTurnIsPending || (isTurnActive && codexClient.isTurnActive(threadID: taskThreadID))
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

            if isDiffPresented {
                fileDiffOverlay
                    .transition(.move(edge: .leading))
                    .zIndex(1)
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
        return "Last used: \(names.joined(separator: ", ")) — press Return to reuse"
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
            if workspaceRootURLs.isEmpty {
                Text("No working folders are set. Add one or more folders before sending a message.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
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
                    if messages.isEmpty {
                        VStack(spacing: 12) {
                            if isLoadingHistory {
                                ProgressView("Loading conversation…")
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "bubble.left.and.bubble.right")
                                    .font(.system(size: 25, weight: .regular))
                                    .foregroundStyle(Color.accentColor.opacity(0.8))
                                Text("Start a conversation")
                                    .font(.system(size: 17, weight: .semibold))
                                Text("Send a message to Codex · Luna.")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 210)
                        .padding(30)
                        .accessibilityIdentifier("empty-conversation")
                    } else {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            ForEach(messages) { message in
                                messageBubble(message)
                                    .id(message.id)
                            }
                        }
                    }

                    if !activities.isEmpty || isResponding {
                        activityList
                    }
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
            .onChange(of: activities) { _, _ in
                if isResponding { scrollToLatest(using: scrollProxy) }
            }
        }
    }

    private var activityList: some View {
        let runningCount = activities.filter { $0.status == "inProgress" || $0.status == "running" }.count
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    isActivityExpanded.toggle()
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: isActivityExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Image(systemName: runningCount > 0 || isResponding ? "gearshape.2.fill" : "checkmark.circle.fill")
                        .foregroundStyle(runningCount > 0 || isResponding ? Color.accentColor : Color.green)
                    if isResponding && runningCount == 0 {
                        TimelineView(.periodic(from: .now, by: 0.45)) { timeline in
                            let phase = Int(timeline.date.timeIntervalSinceReferenceDate / 0.45) % 4
                            Text("Thinking" + String(repeating: ".", count: phase))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                                .accessibilityLabel("Thinking")
                                .accessibilityIdentifier("codex-thinking-indicator")
                        }
                    } else {
                        Text(runningCount > 0 ? "Running \(runningCount) task\(runningCount == 1 ? "" : "s")…" : "Codex activity · \(activities.count) task\(activities.count == 1 ? "" : "s")")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonHoverPointer()
            .help("Show or hide Codex activity details")
            .buttonStyle(.plain)
            .accessibilityLabel(isResponding && runningCount == 0 ? "Thinking" : runningCount > 0 ? "Running \(runningCount) task\(runningCount == 1 ? "" : "s")" : "Codex activity, \(activities.count) task\(activities.count == 1 ? "" : "s")")
            .accessibilityIdentifier("codex-activity-disclosure")

            if isActivityExpanded {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(activities) { activity in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 7) {
                                Image(systemName: activity.status == "completed" ? "checkmark.circle.fill" : "gearshape.2.fill")
                                    .foregroundStyle(activity.status == "completed" ? .green : .accentColor)
                                Text(activity.title)
                                    .font(.system(size: 11, weight: .medium))
                                    .textSelection(.enabled)
                                Spacer(minLength: 4)
                                Text(activity.statusLabel)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                            if !activity.detail.isEmpty {
                                Text(activity.detail)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .lineLimit(4)
                                    .accessibilityIdentifier("codex-activity-detail-\(activity.id)")
                                    .accessibilityLabel(activity.detail)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(9)
                        .background(WorkspaceTheme.panelBackground, in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("\(activity.title), \(activity.statusLabel)")
                        .accessibilityValue(activity.detail)
                        .accessibilityIdentifier("codex-activity-row-\(activity.id)")
                    }
                }
                .padding(.top, 6)
            }
        }
    }

    @ViewBuilder
    private func messageBubble(_ message: CodexChatMessage) -> some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .assistant {
                assistantBubble(message)
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

            Group {
                if displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && isResponding {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    assistantMarkdownContent(displayText)
                }
            }
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
        return VStack(alignment: .leading, spacing: 7) {
            ForEach(blocks) { block in
                switch block.kind {
                case .heading(let level):
                    Text(Self.markdownAttributedText(block.text))
                        .font(.system(size: level == 1 ? 19 : level == 2 ? 17 : 15, weight: .semibold))
                        .accessibilityIdentifier("assistant-markdown-heading-\(block.id)")
                case .listItem:
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("•").foregroundStyle(.secondary)
                        Text(Self.markdownAttributedText(block.text))
                            .accessibilityIdentifier("assistant-markdown-list-content-\(block.id)")
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("assistant-markdown-list-item-\(block.id)")
                case .paragraph:
                    Text(Self.markdownAttributedText(block.text))
                        .accessibilityIdentifier("assistant-markdown-paragraph-\(block.id)")
                }
            }
        }
        .lineSpacing(4)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }

    private static func markdownBlocks(_ markdown: String) -> [AssistantMarkdownBlock] {
        markdown.components(separatedBy: .newlines).enumerated().compactMap { index, rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return nil }
            let headingPrefix = line.prefix(while: { $0 == "#" })
            if !headingPrefix.isEmpty, headingPrefix.count <= 6,
               line.dropFirst(headingPrefix.count).first == " " {
                return AssistantMarkdownBlock(id: index, kind: .heading(headingPrefix.count), text: String(line.dropFirst(headingPrefix.count + 1)))
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                return AssistantMarkdownBlock(id: index, kind: .listItem, text: String(line.dropFirst(2)))
            }
            return AssistantMarkdownBlock(id: index, kind: .paragraph, text: line)
        }
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
                                    Button { pendingImages.removeAll { $0.id == attachment.id } } label: {
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

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(errorMessage)
                    .accessibilityIdentifier("codex-chat-error")
            }

            VStack(alignment: .leading, spacing: 10) {
                TextField("Message…", text: $draft, axis: .vertical)
                    .font(.system(size: 14))
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .focused($isComposerFocused)
                    .onKeyPress(.return, phases: .down) { press in
                        guard press.modifiers.contains(.shift) else { return .ignored }
                        draft += "\n"
                        return .handled
                    }
                    .onKeyPress(KeyEquivalent("v"), phases: .down) { press in
                        guard press.modifiers.contains(.command),
                              let image = NSPasteboard.general.readObjects(forClasses: [NSImage.self])?.first as? NSImage,
                              let data = image.tiffRepresentation else { return .ignored }
                        do { try addImageData(data) }
                        catch { errorMessage = error.localizedDescription }
                        return .handled
                    }
                    .onSubmit { sendMessage() }
                    .onPasteCommand(of: [.image]) { providers in
                        for provider in providers {
                            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                                guard let data else { return }
                                Task { @MainActor in
                                    do { try addImageData(data) }
                                    catch { errorMessage = error.localizedDescription }
                                }
                            }
                        }
                    }
                    .onChange(of: draft) { _, newValue in
                        if newValue.trimmingCharacters(in: .whitespacesAndNewlines) == "/plan" {
                            activatePlanMode()
                        }
                    }
                    .disabled(isReadOnly || isResponding || isLoadingHistory)
                    .accessibilityIdentifier("message-composer")

                HStack(spacing: 12) {
                    Button { isShowingImagePicker = true } label: { Image(systemName: "paperclip") }
                    .buttonHoverPointer()
                    .help("Attach image")
                        .buttonStyle(.plain).accessibilityLabel("Attach image")
                        .accessibilityIdentifier("attach-chat-image-button")
                    Menu {
                        ForEach(CodexConversationMode.allCases, id: \.self) { mode in
                            Button {
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
                            if conversationMode == .plan {
                                Text("Plan")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                        }
                        .foregroundStyle(conversationMode == .plan ? Color.accentColor : Color.secondary)
                        .frame(minWidth: 30, minHeight: 31)
                        .contentShape(Rectangle())
                    }
                    .buttonHoverPointer()
                    .menuStyle(.borderlessButton)
                    .help("Change conversation mode or add context")
                    .accessibilityLabel("Conversation mode: \(conversationMode.title)")
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
                            Image(systemName: "pause.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 31, height: 31)
                                .background(Color.primary.opacity(0.72), in: RoundedRectangle(cornerRadius: 9))
                        }
                        .buttonHoverPointer()
                        .help("Pause Codex response")
                        .buttonStyle(.plain)
                        .disabled(isPausingResponse || !codexClient.isTurnActive)
                        .accessibilityLabel("Pause response")
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
                        Button("Save") {
                            Task { @MainActor in _ = await saveDraftAndGenerateTitle(status: nil, then: onBack) }
                        }
                        .buttonHoverPointer()
                        .help("Save draft and return to the board")
                            .disabled(isResponding || isLoadingHistory || draft.isEmpty)
                            .accessibilityIdentifier("save-task-prompt-button")
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
            isResponding = hasPendingSubmittedPrompt
                && (task.status == .inProgress || task.status == .waitingResponse)
            if let threadID = task.codexThreadID {
                isResponding = isResponding || codexClient.isTurnActive(threadID: threadID)
            }
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
        if text == "/plan" {
            activatePlanMode()
            return
        }
        let userMessageID = UUID().uuidString
        let assistantMessageID = UUID().uuidString
        messages.append(CodexChatMessage(id: userMessageID, role: .user, text: text, imageDataURLs: pendingImages.map(\.dataURL)))
        messages.append(CodexChatMessage(id: assistantMessageID, role: .assistant, text: ""))
        isResponding = true
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
                messages.removeAll { $0.id == userMessageID || $0.id == assistantMessageID }
                draft = text
                pendingImages = imageDataURLs.compactMap { dataURL in
                    guard let image = Self.image(fromDataURL: dataURL) else { return nil }
                    return PendingImage(dataURL: dataURL, image: image)
                }
                isResponding = false
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
                            Task { await refreshWorkspaceChanges() }
                        }
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
            } catch {
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

    private func addImageData(_ data: Data) throws {
        guard pendingImages.count < 8, data.count <= 10_000_000,
              let image = NSImage(data: data),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw BridgeCommandError(code: "invalid_argument", message: "Choose up to 8 valid images, each smaller than 10 MB.")
        }
        pendingImages.append(PendingImage(dataURL: "data:image/png;base64,\(png.base64EncodedString())", image: image))
    }

    private static func image(fromDataURL value: String) -> NSImage? {
        guard let comma = value.firstIndex(of: ","), let data = Data(base64Encoded: String(value[value.index(after: comma)...])) else { return nil }
        return NSImage(data: data)
    }

    private func saveAndBack() {
        if isReadOnly { onBack(); return }
        if isResponding { onBack(); return }
        if isNewTask, draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
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
        Task { @MainActor in _ = await saveDraftAndGenerateTitle(status: nil, then: onBack) }
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
                var fields = StationAIDiagnostics.errorFields(error, redacting: [resolvedTitle, prompt])
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
        let target: String
        if let latestMessage = messages.last {
            target = latestMessage.id
        } else if let latestActivity = activities.last {
            target = latestActivity.id
        } else {
            return
        }
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(target, anchor: .bottom)
        }
    }
}
